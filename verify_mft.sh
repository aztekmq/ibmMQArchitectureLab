Sweet — here’s a **single-shot verifier** that creates test files, runs an end-to-end transfer **AGENT\_REM → AGENT\_LCL**, verifies content, and (optionally) runs a reverse + wildcard transfer. It assumes the same container/QM/agent names from your build script.

Save as `verify_mft.sh`, make executable, and run:

```bash
chmod +x verify_mft.sh
./verify_mft.sh                 # forward transfer (REM -> LCL)
./verify_mft.sh --reverse       # also do LCL -> REM reply
./verify_mft.sh --wildcard      # also do REM -> LCL directory sync
./verify_mft.sh --reverse --wildcard
```

---

```bash
#!/usr/bin/env bash
# =============================================================================
# Script Name : verify_mft.sh
# Purpose     : End-to-end smoke test for IBM MQ MFT across 4-container layout
#               - Forward transfer:  AGENT_REM (mftagent)  -> AGENT_LCL (qmagent)
#               - Optional reverse:  AGENT_LCL (qmagent)   -> AGENT_REM (mftagent)
#               - Optional wildcard: copy *.txt REM -> LCL
#
# Defaults assume the build script provisioned:
#   Containers : qmcoord, qmcmd, qmagent, mftagent
#   QMs        : QMCOORD, QMCMD, QMAGENT
#   Domain     : MFTDOM
#   Agents     : AGENT_LCL (on qmagent), AGENT_REM (on mftagent)
#
# Usage:
#   ./verify_mft.sh [--reverse] [--wildcard]
#
# Customize via env vars:
#   CMD_CNAME=qmcmd COORD_CNAME=qmcoord AGENT_CNAME=qmagent REM_CNAME=mftagent \
#   DOMAIN=MFTDOM AGENT_LCL=AGENT_LCL AGENT_REM=AGENT_REM ./verify_mft.sh
#
# Exit codes:
#   0 = success, non-zero = failure
# =============================================================================

set -euo pipefail

# --------- Config (overridable by env) ----------
CMD_CNAME="${CMD_CNAME:-qmcmd}"
COORD_CNAME="${COORD_CNAME:-qmcoord}"
AGENT_CNAME="${AGENT_CNAME:-qmagent}"   # container that hosts QMAGENT + AGENT_LCL
REM_CNAME="${REM_CNAME:-mftagent}"       # agent-only container (AGENT_REM)

QM_COORD="${QM_COORD:-QMCOORD}"
QM_CMD="${QM_CMD:-QMCMD}"
QM_AGENT="${QM_AGENT:-QMAGENT}"

DOMAIN="${DOMAIN:-MFTDOM}"
AGENT_LCL="${AGENT_LCL:-AGENT_LCL}"     # runs in $AGENT_CNAME
AGENT_REM="${AGENT_REM:-AGENT_REM}"     # runs in $REM_CNAME

SRC_DIR_REM="${SRC_DIR_REM:-/var/mqm/mqft/src}"
DST_DIR_LCL="${DST_DIR_LCL:-/var/mqm/mqft/dst}"

# Options
DO_REVERSE=false
DO_WILDCARD=false

# Timing
RETRY_SLEEP="${RETRY_SLEEP:-2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"   # seconds per check

# --------- CLI args ----------
for arg in "$@"; do
  case "$arg" in
    --reverse)  DO_REVERSE=true ;;
    --wildcard) DO_WILDCARD=true ;;
    -h|--help)
      echo "Usage: $0 [--reverse] [--wildcard]"
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --------- Colors ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;36m"; NC="\033[0m"
die() { echo -e "${RED}❌ $*${NC}"; exit 1; }
ok()  { echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }

# --------- Helpers ----------
needs_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

docker_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

mft_cli_exists() {
  docker exec "$1" bash -lc "[ -x /opt/mqm/mqft/bin/fteCreateTransfer ]"
}

wait_for_file() {
  local cname="$1" path="$2" t=0
  while ! docker exec "$cname" bash -lc "[ -s '$path' ]" >/dev/null 2>&1; do
    sleep "$RETRY_SLEEP"; t=$((t+RETRY_SLEEP))
    if (( t >= WAIT_TIMEOUT )); then
      return 1
    fi
  done
  return 0
}

exec_cmd() {
  local cname="$1"; shift
  docker exec "$cname" bash -lc "$*"
}

fte_from_cmd() {
  exec_cmd "$CMD_CNAME" ". /opt/mqm/bin/setmqenv -s; $*"
}

# --------- Preflight ----------
needs_bin docker
for c in "$CMD_CNAME" "$COORD_CNAME" "$AGENT_CNAME" "$REM_CNAME"; do
  docker_running "$c" || die "Container '$c' is not running"
done
ok "All containers are running."

for c in "$CMD_CNAME" "$COORD_CNAME" "$AGENT_CNAME" "$REM_CNAME"; do
  if ! mft_cli_exists "$c"; then
    die "MFT CLI not found in '$c' (/opt/mqm/mqft/bin). Use an MQ Advanced image."
  fi
done
ok "MFT CLI detected in all containers."

# Quick agent ping from command server
info "Pinging agents from $CMD_CNAME..."
fte_from_cmd "/opt/mqm/mqft/bin/ftePingAgent -d ${DOMAIN} ${AGENT_LCL}" | sed -n '1,60p' || true
fte_from_cmd "/opt/mqm/mqft/bin/ftePingAgent -d ${DOMAIN} ${AGENT_REM}" | sed -n '1,60p' || true

# --------- Prepare test files/folders ----------
info "Preparing source on ${REM_CNAME}:${SRC_DIR_REM} and destination on ${AGENT_CNAME}:${DST_DIR_LCL}..."
exec_cmd "$REM_CNAME"  "mkdir -p '${SRC_DIR_REM}'; echo \"Hello from REM \$(date -Is)\" > '${SRC_DIR_REM}/hello.txt'; ls -l '${SRC_DIR_REM}'"
exec_cmd "$AGENT_CNAME" "mkdir -p '${DST_DIR_LCL}'; ls -ld '${DST_DIR_LCL}'"
ok "Prep complete."

# --------- Forward transfer: REM -> LCL ----------
info "Submitting forward transfer: ${AGENT_REM} → ${AGENT_LCL}"
fte_from_cmd "/opt/mqm/mqft/bin/fteCreateTransfer \
  -d '${DOMAIN}' \
  -sa '${AGENT_REM}' \
  -da '${AGENT_LCL}' \
  -sm once \
  -de overwrite \
  -v \
  -s '${SRC_DIR_REM}/hello.txt' \
  -d '${DST_DIR_LCL}/hello.txt'"

info "Waiting for file on ${AGENT_CNAME}:${DST_DIR_LCL}/hello.txt ..."
if wait_for_file "$AGENT_CNAME" "${DST_DIR_LCL}/hello.txt"; then
  ok "Forward transfer completed."
  exec_cmd "$AGENT_CNAME" "echo '---- DEST CONTENT ----'; cat '${DST_DIR_LCL}/hello.txt'"
else
  warn "File not detected within ${WAIT_TIMEOUT}s. Checking recent transfers and logs..."
  fte_from_cmd "/opt/mqm/mqft/bin/fteListTransfers -d '${DOMAIN}' -status recent | sed -n '1,160p'"
  exec_cmd "$AGENT_CNAME" "tail -n 120 /var/mqm/mqft/logs/${AGENT_LCL}/agent.log || true"
  exec_cmd "$REM_CNAME"   "tail -n 120 /var/mqm/mqft/logs/${AGENT_REM}/agent.log || true"
  die "Forward transfer failed or timed out."
fi

# --------- Optional reverse: LCL -> REM ----------
if $DO_REVERSE; then
  info "Preparing reply on LCL and transferring back to REM..."
  exec_cmd "$AGENT_CNAME" "echo \"Reply from LCL \$(date -Is)\" > '${DST_DIR_LCL}/reply.txt'; ls -l '${DST_DIR_LCL}/reply.txt'"

  fte_from_cmd "/opt/mqm/mqft/bin/fteCreateTransfer \
    -d '${DOMAIN}' \
    -sa '${AGENT_LCL}' \
    -da '${AGENT_REM}' \
    -sm once \
    -de overwrite \
    -v \
    -s '${DST_DIR_LCL}/reply.txt' \
    -d '${SRC_DIR_REM}/reply.txt'"

  info "Waiting for file on ${REM_CNAME}:${SRC_DIR_REM}/reply.txt ..."
  if wait_for_file "$REM_CNAME" "${SRC_DIR_REM}/reply.txt"; then
    ok "Reverse transfer completed."
    exec_cmd "$REM_CNAME" "echo '---- REM CONTENT ----'; cat '${SRC_DIR_REM}/reply.txt'"
  else
    warn "File not detected within ${WAIT_TIMEOUT}s. Checking logs..."
    fte_from_cmd "/opt/mqm/mqft/bin/fteListTransfers -d '${DOMAIN}' -status recent | sed -n '1,160p'"
    exec_cmd "$AGENT_CNAME" "tail -n 120 /var/mqm/mqft/logs/${AGENT_LCL}/agent.log || true"
    exec_cmd "$REM_CNAME"   "tail -n 120 /var/mqm/mqft/logs/${AGENT_REM}/agent.log || true"
    die "Reverse transfer failed or timed out."
  fi
fi

# --------- Optional wildcard: REM *.txt -> LCL dir ----------
if $DO_WILDCARD; then
  info "Creating 3 sample files on REM and transferring all *.txt to LCL directory..."
  exec_cmd "$REM_CNAME" "for i in 1 2 3; do echo \"file \$i @ \$(date -Is)\" > '${SRC_DIR_REM}/file'\$i'.txt'; done; ls -l '${SRC_DIR_REM}'"

  fte_from_cmd "/opt/mqm/mqft/bin/fteCreateTransfer \
    -d '${DOMAIN}' \
    -sa '${AGENT_REM}' \
    -da '${AGENT_LCL}' \
    -sm once \
    -de overwrite \
    -v \
    -s '${SRC_DIR_REM}/*.txt' \
    -d '${DST_DIR_LCL}/'"

  # Wait for a sentinel (file3.txt) to arrive
  if wait_for_file "$AGENT_CNAME" "${DST_DIR_LCL}/file3.txt"; then
    ok "Wildcard transfer completed."
    exec_cmd "$AGENT_CNAME" "ls -l '${DST_DIR_LCL}'"
  else
    warn "Wildcard files not detected within ${WAIT_TIMEOUT}s. Checking logs..."
    fte_from_cmd "/opt/mqm/mqft/bin/fteListTransfers -d '${DOMAIN}' -status recent | sed -n '1,160p'"
    exec_cmd "$AGENT_CNAME" "tail -n 120 /var/mqm/mqft/logs/${AGENT_LCL}/agent.log || true"
    exec_cmd "$REM_CNAME"   "tail -n 120 /var/mqm/mqft/logs/${AGENT_REM}/agent.log || true"
    die "Wildcard transfer failed or timed out."
  fi
fi

# --------- Show recent transfers & tail logs ----------
info "Recent transfer summary:"
fte_from_cmd "/opt/mqm/mqft/bin/fteListTransfers -d '${DOMAIN}' -status recent | sed -n '1,180p'"

info "Agent log tails (last 60 lines):"
exec_cmd "$AGENT_CNAME" "echo '--- ${AGENT_LCL} (LCL) ---'; tail -n 60 /var/mqm/mqft/logs/${AGENT_LCL}/agent.log || true"
exec_cmd "$REM_CNAME"   "echo '--- ${AGENT_REM} (REM) ---'; tail -n 60 /var/mqm/mqft/logs/${AGENT_REM}/agent.log || true"

ok "MFT smoke test completed successfully."
