from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).parent
MANAGE_SPEC = importlib.util.spec_from_file_location('deploy_manage', ROOT / 'manage.py')
MANAGE = importlib.util.module_from_spec(MANAGE_SPEC)
MANAGE_SPEC.loader.exec_module(MANAGE)


class TutorialMountTest(unittest.TestCase):
    def _render(self, compose_name):
        with tempfile.TemporaryDirectory(prefix='compose-tutorial-test-') as directory:
            project = Path(directory)
            compose_file = project / compose_name
            shutil.copy(ROOT / compose_name, compose_file)
            tutorial_dir = project / 'tutorials'
            tutorial_dir.mkdir()
            key_file = project / 'tutorials-signing-key'
            key_file.write_text('test-signing-key-' + 'x' * 40 + '\n')
            (project / 'cloudflared').mkdir()
            (project / 'cloudflared/token').write_text('test-token\n')

            runtime_env = project / ('.env.production' if compose_name == 'compose.main.yml' else 'preview.env')
            runtime_env.write_text('\n'.join([
                'POSTGRES_USER=almis',
                'POSTGRES_PASSWORD=test-password',
                'POSTGRES_DB=almis',
                'DATABASE_URL=postgresql://almis:test-password@db:5432/almis?schema=public',
                'DIRECT_URL=postgresql://almis:test-password@db:5432/almis?schema=public',
                'JWT_SECRET=test-jwt-secret',
                'ALLOWED_ORIGINS=[]',
                '',
            ]))
            interpolation = project / 'compose.env'
            values = {
                'POSTGRES_USER': 'almis',
                'POSTGRES_PASSWORD': 'test-password',
                'POSTGRES_DB': 'almis',
                'TUTORIALS_HOST_DIR': str(tutorial_dir),
                'TUTORIALS_SIGNING_KEY_FILE': str(key_file),
            }
            if compose_name == 'compose.main.yml':
                values.update(APP_IMAGE='test-image', MAIN_HOST='api.example.com',
                               HOST_UID='1000', HOST_GID='1000')
            else:
                values.update(PREVIEW_IMAGE='test-image', PREVIEW_ID='pr-42',
                              PREVIEW_HOST='pr-42-api.example.com', PREVIEW_ENV_FILE=str(runtime_env))
            interpolation.write_text(''.join(f'{name}={value}\n' for name, value in values.items()))

            command = [
                'docker', 'compose', '--project-directory', str(project),
                '--env-file', str(interpolation), '-f', str(compose_file),
                'config', '--format', 'json',
            ]
            environment = {name: value for name, value in os.environ.items()
                           if name not in values and not name.startswith(('TUTORIALS_', 'COMPOSE_'))}
            result = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout), tutorial_dir, key_file

    def _assert_contract(self, rendered, tutorial_dir, key_file):
        api = rendered['services']['api']
        environment = api['environment']
        self.assertEqual(environment['TUTORIALS_DIR'], '/srv/tutorials')
        self.assertEqual(environment['TUTORIALS_SIGNING_SECRET_FILE'],
                         '/run/secrets/tutorials-signing-key')
        self.assertEqual({name for name in environment if name.startswith('TUTORIALS_SIGNING_')},
                         {'TUTORIALS_SIGNING_SECRET_FILE'})

        mounts = [mount for mount in api.get('volumes', []) if mount['target'] == '/srv/tutorials']
        self.assertEqual(len(mounts), 1)
        self.assertEqual(mounts[0]['type'], 'bind')
        self.assertEqual(mounts[0]['source'], str(tutorial_dir.resolve()))
        self.assertTrue(mounts[0].get('read_only', False))

        attachments = api.get('secrets', [])
        self.assertEqual(len(attachments), 1)
        self.assertEqual(attachments[0]['source'], 'tutorials-signing-key')
        # Compose versions render the default target either as a name or an absolute path.
        target = Path('/run/secrets') / attachments[0]['target']
        self.assertEqual(str(target), environment['TUTORIALS_SIGNING_SECRET_FILE'])
        self.assertEqual(rendered['secrets']['tutorials-signing-key']['file'],
                         str(key_file.resolve()))

    def test_main_compose_renders_the_read_only_file_secret_contract(self):
        rendered, tutorial_dir, key_file = self._render('compose.main.yml')
        self._assert_contract(rendered, tutorial_dir, key_file)

    def test_preview_compose_renders_the_read_only_file_secret_contract(self):
        rendered, tutorial_dir, key_file = self._render('compose.preview.yml')
        self._assert_contract(rendered, tutorial_dir, key_file)

    def test_manager_isolates_and_preserves_keys_through_preview_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix='key-isolation-test-') as directory:
            root = Path(directory) / 'deploy'

            def invoke(action, pr=None):
                arguments = ['manage.py', action, '--root', str(root)]
                if action != 'remove-preview':
                    arguments += ['--image', 'test-image']
                if pr is not None:
                    arguments += ['--pr', str(pr)]
                old_mask = os.umask(0o077)
                try:
                    with patch('sys.argv', arguments), redirect_stdout(io.StringIO()), \
                            patch.object(MANAGE.subprocess, 'run') as run, \
                            patch.object(MANAGE, 'publish_dns'):
                        MANAGE.main()
                    call = run.call_args
                    self.assertEqual(call.args[0][:2], ['docker', 'compose'])
                    return call.kwargs['env']
                finally:
                    os.umask(old_mask)

            main = invoke('main')
            preview = invoke('preview', 42)
            other_preview = invoke('preview', 43)
            environments = [main, preview, other_preview]
            keys = [Path(env['TUTORIALS_SIGNING_KEY_FILE']) for env in environments]
            self.assertEqual(keys, [root / 'cloudflared/tutorials-signing-key',
                                    root / 'previews/pr-42/tutorials-signing-key',
                                    root / 'previews/pr-43/tutorials-signing-key'])
            contents = [key.read_bytes() for key in keys]
            self.assertEqual(len(set(contents)), 3)
            for key, content, environment in zip(keys, contents, environments):
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertGreaterEqual(len(content.strip()), 32)
                self.assertNotIn(content.strip().decode(), json.dumps(environment))
            main_store = str(root.parent / 'tutorials/main')
            self.assertTrue(Path(main_store).is_dir())
            self.assertEqual([env['TUTORIALS_HOST_DIR'] for env in environments], [main_store] * 3)

            preview_store = root.parent / 'tutorials/pr-42'
            preview_store.mkdir()
            self.assertEqual(invoke('preview', 42)['TUTORIALS_HOST_DIR'], str(preview_store))
            invoke('main')
            self.assertEqual([key.read_bytes() for key in keys], contents)
            teardown = invoke('remove-preview', 42)
            self.assertEqual(teardown['TUTORIALS_SIGNING_KEY_FILE'], str(keys[1]))
            self.assertFalse(keys[1].parent.exists())
            self.assertEqual(keys[0].read_bytes(), contents[0])
            self.assertEqual(keys[2].read_bytes(), contents[2])
            self.assertTrue(preview_store.is_dir())


if __name__ == '__main__':
    unittest.main()
