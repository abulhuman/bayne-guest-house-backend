#!/usr/bin/env bash
# Every subcommand prints fixed-format lines and exits 0 on success, 1 on failure.
set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ID="${VERIFY_ID:-default}"
RUN_DIR="$ROOT/.verify/run-$ID"
EVIDENCE_ROOT="$ROOT/.verify/evidence/$ID"
STATE="$RUN_DIR/state.env"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD="admin123"
PG_PKG="@embedded-postgres/linux-x64@16.14.0-beta.17"
PG_HOME="$ROOT/.verify/tools/node_modules/@embedded-postgres/linux-x64"
PG_BIN="$PG_HOME/native/bin"
declare -A DEMO_NAME=([admin]="Abdirahman Ali" [manager]="Mohamed Hassan" [reception]="Ayaan Hassan" [housekeeping]="Fadumo Ahmed"
  [barista]="Abdi Yusuf" [security]="Abdullahi Omar" [finance]="Maryan Ibrahim" [store]="Hamza Osman")

EXTRA_HEADERS=()

die() { echo "FAIL $*"; exit 1; }

load_state() {
  [[ -f "$STATE" ]] || die "no-instance run 'control.sh up' first (VERIFY_ID=$ID)"
  source "$STATE"
}

free_port() { node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }

# Short HEAD, plus a hash of every change under src and prisma, untracked files included.
tree_rev() {
  local head changes
  head="$(git -C "$ROOT" rev-parse --short HEAD)"
  changes="$( { git -C "$ROOT" diff --binary HEAD -- src prisma; (cd "$ROOT" && git ls-files -o --exclude-standard -z -- src prisma | xargs -0 -r sha1sum); } )"
  if [[ -z "$changes" ]]; then echo "$head"; else echo "$head-dirty-$(printf '%s' "$changes" | sha1sum | cut -c1-8)"; fi
}

ready_line() { echo "READY base=$BASE_URL id=$ID rev=$GIT_REV evidence=$EVIDENCE_DIR names=${NAMES_MODE:-verify}"; }

server_alive() {
  [[ -z "${SERVER_PID:-}" && -s "$RUN_DIR/server.pid" ]] && SERVER_PID="$(cat "$RUN_DIR/server.pid")"
  [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null &&
    tr '\0' ' ' <"/proc/$SERVER_PID/cmdline" 2>/dev/null | grep -q "dist/src/main" &&
    [[ "$(readlink "/proc/$SERVER_PID/cwd" 2>/dev/null)" == "$ROOT" ]]
}

http() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  rm -f "$RUN_DIR/last.body"
  local args=(-sS --max-time 30 -o "$RUN_DIR/last.body" -w '%{http_code}' -X "$method" "$BASE_URL$path")
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  local h; for h in "${EXTRA_HEADERS[@]}"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
  local code
  code="$(curl "${args[@]}" 2>>"$RUN_DIR/curl.log")" || code=000
  echo "$code"
}

cmd_up() {
  local names
  case "${DEMO_NAMES:-}" in
    ""|0) names=verify ;;
    1) names=demo ;;
    *) die "bad-demo-names want=1|0|unset got=$DEMO_NAMES" ;;
  esac
  if [[ -f "$STATE" ]]; then
    local report
    if report="$(cmd_doctor)" && [[ "$report" != *"STALE build-rev"* && "$report" == *"OK names=$names"* ]]; then load_state; ready_line; return 0; fi
    cmd_down | grep -v '^DOWN ' || true
    [[ -d "$RUN_DIR" ]] && exit 1
  fi
  local evidence="$EVIDENCE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$RUN_DIR" "$evidence"
  local log="$RUN_DIR/up.log"; : >"$log"

  [[ -d "$ROOT/node_modules/@nestjs/core" ]] || (cd "$ROOT" && bun install --frozen-lockfile >>"$log" 2>&1) || die "install log=$log"
  (cd "$ROOT" && bunx prisma generate >>"$log" 2>&1) || die "prisma-generate log=$log"

  if [[ ! -f "$PG_HOME/.hydrated" ]]; then
    npm install --prefix "$ROOT/.verify/tools" --no-audit --no-fund "$PG_PKG" >>"$log" 2>&1 || die "install-postgres log=$log"
    (cd "$PG_HOME" && node scripts/hydrate-symlinks.js >>"$log" 2>&1 && touch .hydrated) || die "hydrate-postgres log=$log"
  fi
  local pg_port app_port
  pg_port="$(free_port)"; app_port="$(free_port)"
  if [[ -d "$RUN_DIR/pgdata" ]]; then
    "$PG_BIN/pg_ctl" -D "$RUN_DIR/pgdata" -m fast stop >>"$log" 2>&1 || true
    rm -rf "$RUN_DIR/pgdata"
  fi
  "$PG_BIN/initdb" -D "$RUN_DIR/pgdata" -U postgres --auth=trust >>"$log" 2>&1 || die "initdb log=$log"
  "$PG_BIN/pg_ctl" -D "$RUN_DIR/pgdata" -l "$RUN_DIR/postgres.log" -w -t 60 \
    -o "-p $pg_port -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >>"$log" 2>&1 || die "postgres-start log=$RUN_DIR/postgres.log"
  psql -h 127.0.0.1 -p "$pg_port" -U postgres -d postgres -c 'create database bgh' >>"$log" 2>&1 || die "createdb log=$log"
  local db_url="postgresql://postgres@127.0.0.1:$pg_port/bgh?schema=public"
  cat >"$STATE" <<EOF
