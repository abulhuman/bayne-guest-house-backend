#!/usr/bin/env bash
# Converges the Ubuntu-24.04 WSL distro into the Almis deployment host. Runs as root.
# Usage: wsl-provision.sh [--check]
# --check runs only the checks, prints each missing item, and exits 1 if any is missing.
# The loop in main calls the step functions as check_$id and set_$id.
# shellcheck disable=SC2329
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

readonly runner_dir=/home/almis/.local/share/almis/runner
readonly cf_version=1.0.0-beta.17
readonly keyrings=/etc/apt/keyrings
readonly base_packages=(ca-certificates curl python3 git)
readonly repo_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh nodejs)

wsl_conf() {
  cat <<'EOF'
[boot]
systemd=true

[user]
default=almis
EOF
}

runner_unit() {
  cat <<EOF
[Unit]
Description=Almis GitHub deployment runner
After=docker.service network-online.target
Wants=docker.service network-online.target
ConditionPathExists=$runner_dir/.runner

[Service]
User=almis
Group=almis
SupplementaryGroups=docker
WorkingDirectory=$runner_dir
ExecStart=$runner_dir/run.sh
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=/home/almis
Restart=always
RestartSec=10
TimeoutStopSec=300
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF
}

# Each source is "list-name keyring key-url repo-url suite components".
apt_sources() {
  local codename
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "docker docker.asc https://download.docker.com/linux/ubuntu/gpg https://download.docker.com/linux/ubuntu $codename stable"
  echo "github-cli githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg https://cli.github.com/packages stable main"
  echo "nodesource nodesource.asc https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key https://deb.nodesource.com/node_24.x nodistro main"
}

# Writes stdin to a file through a rename so an interrupted run never leaves it half written.
write_file() {
  local path=$1 mode=$2 tmp
  tmp=$(mktemp "$path.XXXXXX")
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

# curl -o leaves nothing at the destination when a download fails partway.
fetch() {
  local url=$1 path=$2 tmp
  tmp=$(mktemp "$path.XXXXXX")
  curl -fsSL -o "$tmp" "$url"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$path"
}

file_matches() { [[ -f $1 && $(cat "$1") == "$2" ]]; }

installed() {
  local package
  for package in "$@"; do
    [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) == 'install ok installed' ]] || return 1
  done
}

systemd_running() { [[ -d /run/systemd/system ]]; }

# Enabling only writes symlinks, so it works before systemd is PID 1. Docker test
# containers have no systemctl at all, and there the step is skipped with a warning.
enabled() {
  if ! command -v systemctl >/dev/null; then
    echo "warning: systemctl not found, cannot enable $*" >&2
    return 0
  fi
  systemctl is-enabled --quiet "$@" 2>/dev/null
}

check_wsl_conf() { file_matches /etc/wsl.conf "$(wsl_conf)"; }
set_wsl_conf() { wsl_conf | write_file /etc/wsl.conf 0644; }

check_user() {
  local entry
  entry=$(getent passwd almis) || return 1
  [[ $(cut -d: -f6,7 <<<"$entry") == /home/almis:/bin/bash && -d /home/almis ]]
}
set_user() {
  if getent passwd almis >/dev/null; then
    usermod -d /home/almis -s /bin/bash almis
    install -d -o almis -g almis -m 0750 /home/almis
  else
    useradd -m -d /home/almis -s /bin/bash almis
  fi
}

check_base_packages() { installed "${base_packages[@]}"; }
set_base_packages() {
  apt-get update -qq
  apt-get install -y -qq "${base_packages[@]}" >/dev/null
}

# A repository configured in any source file counts, so a source added by hand is never
# duplicated. Two entries for one repository with different keyrings break apt-get update.
configured() { grep -qsF -- "$1" /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; }

check_apt_sources() {
  local name keyring key repo suite
  while read -r name keyring key repo suite; do
    configured "$repo" || return 1
  done < <(apt_sources)
}
set_apt_sources() {
  local name keyring key repo suite arch
  arch=$(dpkg --print-architecture)
  install -m 0755 -d "$keyrings"
  while read -r name keyring key repo suite; do
    configured "$repo" && continue
    fetch "$key" "$keyrings/$keyring"
    echo "deb [arch=$arch signed-by=$keyrings/$keyring] $repo $suite" | write_file "/etc/apt/sources.list.d/$name.list" 0644
  done < <(apt_sources)
}

check_packages() {
  installed "${repo_packages[@]}" && [[ $(node --version 2>/dev/null) == v24.* ]]
}
set_packages() {
  apt-get update -qq
  apt-get install -y -qq "${repo_packages[@]}" >/dev/null
}

# NodeSource puts the npm global prefix at /usr, so cf lands in /usr/bin, which the runner PATH has.
check_cf() {
  [[ $(npm ls --global --depth=0 cf 2>/dev/null) == *"cf@$cf_version"* && -x /usr/bin/cf ]]
}
set_cf() { npm install --global --silent "cf@$cf_version"; }

check_docker_group() { [[ " $(id -nG almis 2>/dev/null) " == *' docker '* ]]; }
set_docker_group() { usermod -aG docker almis; }

check_docker_enabled() { enabled docker.service containerd.service; }
set_docker_enabled() { systemctl enable docker.service containerd.service; }

check_runner_unit() { file_matches /etc/systemd/system/almis-runner.service "$(runner_unit)"; }
set_runner_unit() {
  runner_unit | write_file /etc/systemd/system/almis-runner.service 0644
  if systemd_running; then
    systemctl daemon-reload
    systemctl try-restart almis-runner.service
  fi
}

check_runner_enabled() { enabled almis-runner.service; }
set_runner_enabled() { systemctl enable almis-runner.service; }

steps=(
  'wsl_conf|/etc/wsl.conf enables systemd and defaults to almis'
  'user|user almis exists'
  'base_packages|base packages installed'
  'apt_sources|Docker, GitHub CLI, and NodeSource apt sources'
  'packages|Docker Engine, gh, and Node.js 24 installed'
  "cf|cf@$cf_version installed globally"
  'docker_group|almis is in group docker'
  'docker_enabled|docker and containerd enabled'
  'runner_unit|almis-runner.service unit file'
  'runner_enabled|almis-runner.service enabled'
)

main() {
  local check_only=0 step id name missing=0
  case ${1:-} in
    --check) check_only=1 ;;
    '') ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
  esac
  for step in "${steps[@]}"; do
    id=${step%%|*}
    name=${step#*|}
    if "check_$id"; then
      ((check_only)) || echo "ok   $name"
    elif ((check_only)); then
      echo "missing $name"
      missing=1
    else
      "set_$id"
      "check_$id" || { echo "failed $name" >&2; exit 1; }
      echo "set  $name"
    fi
  done
  if ! ((check_only)) && ! systemd_running; then
    echo 'warning: systemd is not PID 1. Restart the distro to boot it.' >&2
  fi
  exit "$missing"
}

# bootstrap.ps1 feeds this file through bash -s. Detaching stdin keeps apt and npm
# from reading script text, and keeping main last means bash has parsed every function first.
main "$@" </dev/null
