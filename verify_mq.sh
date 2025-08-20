#!/usr/bin/env bash
# =============================================================================
# Script Name : verify_mq.sh
# Purpose     : Verify a single IBM MQ queue manager is healthy (status, TCP,
#               and an optional bindings/client put/get sanity check).
#
# Usage:
#   ./verify_mq.sh                 # full verification (bindings loopback if possible)
#   ./verify_mq.sh --check-only    # skip put/get tests, just status + TCP probe
#   ./verify_mq.sh --help
#
# Environment overrides (export before run or inline KEY=VAL ./verify_mq.sh):
#   QM_NAME=QM1                    # queue manager name
#   TARGET=qm1                     # container name; if empty → run commands locally
#   HOST=127.0.0.1                 # host to TCP-probe (for listeners)
#   PORT=1414                      # port to TCP-probe
#   CHANNEL=DEV.APP.SVRCONN        # for optional client test (amqsputc/amqsgetc)
#   DO_CLIENT_TEST=false           # true = run client-mode put/get via HOST:PORT
#   CHECK_ONLY=false               # true = skip put/get tests entirely
#   RETRY_SLEEP=3                  # seconds between role/status polls
#   TIMEOUT=60                     # total seconds to wait for RUNNING status
#
# Exit codes: 0 success; non-zero on any failed check
# =============================================================================

set -euo pipefail

# -------- Defaults --------
QM_NAME="${QM_NAME:-QM1}"
TARGET="${TARGET:-}"             # if set → container name for docker exec
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-1414}"
CHANNEL="${CHANNEL:-DEV.APP.SVRCONN}"
DO_CLIENT_TEST="${DO_CLIENT_TEST:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
RETRY_SLEEP="${RETRY_SLEEP:-3}"
TIMEOUT="${TIMEOUT:-60}"

# -------- CLI --------
usage() {
  cat <<USAGE
Usage: $0 [--check-only] [--help]

Options:
  --check-only   Skip put/get tests; perform status + TCP probe only
  --help         Show this help

Environment (examples):
  QM_NAME=${QM_NAME} TARGET=${TARGET:-<empty_for_local>} HOST=${HOST} PORT=${PORT} CHANNEL=${CHANNEL}
  DO_CLIENT_TEST=${DO_CLIENT_TEST} CHECK_ONLY=${CHECK_ONLY} RETRY_SLEEP=${RETRY_SLEEP} TIMEOUT=${TIMEOUT}
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true; shift;;
    -h|--help)    usage;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# -------- Colors & helpers --------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;36m"; NC="\033[0m"