EVIDENCE_DIR=$evidence
PG_PORT=$pg_port
DATABASE_URL='$db_url'
APP_PORT=$app_port
BASE_URL=http://127.0.0.1:$app_port
JWT_SECRET=verify-jwt-secret
ATTENDANCE_API_KEY=verify-attendance-key
GIT_REV=$(tree_rev)
NAMES_MODE=$names
EOF

  local i
  (cd "$ROOT" && DATABASE_URL="$db_url" DIRECT_URL="$db_url" bunx prisma migrate deploy >>"$log" 2>&1) || die "migrate log=$log"
  (cd "$ROOT" && DATABASE_URL="$db_url" DIRECT_URL="$db_url" bunx prisma db seed >>"$log" 2>&1) || die "seed log=$log"
  if [[ "$names" == demo ]]; then
    [[ "$(psql -h 127.0.0.1 -p "$pg_port" -U postgres -d bgh -At -v ON_ERROR_STOP=1 \
      -c "update \"User\" set name = '${DEMO_NAME[admin]}' where email = '$ADMIN_EMAIL'" 2>>"$log")" == "UPDATE 1" ]] || die "demo-names log=$log"
  fi
  (cd "$ROOT" && bun run build >>"$log" 2>&1) || die "build log=$log"

  (cd "$ROOT" && exec env DATABASE_URL="$db_url" DIRECT_URL="$db_url" PORT="$app_port" HOST=127.0.0.1 \
    JWT_SECRET=verify-jwt-secret ATTENDANCE_API_KEY=verify-attendance-key \
    nohup node dist/src/main >"$RUN_DIR/server.log" 2>&1) &
  echo "SERVER_PID=$!" >>"$STATE"
  echo "$!" >"$RUN_DIR/server.pid"
  load_state

  for i in $(seq 60); do
    [[ "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$BASE_URL/health")" == 200 ]] && break
    server_alive || die "server-exited log=$RUN_DIR/server.log"
    sleep 1
  done
  [[ "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$BASE_URL/health")" == 200 ]] || die "health-timeout log=$RUN_DIR/server.log"
  ready_line
}

cmd_doctor() {
  local fails=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "OK $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
  [[ -f "$STATE" ]] || { echo "FAIL state no-instance"; echo "DOCTOR FAIL"; return 1; }
  load_state
  check postgres "pg_isready -h 127.0.0.1 -p $PG_PORT -U postgres"
  check server-pid "server_alive"
  check port-owner "ss -ltnpH 'sport = :$APP_PORT' | grep -q 'pid=$SERVER_PID,'"
  check health "[[ \$(curl -s --max-time 10 $BASE_URL/health | jq -r .ok) == true ]]"
  check admin-login "[[ \$(http POST /auth/login '' '{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}') == 201 ]]"
  echo "OK names=${NAMES_MODE:-verify}"
  local head; head="$(tree_rev)"
  if [[ "$head" == "$GIT_REV" ]]; then echo "OK build-rev $GIT_REV"; else echo "STALE build-rev built=$GIT_REV now=$head (the next up rebuilds)"; fi
  if (( fails == 0 )); then echo "DOCTOR PASS base=$BASE_URL"; else echo "DOCTOR FAIL"; return 1; fi
}

cmd_token() {
  local role="${1:?usage: token <role>}"
  load_state
  local cache="$RUN_DIR/token-$role"
  [[ -s "$cache" ]] && { cat "$cache"; return 0; }
  local email="$ADMIN_EMAIL" password="$ADMIN_PASSWORD"
  if [[ "$role" != admin ]]; then
    email="verify-$role@example.com"; password="verify-pass-$role"
    local name="Verify $role"
    if [[ "${NAMES_MODE:-verify}" == demo ]]; then name="${DEMO_NAME[$role]-}"; [[ -n "$name" ]] || die "no-demo-name role=$role"; fi
    local admin; admin="$(cmd_token admin)" || { echo "$admin"; exit 1; }
    local code; code="$(http POST /staff "$admin" "$(jq -nc --arg n "$name" --arg r "$role" --arg e "$email" --arg p "$password" \
      '{name:$n, role:$r, phone:"0911000000", username:$e, password:$p, forceChangePassword:false}')")"
    [[ "$code" == 201 ]] || die "create-staff role=$role http=$code body=$(cat "$RUN_DIR/last.body")"
  fi
  local code; code="$(http POST /auth/login '' "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')")"
  [[ "$code" == 201 ]] || die "login role=$role http=$code body=$(cat "$RUN_DIR/last.body")"
  jq -er .access_token "$RUN_DIR/last.body" >"$cache" || die "no-token role=$role"
  cat "$cache"
}

cmd_call() {
  local expect=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --expect) expect="$2" ;;
      --header) EXTRA_HEADERS+=("$2") ;;
      *) die "unknown-flag $1" ;;
    esac
    shift 2
  done
  local who="${1:?usage: call [--expect CODE] [--header 'K: V'] <role|anon> <METHOD> <PATH> [JSON]}" method="${2:?}" path="${3:?}" body="${4:-}"
  load_state
  rm -f "$RUN_DIR/last.json"
  local token=""
  [[ "$who" != anon ]] && { token="$(cmd_token "$who")" || { echo "$token"; exit 1; }; }
  local code; code="$(http "$method" "$path" "$token" "$body")"
  [[ "$code" == 000 ]] && die "http-unreachable base=$BASE_URL (dead, cut off, or slower than 30s; see $RUN_DIR/curl.log and run 'control.sh doctor')"
  local seq; seq=$(( $(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.json' | wc -l) + 1 ))
  local file; file="$EVIDENCE_DIR/$(printf '%03d' "$seq")-$who-$method-$(echo "$path" | tr -c 'a-zA-Z0-9\n' '_' | cut -c2-60).json"
  # The body goes through a file because a large one passed as an argument exceeds the kernel's argument limit.
  local resp="$RUN_DIR/last.resp"
  if [[ ! -s "$RUN_DIR/last.body" ]]; then echo null >"$resp"
  elif ! jq -c . "$RUN_DIR/last.body" >"$resp" 2>/dev/null; then jq -Rsc . "$RUN_DIR/last.body" >"$resp"; fi
  local hdrs; hdrs="$(printf '%s\n' "${EXTRA_HEADERS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')"
  jq -n --arg who "$who" --arg m "$method" --arg p "$path" --arg b "$body" --argjson h "$hdrs" --argjson s "$code" --slurpfile r "$resp" \
    --arg at "$(date -u +%FT%TZ)" '{at:$at, request:{as:$who, method:$m, path:$p, headers:$h, body:($b|fromjson? // $b)}, response:{status:$s, body:$r[0]}}' >"$file" ||
    { rm -f "$file"; die "write-evidence file=$file"; }
  cp "$file" "$RUN_DIR/last.json"
  echo "HTTP $code"
  echo "EVIDENCE $file"
  jq -c .response.body "$file"
  if [[ -n "$expect" && "$code" != "$expect" ]]; then echo "EXPECT FAIL want=$expect got=$code"; return 1; fi
  [[ -n "$expect" ]] && echo "EXPECT OK $code"
  return 0
}

cmd_last() {
  load_state
  local out; out="$(jq -er ".response.body | ${1:-.}" "$RUN_DIR/last.json" 2>/dev/null)" || die "last filter=${1:-} is false, null or missing"
  echo "$out"
}

cmd_sql() {
  local q="${1:?usage: sql \"<query>\"}"
  load_state
  local out; out="$(psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d bgh -At -F '|' -v ON_ERROR_STOP=1 -c "$q" 2>&1)" || die "sql $out"
  local seq; seq=$(( $(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.json' | wc -l) + 1 ))
  local file; file="$EVIDENCE_DIR/$(printf '%03d' "$seq")-sql.json"
  printf '%s' "$out" | jq -Rs --arg q "$q" --arg at "$(date -u +%FT%TZ)" '{at:$at, sql:$q, rows:split("\n")}' >"$file" ||
    { rm -f "$file"; die "write-evidence file=$file"; }
  echo "EVIDENCE $file"
  echo "$out"
}

cmd_down() {
  [[ -d "$RUN_DIR" ]] || { echo "DOWN nothing-running evidence=$EVIDENCE_ROOT"; return 0; }
  [[ -f "$STATE" ]] && source "$STATE"
  if server_alive; then kill "$SERVER_PID"; sleep 1; server_alive && kill -9 "$SERVER_PID"; fi
  server_alive && die "server-stop pid=$SERVER_PID run=$RUN_DIR"
  if [[ -d "$RUN_DIR/pgdata" ]]; then
    "$PG_BIN/pg_ctl" -D "$RUN_DIR/pgdata" -m fast -w stop >/dev/null 2>&1
    "$PG_BIN/pg_ctl" -D "$RUN_DIR/pgdata" status >/dev/null 2>&1 && die "postgres-stop run=$RUN_DIR"
  fi
  local keep="${EVIDENCE_DIR:-$EVIDENCE_ROOT/failed-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$keep"
  cp "$RUN_DIR"/*.log "$keep/" 2>/dev/null
  rm -rf "$RUN_DIR"
  echo "DOWN ok evidence=$keep"
}

case "${1:-}" in
  up|doctor|token|call|last|sql|down) c="$1"; shift; "cmd_$c" "$@" ;;
  *) echo "usage: control.sh up|doctor|token <role>|call [--expect CODE] [--header 'K: V'] <role|anon> <METHOD> <PATH> [JSON]|last [jq-path]|sql \"<query>\"|down"; exit 1 ;;
esac
