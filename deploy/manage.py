#!/usr/bin/env python3
"""Deploy without printing secrets. Runtime files live outside the Git checkout."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess


DEFAULT_ROOT = Path.home() / '.local/share/almis/deploy'


def read_env(path):
    if not path.exists():
        return {}
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#') and '=' in line)


def write_env(path, values):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w') as output:
        os.chmod(temporary, 0o600)
        for key, value in values.items():
            if '\n' in str(value) or '\r' in str(value):
                raise ValueError(f'{key} must be a single line')
            output.write(f'{key}={value}\n')
    temporary.replace(path)
    os.chmod(path, 0o600)


def prepare_env(path, template=None):
    values = read_env(path)
    if not values and template and template.exists():
        values = read_env(template)
    values.setdefault('POSTGRES_USER', 'almis')
    values.setdefault('POSTGRES_DB', 'almis')
    values.setdefault('POSTGRES_PASSWORD', secrets.token_hex(32))
    url = (f"postgresql://{values['POSTGRES_USER']}:{values['POSTGRES_PASSWORD']}"
           f"@db:5432/{values['POSTGRES_DB']}?schema=public")
    values.setdefault('DATABASE_URL', url)
    values.setdefault('DIRECT_URL', url)
    values.setdefault('JWT_SECRET', secrets.token_hex(48))
    values.setdefault('JWT_EXPIRES_IN', '3600')
    values.setdefault('ALLOWED_ORIGINS', '[]')
    write_env(path, values)


def ensure_secret(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.tmp')
        temporary.write_text(secrets.token_urlsafe(48) + '\n')
        os.chmod(temporary, 0o600)
        temporary.replace(path)
    os.chmod(path, 0o600)


def tutorial_signing_key(root, preview=None):
    if preview is None:
        return root / 'cloudflared/tutorials-signing-key'
    return root / f'previews/pr-{preview}/tutorials-signing-key'


def cloudflare(*args):
    result = subprocess.run(['cf', *args], capture_output=True, text=True)
    if result.returncode:
        # Avoid returning an API response that may contain credentials.
        raise RuntimeError('Cloudflare command failed: ' + ' '.join(args[:3]))
    return json.loads(result.stdout)


def publish_dns(root, hostname, remove=False):
    state = json.loads((root / 'cloudflare-state.json').read_text())
    zone = state['zone']
    target = state['tunnel_id'] + '.cfargotunnel.com'
    marker = 'almis-onprem:' + hostname
    records = cloudflare('dns', 'records', 'list', '--zone', zone, '--name', hostname)
    if records:
        if any(r['type'] != 'CNAME' or r['content'] != target or
               r.get('comment') != marker or not r.get('proxied') for r in records):
            raise RuntimeError('DNS name already belongs to another configuration: ' + hostname)
        if remove:
            for record in records:
                cloudflare('dns', 'records', 'delete', record['id'], '--zone', zone, '--force')
    elif not remove:
        body = json.dumps(dict(type='CNAME', name=hostname, content=target,
                               proxied=True, ttl=1, comment=marker))
        cloudflare('dns', 'records', 'create', '--zone', zone, '--body', body, '--dry-run')
        cloudflare('dns', 'records', 'create', '--zone', zone, '--body', body)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'main', 'preview', 'remove-preview'])
    parser.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--image')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--host', default='api.almishotel.com')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}', args.host):
        parser.error('Invalid hostname')
    if args.action in ('main', 'preview') and not args.image:
        parser.error('--image is required')
    if args.action in ('preview', 'remove-preview') and (args.pr is None or args.pr < 1):
        parser.error('--pr must be positive')
    root = args.root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    # One writer per host. Never cancel a deployment midway through migrations.
    with (root / '.deploy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = Path(__file__).resolve().parent
        if args.action == 'prepare':
            for name in ('compose.main.yml', 'compose.preview.yml', 'manage.py'):
                if source / name != root / name:
                    shutil.copyfile(source / name, root / name)
            (root / 'cloudflared').mkdir(exist_ok=True, mode=0o700)
            (root.parent / 'tutorials/main').mkdir(parents=True, exist_ok=True, mode=0o700)
            ensure_secret(tutorial_signing_key(root))
            prepare_env(root / '.env.production', source / '.env.production')
            prepare_env(root / '.env.preview', source / '.env.preview')
            print(f'Prepared {root}; existing secrets preserved, values hidden.')
            return

        if args.action == 'main':
            env_file = root / '.env.production'
            prepare_env(env_file)
            tutorial_dir = root.parent / 'tutorials/main'
            tutorial_key = tutorial_signing_key(root)
            tutorial_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            ensure_secret(tutorial_key)
            settings = dict(APP_IMAGE=args.image, MAIN_HOST=args.host,
                            TUTORIALS_HOST_DIR=str(tutorial_dir), TUTORIALS_SIGNING_KEY_FILE=str(tutorial_key),
                            HOST_UID=str(os.getuid()), HOST_GID=str(os.getgid()),
                            POSTGRES_VOLUME=read_env(env_file).get('POSTGRES_VOLUME', 'almis-main_postgres'))
            # External volume survives Compose teardown and preserves an existing installation.
            subprocess.run(['docker', 'volume', 'create', settings['POSTGRES_VOLUME']],
                           stdout=subprocess.DEVNULL, check=True)
            compose = ['docker', 'compose', '--project-directory', str(root),
                       '--env-file', str(env_file), '-f', str(root / 'compose.main.yml')]
        else:
            env_file = root / f'previews/pr-{args.pr}/.env'
            if args.action == 'remove-preview' and not env_file.exists():
                publish_dns(root, f'pr-{args.pr}-{args.host}', remove=True)
                print(f'Preview {args.pr} already absent.')
                return
            # Never reuse the production or another PR's JWT/database credentials.
            if not env_file.exists():
                defaults = read_env(root / '.env.preview')
                write_env(env_file, {'ALLOWED_ORIGINS': defaults.get('ALLOWED_ORIGINS', '[]')})
            prepare_env(env_file)
            tutorial_root = root.parent / 'tutorials'
            tutorial_main = tutorial_root / 'main'
            tutorial_dir = tutorial_root / f'pr-{args.pr}'
            tutorial_root.mkdir(parents=True, exist_ok=True, mode=0o700)
            tutorial_main.mkdir(parents=True, exist_ok=True, mode=0o700)
            tutorial_key = tutorial_signing_key(root, args.pr)
            ensure_secret(tutorial_key)
            if not tutorial_dir.is_dir():
                tutorial_dir = tutorial_main
            settings = dict(PREVIEW_ID=f'pr-{args.pr}', PREVIEW_IMAGE=args.image or 'unused',
                            TUTORIALS_HOST_DIR=str(tutorial_dir), TUTORIALS_SIGNING_KEY_FILE=str(tutorial_key),
                            PREVIEW_HOST=f'pr-{args.pr}-{args.host}', PREVIEW_ENV_FILE=str(env_file))
            compose = ['docker', 'compose', '--project-directory', str(root),
                       '--env-file', str(env_file), '-p', f'almis-preview-pr-{args.pr}',
                       '-f', str(root / 'compose.preview.yml')]
        environment = {**os.environ, **settings}
        if args.action == 'remove-preview':
            publish_dns(root, settings['PREVIEW_HOST'], remove=True)
            subprocess.run(compose + ['down', '--volumes', '--remove-orphans'],
                           env=environment, check=True)
            shutil.rmtree(env_file.parent)
            print(f'Removed preview {args.pr} and its disposable database.')
        else:
            subprocess.run(compose + ['up', '-d', '--wait', '--wait-timeout', '240'],
                           env=environment, check=True)
            if args.action == 'main':
                write_env(root / '.env.stack', settings)
            publish_dns(root, settings.get('PREVIEW_HOST', args.host))
            print('Healthy deployment at https://' + settings.get('PREVIEW_HOST', args.host))


if __name__ == '__main__':
    main()
