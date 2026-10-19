# On-premise deployment

The main API is `https://api.almishotel.com`. Each same-repository PR targeting `main` gets `https://pr-N-api.almishotel.com` and its own empty Postgres database. Merging or closing the PR removes its containers, database volume, credentials, and DNS record.

Cloudflare serves DNS. Namecheap remains the registrar. DNS records belong in Cloudflare, not Namecheap Advanced DNS. Preview names have one subdomain level so Cloudflare Universal SSL covers them without an Advanced Certificate.

## Files on the host

The deployment directory is `~/.local/share/almis/deploy`, outside any Git worktree. `manage.py prepare` installs manifests and preserves existing secrets. Generated env and token files have mode `0600`; new directories have mode `0700`.

- `.env.production` contains production JWT and database credentials.
- `.env.preview` supplies default frontend origins for new previews.
- `previews/pr-N/.env` contains credentials unique to that PR.
- `.env.admin` holds the generated initial admin login, when bootstrapped. Change its password on first login.
- `.env.stack` records the current main image and non-secret Compose settings.
- `cloudflare-state.json` records the zone and tunnel UUID.
- `cloudflared/token` authenticates the remotely managed tunnel.
- `cloudflared/tutorials-signing-key` is the production-only HMAC key mounted read-only into the main API. Each preview keeps a separate key at `previews/pr-N/tutorials-signing-key`.
- `~/.local/share/almis/tutorials/main` is the published main tutorial store. `pr-N` directories hold PR preview stores and fall back to `main` when absent.

The API and database have no published ports. The database only joins a private network belonging to that deployment. Traefik binds its local diagnostic port to `127.0.0.1:8080`. Cloudflared makes outbound connections, so no public inbound SSH port is required.

## Tutorial media

The backend reads `/srv/tutorials` from a read-only host mount. The manager creates `~/.local/share/almis/tutorials/main` during `prepare`, and `main` is the fallback for previews without a `pr-N` directory. FE-4 publishes content-addressed MP4 and poster files plus an atomically replaced `manifest.json` into these directories. The API receives `TUTORIALS_DIR=/srv/tutorials` and reads the HMAC key from `/run/secrets/tutorials-signing-key`; production and every preview use different key files, and the key value is never placed in a Compose environment entry or image layer. Keep the host directories and keys outside Git and back them up with the deployment host's protected files.

Compose refuses a missing tutorial source directory instead of creating a root-owned directory. Use the manager to create the main store before starting Compose directly. An existing empty store still serves an empty tutorial list.

Preview keys remain stable across redeploys and are deleted with their preview credentials during `remove-preview`. Falling back to main's media never reuses main's signing key. Preview removal preserves the main store and any preview media store; the publisher owns media retention.

The backend manager reserves `tutorials/pr-N` and `deploy/previews/pr-N` for backend PRs. Frontend previews must use a separate repository namespace for media and their own signing keys, credentials and Compose projects. They must not mount production's signing key or invoke this manager with a frontend PR number.

Signed media URLs grant access to anyone holding the URL for up to one hour. Keep them out of shared logs. The API currently runs as root, so host chmod restrictions do not prove an unreadable-manifest failure; read-only mounts still prevent writes.

Run `python3 -m unittest discover -s deploy -p 'test*.py' -v` from the checkout to check the tutorial deployment contract. The tests require Docker Compose with JSON config output, but do not start containers or publish DNS. They render both Compose files using temporary test credentials and exercise the manager with Docker and DNS calls mocked.

The current frontend allowlist is `https://almishotel.com` and `https://www.almishotel.com`. Edit `ALLOWED_ORIGINS` in the production env file if the frontend uses other origins, using a JSON array. Add `ATTENDANCE_API_KEY` when configuring the attendance scanner. Restart the API after changing its env file.

## Bootstrap

Install Docker Engine, Compose v2 with `--wait`, Python 3, GitHub CLI, and Cloudflare CLI. Authenticate the Cloudflare CLI on the deployment host. Do not print its authentication tokens.

```bash
python3 deploy/manage.py prepare
```

Create a remotely managed Cloudflare Tunnel using `cf tunnels create --name almis-onprem --config-source cloudflare`. Save its UUID, zone, and hostname in `cloudflare-state.json`:

```json
{
  "tunnel_id": "<UUID>",
  "zone": "almishotel.com",
  "main_host": "api.almishotel.com"
}
```

Retrieve the tunnel token directly into `cloudflared/token`, with mode `0600`. The CLI returns a JSON string; decode that string before writing the token file. Never paste the token into Git, a workflow, or a command argument. The connector reads it with `--token-file`.

Apply `cloudflared/ingress.example.json` using `cf tunnels config update <UUID> --body ...`, after reviewing the CLI's dry run. The wildcard is an ingress rule only. Do not create a wildcard DNS record for the whole zone. `manage.py` creates one proxied CNAME per deployment, pointing to `<UUID>.cfargotunnel.com`, and refuses to replace DNS records it does not own.

Build and start the main image:

```bash
docker build -t almis-backend:bootstrap .
python3 deploy/manage.py main --image almis-backend:bootstrap
```

Pending Prisma migrations run before the API starts. The deployment waits for Postgres and the API to become healthy, then creates the main DNS record. New installations use the external `almis-main_postgres` volume. This host preserves its original `bayne-main_postgres` volume through `POSTGRES_VOLUME` in the private production env file. The main volume is external so Compose cannot remove it. Never remove the production volume manually.

## Continuous deployment

CI runs unit tests, type checking, migrations, and integration tests before calling a deployment workflow. Merging to `main` runs CI only. Production deploys when someone pushes a release tag:

```bash
git switch main && git pull --ff-only
git tag -a v1.4.0 -m "v1.4.0"
git push fork v1.4.0
```

The tag must point at a commit that `main` already contains, or the deployment fails before touching the host. CI runs again on the tagged commit first. To roll back, re-run CI on an older tag with `gh workflow run CI --ref v1.3.0`. Rolling back the image does not undo database migrations.

Releases build their image on the local deployment runner, where Docker's layer cache rebuilds a source-only change in seconds. PR preview images build on GitHub-hosted runners and reach the local runner through GHCR (`ghcr.io/abulhuman/bayne-guest-house-backend:pr-<n>-<sha>`), so PR code never builds on this host. The host pulls only the layers it lacks, and closing a PR deletes its images from the host and every closed PR's images from GHCR. GHCR refuses to delete a package's last tagged version, so one stays until the next teardown. The workflow token signs in to GHCR for each job, so no GHCR password, deployment SSH key, or repository secret is needed.

A repository admin must register a self-hosted Linux x64 runner on this machine with label `almis-onprem`. The runner must run as the host user who owns `~/.local/share/almis/deploy` and has Docker access. Its PATH must include `docker`, `python3`, `cf`, `gh`, and their runtime dependencies. Use the installation commands GitHub provides under:

https://github.com/abulhuman/bayne-guest-house-backend/settings/actions/runners/new

Upstream runner admin access is pending. The temporary deployment repository is `abulhuman/bayne-guest-house-backend`. Register with `python3 deploy/register-runner.py --repo abulhuman/bayne-guest-house-backend`. The script downloads the official runner, verifies its release SHA-256 digest, and passes the registration token through the runner input environment without displaying it. The runner is named `almis-onprem` and lives in `~/.local/share/almis/runner`.

Run it under a user systemd service with `Restart=always`, an explicit PATH containing the Cloudflare CLI and Node runtime, and `WorkingDirectory` set to the runner directory. Copy `almis-runner.service.example` to `~/.config/systemd/user/almis-runner.service`, adjust the Node path to the installed version, then run `systemctl --user daemon-reload` and `systemctl --user enable --now almis-runner.service`. This host has user lingering and Docker startup enabled so it returns after reboot. Runner state contains credentials and must remain private.

When upstream admin access arrives, stop the runner service, remove the fork registration using the runner's `config.sh remove` with a freshly obtained removal token, and register against `Jaal-moha/bayne-guest-house-backend`. Keep the same runner label, runtime directory, tunnel, and database. Merge these deployment workflows upstream before switching triggers. Do not run production triggers from both repositories simultaneously.

The local runner never checks out or executes PR host scripts. It loads the built container image and uses the deployment script installed by the last release. Same-repository contributors are trusted to run preview application code in containers. Fork PRs only run CI. Keep workflow changes reviewed and do not enable fork deployment jobs on this persistent runner.

The preview job checks that the PR is still open and its head SHA still matches before starting it. A release checks that `main` contains its commit. Releases run one at a time. A newer waiting release replaces an older waiting one. A host lock serializes mutations, and workflows do not cancel a running deployment midway through migrations. Preview comments appear only after the container becomes healthy and DNS creation succeeds.

The main job also checks public HTTPS. If the host resolver returns stale DNS, it retries with an IPv4 address retrieved from Cloudflare DNS over HTTPS. Certificate verification and the public hostname remain enabled.

To create or remove a preview manually:

```bash
python3 ~/.local/share/almis/deploy/manage.py preview --pr 42 --image almis-backend:pr-42
python3 ~/.local/share/almis/deploy/manage.py remove-preview --pr 42
```

Preview removal deliberately destroys that PR's disposable database. Production data is never copied into previews. Old Docker image tags are retained for rollback; remove obsolete preview images periodically without pruning production volumes.

## Operations

```bash
cd ~/.local/share/almis/deploy
docker compose --env-file .env.production --env-file .env.stack -f compose.main.yml ps
docker compose --env-file .env.production --env-file .env.stack -f compose.main.yml logs --tail=100 api cloudflared
curl --fail -H 'Host: api.almishotel.com' http://127.0.0.1:8080/health
curl --fail https://api.almishotel.com/health
```

Do not print `docker compose config`, `docker inspect`, or env file contents in shared logs; they can include credentials. Use `docker compose config --quiet` to validate privately.

Back up the production database before accepting real guest data and before migrations. Write dumps to a protected directory and keep a copy on another machine. A named Docker volume survives container replacement, but it is not a backup.

If a migration fails, stop `api`, inspect the migration error, and repair the database. Use the same env-file flags with `docker compose run --rm --no-deps api npx prisma migrate resolve --rolled-back <name>` after undoing its changes, or `--applied` after completing the migration manually. Restart with `manage.py main --image <fixed-image>` after the database state is correct. Changing an image does not undo database migrations.

Do not run the existing development seed in production. It creates a known password. Create the initial admin with a separately generated credential and require a password change on first login.

This deployment depends on this machine staying powered on and Docker running. Suspend, lost connectivity, or a host reboot will interrupt service until the host and connector recover.

## Doppler

Doppler is optional. Separate production and preview configurations help with access sharing and centralized rotation. A single host can start with protected local env files. If Doppler is added later, use a read-only config-scoped service token, keep its bootstrap credential on the host, and write secrets into a private env file before recreating the API container. `doppler run -- docker compose ...` alone does not replace this stack's explicit `env_file` settings. Existing JWT keys and database passwords must be imported unchanged; rotating a Postgres password requires updating the database role as well as the env file.
