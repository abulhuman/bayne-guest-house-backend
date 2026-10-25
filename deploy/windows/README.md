# Windows deployment host

This guide is for the operator who rebuilds the Windows machine that hosts the backend. The rehearsal host is `silver-satellite` on Tailscale, with the Windows admin user `orca`. The stack runs in WSL2 and follows the Linux flow in [../README.md](../README.md) unchanged.

`bootstrap.ps1` converges Windows. It pipes `wsl-provision.sh` into the distro to converge Linux. Both scripts are safe to rerun. A rerun on a converged machine changes nothing and exits 0.

## What it sets up

On Windows, `bootstrap.ps1` does the following.

- Checks that it runs elevated and that firmware virtualization is on.
- Stops the machine from sleeping on AC and battery, and makes closing the lid do nothing.
- Sets the connected Wi-Fi profile to connect automatically.
- Installs OpenSSH Server, starts it automatically, and disables password logins.
- Adds the firewall rule `sshd-tailscale`, which allows TCP 22 only from `100.64.0.0/10`, and disables the default `OpenSSH-Server-In-TCP` rule.
- Checks that the Tailscale service is installed and starts automatically, and turns on Tailscale unattended mode. Without it, Tailscale disconnects when the last user logs off, and the machine drops off the tailnet after every reboot until someone logs in.
- Enables the Windows features `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`.
- Installs the WSL package and writes `vmIdleTimeout=-1` and `instanceIdleTimeout=-1` to `%USERPROFILE%\.wslconfig`, so WSL never shuts down when idle.
- Installs the `Ubuntu-24.04` distro as WSL 2, provisions it, and restarts it once so systemd is PID 1.
- Registers the scheduled task `Almis WSL`. It runs `wsl.exe -d Ubuntu-24.04 -- sleep infinity` at boot, so WSL runs with nobody logged in. The script prompts for the admin user's Windows password when it registers the task.

Inside the distro, `wsl-provision.sh` does the following as root.

- Writes `/etc/wsl.conf` to boot systemd and make `almis` the default user.
- Creates the user `almis` and adds it to the `docker` group.
- Installs Docker Engine with Buildx and Compose, GitHub CLI, Node.js 24, Python 3, Git, and the Cloudflare CLI `cf@1.0.0-beta.17`.
- Enables `docker` and `containerd`.
- Installs and enables the system unit `almis-runner.service`. The unit stays inactive until the runner is registered.

The scripts do not register the runner, run `manage.py`, or log in to `gh` or `cf`. Those steps need a person and are listed below.

## Prerequisites

- Windows 10 or 11 Pro, version 22H2 or later.
- Intel VT-x or AMD-V enabled in the firmware setup.
- Tailscale installed and logged in.
- An OpenSSH key for the admin user. Windows reads admin keys from `C:\ProgramData\ssh\administrators_authorized_keys`, not from the user profile. The script never changes this file. Put the public key in it, then restrict its permissions from an elevated prompt.

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant SYSTEM:(F) /grant Administrators:(F)
```

Confirm that key login works before you run the script. The script turns off password logins.

## Running it

Copy the directory to the host and run the script over SSH. OpenSSH on Windows gives admin users an elevated session. Use `ssh -t` so the password prompt works.

```bash
scp -r deploy/windows silver-satellite:almis-bootstrap
ssh -t silver-satellite powershell -NoProfile -ExecutionPolicy Bypass -File almis-bootstrap/bootstrap.ps1
```

To copy a newer version later, delete `almis-bootstrap` on the host first. Otherwise `scp -r` nests the new copy inside the old one.

Each step prints `ok` when it was already converged or `set` when the script changed it. The script stops at the first step it cannot converge and names it.

Enabling the Windows features needs a restart. The script then exits with code 3010. Restart Windows, then run the same command again. Downloading WSL and the distro can take more than 10 minutes on a slow link. If a run is interrupted, run it again.

To verify the machine without changing it, add `-Check`. It runs only the tests and exits 1 if any step is not converged.

```bash
ssh silver-satellite powershell -NoProfile -ExecutionPolicy Bypass -File almis-bootstrap/bootstrap.ps1 -Check
```

The `Almis WSL` task stores `orca`'s password so it can start at boot with nobody logged in. Task Scheduler rejects a wrong password when the task is registered. If the password changes, the task stops starting. Delete the task with `Unregister-ScheduledTask -TaskName 'Almis WSL'` and rerun the script.

The S4U logon type, which stores no password, does not work. On `silver-satellite` an S4U task ran `wsl.exe` at boot and exited with `0xFFFFFFFF`, and the stack only came up after someone logged in. To avoid storing a password, rerun with `-AutostartLogon Interactive`. The task then starts when `orca` logs on, so the machine also needs Windows autologon to recover from a reboot.

## Manual steps after it converges

Run these once, in order. Open a shell in the distro as `almis` with `wsl -d Ubuntu-24.04`, then use a checkout of this repository.

1. Log in to the Cloudflare CLI. It prints a URL and a code. Approve the code in a browser on any machine.

   ```bash
   cf auth login --device --no-browser
   ```

2. Install the deployment files.

   ```bash
   python3 deploy/manage.py prepare
   ```

3. Copy the production secrets and the tunnel token into `~/.local/share/almis/deploy`, following [Files on the host](../README.md#files-on-the-host) and [Bootstrap](../README.md#bootstrap). Keep the files at mode `0600`.

4. Register the runner. Only one host can hold the runner name `almis-onprem`. If another host has it, run `config.sh remove` in that host's runner directory first. The command below needs `gh` logged in as a repository admin, or `GH_TOKEN` set for this one command.

   ```bash
   python3 deploy/register-runner.py --repo abulhuman/bayne-guest-house-backend
   ```

5. Start the runner. `almis` has no sudo, so run this from Windows.

   ```powershell
   wsl -d Ubuntu-24.04 -u root -- systemctl start almis-runner
   ```

## Operating notes

WSL runs only while the `Almis WSL` task holds it open. If the task stops, WSL shuts down and takes the stack with it. Check it with `Get-ScheduledTask -TaskName 'Almis WSL'`.

WSL forwards localhost, so `http://localhost:8080` on Windows reaches Traefik inside the distro. Use it for the health checks in [Operations](../README.md#operations).

The stack is down while the machine is off or asleep. The script disables sleep, but a manual shutdown or a Windows Update restart still stops service until the machine boots again.

On battery, the machine keeps running until the battery is empty, and then the stack dies. Keep it on AC power. The script warns when it runs on battery.

The runner unit is a system unit, not a `systemd --user` unit, because user sessions fail to start for users of this distro.