die(){ echo -e "${RED}❌ $*${NC}"; exit 1; }
ok(){  echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

# If TARGET set, run inside container; else run locally
exec_mq() {
  local cmd=". /opt/mqm/bin/setmqenv -s; $*"
  if [[ -n "$TARGET" ]]; then docker exec "$TARGET" bash -lc "$cmd"; else bash -lc "$cmd"; fi
}

# Generic shell exec (non-MQ)
exec_sh() {
  if [[ -n "$TARGET" ]]; then docker exec "$TARGET" bash -lc "$*"; else bash -lc "$*"; fi
}

# TCP probe without nc
tcp_probe() {
  local host="$1" port="$2"
  ( bash -c "exec 3<>/dev/tcp/${host}/${port}" ) >/dev/null 2>&1
}

# Check whether MQ sample binaries exist (bindings) in context
have_bindings_samples() {
  exec_sh "[ -x /opt/mqm/samp/bin/amqsput ] && [ -x /opt/mqm/samp/bin/amqsget ]" >/dev/null 2>&1
}

# Check whether MQ client samples exist (client) in context
have_client_samples() {
  exec_sh "[ -x /opt/mqm/samp/bin/amqsputc ] && [ -x /opt/mqm/samp/bin/amqsgetc ]" >/dev/null 2>&1
}

# -------- Preflight --------
if [[ -n "$TARGET" ]]; then
  need docker
  docker ps --format '{{.Names}}' | grep -qx "$TARGET" || die "Container '$TARGET' not running"
  ok "Container detected: ${TARGET}"
else
  ok "Local mode (no container)"
fi

# -------- 1) Queue manager status --------
info "Checking status of ${QM_NAME} (waiting up to ${TIMEOUT}s for RUNNING)..."
t=0
while true; do
  set +e
  out="$(exec_mq "dspmq -m ${QM_NAME} -o status" 2>/dev/null)"; rc=$?
  set -e
  if [[ $rc -eq 0 ]] && echo "$out" | grep -q "STATUS\(.*\)Running"; then
    ok "${QM_NAME} is RUNNING"
    break
  fi
  [[ $t -ge $TIMEOUT ]] && { echo "$out" | sed -e 's/^/  /'; die "${QM_NAME} not RUNNING within ${TIMEOUT}s"; }
  sleep "$RETRY_SLEEP"; t=$((t+RETRY_SLEEP))
done

# -------- 2) Listener/TCP probe --------
info "Probing TCP ${HOST}:${PORT}…"
if tcp_probe "$HOST" "$PORT"; then
  ok "TCP listener reachable on ${HOST}:${PORT}"
else
  warn "TCP ${HOST}:${PORT} not reachable — ensure a listener is started & mapped."
fi

# Short MQSC snapshot (best-effort; not fatal)
set +e
snap="$(exec_mq "echo 'DIS QMGR' | runmqsc ${QM_NAME} 2>/dev/null" || true)"
set -e
if [[ -n "${snap:-}" ]]; then
  info "Basic MQSC snapshot (DIS QMGR):"
  echo "$snap" | sed -e 's/^/  /' | head -n 8
fi

# Early exit if only checking
if [[ "${CHECK_ONLY}" == "true" ]]; then
  ok "--check-only complete (status + TCP verified)."
  exit 0
fi

# -------- 3) Bindings loopback put/get (preferred if available) --------
TESTQ="VERIFY.SINGLE.Q"
STAMP="stamp-$(date +%s)"

if have_bindings_samples; then
  info "Running server-bindings put/get loopback on ${QM_NAME} (queue ${TESTQ})…"
  exec_mq "cat <<'MQSC' | runmqsc ${QM_NAME}
DEFINE QLOCAL(${TESTQ}) REPLACE
MQSC" >/dev/null

  set +e
  exec_mq "printf '%s\n' '${STAMP}' | /opt/mqm/samp/bin/amqsput ${TESTQ} ${QM_NAME} >/tmp/put.log 2>&1"
  exec_mq "/opt/mqm/samp/bin/amqsget ${TESTQ} ${QM_NAME} >/tmp/get.log 2>&1"
  got="$(exec_sh "grep -m1 -F '${STAMP}' /tmp/get.log 2>/dev/null" || true)"
  set -e

  exec_mq "cat <<'MQSC' | runmqsc ${QM_NAME}
DELETE QLOCAL(${TESTQ})
MQSC" >/dev/null 2>&1 || true

  if [[ -n "${got}" ]]; then
    ok "Bindings put/get loopback succeeded."
  else
    die "Bindings put/get failed (see /tmp/put.log and /tmp/get.log ${TARGET:+in container})."
  fi
else
  warn "Bindings samples not found; skipping bindings test."
fi

# -------- 4) Optional client-mode put/get via HOST:PORT --------
if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
  if have_client_samples; then
    info "Running client-mode put/get via ${HOST}:${PORT}, channel ${CHANNEL}…"
    # Make a temporary model/local queue for the test (server-side)
    exec_mq "cat <<'MQSC' | runmqsc ${QM_NAME}
DEFINE QLOCAL(${TESTQ}) REPLACE
MQSC" >/dev/null

    # amqsputc/amqsgetc use CCDT/env normally; we can use MQSERVER for simple tests
    set +e
    exec_sh "export MQSERVER='${CHANNEL}/TCP/${HOST}(${PORT})'; printf '%s\n' '${STAMP}' | /opt/mqm/samp/bin/amqsputc ${TESTQ} ${QM_NAME} >/tmp/putc.log 2>&1"
    exec_sh "export MQSERVER='${CHANNEL}/TCP/${HOST}(${PORT})'; /opt/mqm/samp/bin/amqsgetc ${TESTQ} ${QM_NAME} >/tmp/getc.log 2>&1"
    gotc="$(exec_sh "grep -m1 -F '${STAMP}' /tmp/getc.log 2>/dev/null" || true)"
    set -e

    exec_mq "cat <<'MQSC' | runmqsc ${QM_NAME}
DELETE QLOCAL(${TESTQ})
MQSC" >/dev/null 2>&1 || true

    if [[ -n "${gotc}" ]]; then
      ok "Client-mode put/get via ${HOST}:${PORT} succeeded."
    else
      die "Client-mode put/get failed (see /tmp/putc.log and /tmp/getc.log ${TARGET:+in container})."
    fi
  else
    warn "Client samples not found; skipping client-mode test."
  fi
fi

ok "Single queue manager verification completed successfully."