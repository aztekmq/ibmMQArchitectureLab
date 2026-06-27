#!/usr/bin/env bash
# =============================================================================
# Script Name : verify_mi.sh
# Purpose     : Verify a container-based IBM MQ Multi-Instance QM environment.
#
# What it verifies (no MFT involved):
#   1) Containers up (default: qm1a, qm1b) and QM present on shared storage
#   2) Roles: ACTIVE vs STANDBY (via dspmq)
#   3) Shared storage is truly the same (hash of /mnt/mqm/qmgrs/$QM_NAME/qm.ini)
#   4) TCP behavior: ACTIVE host port accepts; STANDBY host port should refuse
#   5) VIP (HAProxy) health, if running (container: mq-vip)
#   6) Optional failover simulation (--simulate-failover), then restore MI state
#
# Usage:
#   ./verify_mi.sh                     # full verification (no failover)
#   ./verify_mi.sh --simulate-failover # includes controlled role swap & restore
#   ./verify_mi.sh --check-only        # skips VIP & TCP/put/get extras
#   ./verify_mi.sh --help
#
# Env overrides (set before running if different names/ports/creds):
#   QM_NAME=QM1 MI_A=qm1a MI_B=qm1b PORT_ACTIVE=14151 PORT_STANDBY=14152 \
#   VIP_CNAME=mq-vip VIP_PORT=14150 VIP_STATS_PORT=8404 VIP_USER=admin VIP_PASS=admin \
#   ./verify_mi.sh
#
# Exit codes: 0 success; non-zero on any failed check
# =============================================================================

set -euo pipefail

# ---------- Defaults (overridable) ----------
QM_NAME="${QM_NAME:-QM1}"
MI_A="${MI_A:-qm1a}"
MI_B="${MI_B:-qm1b}"

# Host ports mapped to container 1414 (as in build_miqm.sh)
PORT_ACTIVE="${PORT_ACTIVE:-14151}"
PORT_STANDBY="${PORT_STANDBY:-14152}"

# VIP (HAProxy), optional
VIP_CNAME="${VIP_CNAME:-mq-vip}"
VIP_PORT="${VIP_PORT:-14150}"
VIP_STATS_PORT="${VIP_STATS_PORT:-8404}"
VIP_USER="${VIP_USER:-admin}"
VIP_PASS="${VIP_PASS:-admin}"

# Behavior
DO_FAILOVER=false
CHECK_ONLY=false
RETRY_SLEEP="${RETRY_SLEEP:-3}"
TIMEOUT="${TIMEOUT:-120}"

# ---------- CLI ----------
usage() {
  cat <<USAGE
Usage: $0 [--simulate-failover] [--check-only] [--help]

  --simulate-failover  End ACTIVE, wait for promotion, then restore MI state
  --check-only         Skip TCP/VIP checks and skip put/get test (just roles+storage)
  --help               Show this help

Environment overrides:
  QM_NAME, MI_A, MI_B, PORT_ACTIVE, PORT_STANDBY,
  VIP_CNAME, VIP_PORT, VIP_STATS_PORT, VIP_USER, VIP_PASS,
  RETRY_SLEEP, TIMEOUT
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulate-failover) DO_FAILOVER=true; shift;;
    --check-only)        CHECK_ONLY=true; shift;;
    -h|--help)           usage;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# ---------- Colors & helpers ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;36m"; NC="\033[0m"
die(){ echo -e "${RED}❌ $*${NC}"; exit 1; }
ok(){  echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }

needs_bin(){ command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }
docker_running(){ docker ps --format '{{.Names}}' | grep -qx "$1"; }
exec_in(){ docker exec "$1" bash -lc "$2"; }

tcp_probe() {
  # Returns 0 if TCP connect succeeds, non-zero otherwise (no nc required)
  local host="$1" port="$2"
  ( bash -c "exec 3<>/dev/tcp/${host}/${port}" ) >/dev/null 2>&1
}

role_of() {
  local cname="$1"
  local out
  out="$(exec_in "$cname" ". /opt/mqm/bin/setmqenv -s; dspmq -m ${QM_NAME} -o status" 2>/dev/null || true)"
  if   echo "$out" | grep -qi "RUNNING as standby"; then echo "standby"
  elif echo "$out" | grep -q  "RUNNING";            then echo "active"
  else echo "down"; fi
}

wait_role() {
  local cname="$1" want="$2" t=0
  info "Waiting for ${QM_NAME} in ${cname} to become ${want} (timeout ${TIMEOUT}s)..."
  while true; do
    [[ "$(role_of "$cname")" == "$want" ]] && { ok "${cname} is ${want}"; return 0; }
    sleep "$RETRY_SLEEP"; t=$((t+RETRY_SLEEP)); [[ $t -ge $TIMEOUT ]] && break
  done
  die "Timed out waiting for ${cname} -> ${want}"
}

hash_qmini() {
  local cname="$1"
  # Prefer sha256sum, fallback to md5sum; echo hash only
  exec_in "$cname" "
    f=/mnt/mqm/qmgrs/${QM_NAME}/qm.ini;
    [ -s \"\$f\" ] || exit 3;
    if command -v sha256sum >/dev/null 2>&1; then sha256sum \"\$f\" | awk '{print \$1}';
    elif command -v md5sum >/dev/null 2>&1; then md5sum \"\$f\" | awk '{print \$1}';
    else sed -n '1,200p' \"\$f\" | cksum | awk '{print \$1}'; fi
  "
}

put_get_loopback() {
  # Server-bindings sanity test on ACTIVE node
  local cname="$1" q="VERIFY.MI.TEST.Q"
  exec_in "$cname" "cat <<'MQSC' | runmqsc ${QM_NAME}
DEFINE QLOCAL(${q}) REPLACE
MQSC"
  local stamp="test-$(date +%s)"
  exec_in "$cname" "printf '%s\n' '${stamp}' | /opt/mqm/samp/bin/amqsputc ${q} ${QM_NAME} >/tmp/put.log 2>&1 || true"
  exec_in "$cname" "/opt/mqm/samp/bin/amqsgetc ${q} ${QM_NAME} >/tmp/get.log 2>&1 || true"
  exec_in "$cname" "grep -q '${stamp}' /tmp/get.log && echo OK || echo FAIL"
  exec_in "$cname" "cat <<'MQSC' | runmqsc ${QM_NAME}
DELETE QLOCAL(${q})
MQSC" >/dev/null 2>&1 || true
}

end_active() {
  local cname="$1" mode="${2:-immediate}"  # immediate|quiesce
  case "$mode" in
    immediate) exec_in "$cname" ". /opt/mqm/bin/setmqenv -s; endmqm -i ${QM_NAME}";;
    quiesce)   exec_in "$cname" ". /opt/mqm/bin/setmqenv -s; endmqm -s ${QM_NAME}";;
    *) die "end_active: mode must be immediate|quiesce";;
  esac
}

start_standby() {
  local cname="$1"
  exec_in "$cname" ". /opt/mqm/bin/setmqenv -s; strmqm -x ${QM_NAME}" >/dev/null 2>&1 || true
}

# ---------- Preflight ----------
needs_bin docker
docker_running "$MI_A" || die "Container '$MI_A' not running"
docker_running "$MI_B" || die "Container '$MI_B' not running"
ok "Containers present: $MI_A, $MI_B"

# ---------- Basic shared storage checks ----------
info "Checking that ${QM_NAME} exists on shared storage..."
exec_in "$MI_A" "[ -d /mnt/mqm/qmgrs/${QM_NAME} ]" || die "${QM_NAME} not found on $MI_A:/mnt/mqm/qmgrs"
exec_in "$MI_B" "[ -d /mnt/mqm/qmgrs/${QM_NAME} ]" || die "${QM_NAME} not found on $MI_B:/mnt/mqm/qmgrs"
ok "Queue manager directory present on both nodes."

info "Comparing shared storage file hash (qm.ini) across both nodes..."
H1="$(hash_qmini "$MI_A" || true)"; H2="$(hash_qmini "$MI_B" || true)"
[[ -n "$H1" && -n "$H2" && "$H1" == "$H2" ]] || die "Shared storage mismatch: qm.ini differs or unreadable (H1='$H1' H2='$H2')"
ok "Shared storage looks consistent (qm.ini hash match)."

# ---------- Roles ----------
RA="$(role_of "$MI_A")"
RB="$(role_of "$MI_B")"
info "$MI_A role: $RA"
info "$MI_B role: $RB"

# Expect exactly one ACTIVE, one STANDBY
if [[ "$RA" == "active" && "$RB" == "standby" ]]; then
  ACTIVE="$MI_A"; STANDBY="$MI_B"
elif [[ "$RB" == "active" && "$RA" == "standby" ]]; then
  ACTIVE="$MI_B"; STANDBY="$MI_A"
else
  die "Expected one ACTIVE and one STANDBY; got $MI_A=$RA, $MI_B=$RB"
fi
ok "Roles valid: ACTIVE=${ACTIVE}, STANDBY=${STANDBY}"

# ---------- Check-only mode ends here ----------
if $CHECK_ONLY; then
  ok "--check-only complete (roles + shared storage verified)."
  exit 0
fi

# ---------- TCP behavior (host ports) ----------
info "Probing host TCP ports (ACTIVE should accept, STANDBY should refuse)..."
if tcp_probe "127.0.0.1" "$PORT_ACTIVE"; then
  ok "ACTIVE port ${PORT_ACTIVE} accepting connections."
else
  warn "ACTIVE port ${PORT_ACTIVE} did NOT accept TCP — verify listener started."
fi

if tcp_probe "127.0.0.1" "$PORT_STANDBY"; then
  warn "STANDBY port ${PORT_STANDBY} accepted TCP — unusual; standby normally doesn't start listeners."
else
  ok "STANDBY port ${PORT_STANDBY} not accepting (expected)."
fi

# ---------- Put/get loopback on ACTIVE (bindings) ----------
info "Running server-bindings put/get on ACTIVE (${ACTIVE})..."
if [[ "$(put_get_loopback "$ACTIVE")" == "OK" ]]; then
  ok "Put/get loopback succeeded on ACTIVE."
else
  die "Put/get loopback failed on ACTIVE (see /tmp/get.log inside ${ACTIVE})."
fi

# ---------- VIP check (optional) ----------
if docker_running "$VIP_CNAME"; then
  info "VIP detected (${VIP_CNAME}); testing TCP on ${VIP_PORT}..."
  if tcp_probe "127.0.0.1" "$VIP_PORT"; then
    ok "VIP TCP reachable on ${VIP_PORT}."
  else
    warn "VIP TCP not reachable on ${VIP_PORT}."
  fi
  if command -v curl >/dev/null 2>&1; then
    info "Fetching HAProxy stats..."
    if curl -fsS -u "${VIP_USER}:${VIP_PASS}" "http://127.0.0.1:${VIP_STATS_PORT}/stats" >/dev/null; then
      ok "VIP stats reachable."
    else
      warn "VIP stats not reachable at :${VIP_STATS_PORT}/stats (auth: ${VIP_USER}/${VIP_PASS})."
    fi
  else
    warn "curl not installed; skipping stats fetch."
  fi
else
  warn "VIP container '${VIP_CNAME}' not running; skipping VIP checks."
fi

# ---------- Optional failover simulation ----------
if $DO_FAILOVER; then
  info "Simulating failover: ending ACTIVE (${ACTIVE}) and waiting for ${STANDBY} to promote..."
  end_active "$ACTIVE" "immediate"
  wait_role "$STANDBY" "active"
  NEW_ACTIVE="$STANDBY"; NEW_STANDBY="$ACTIVE"

  # Start the old active as standby again
  info "Restoring MI state: starting ${NEW_STANDBY} as STANDBY..."
  start_standby "$NEW_STANDBY"
  wait_role "$NEW_STANDBY" "standby"
  ok "Failover simulation complete. ACTIVE=${NEW_ACTIVE}, STANDBY=${NEW_STANDBY}"
fi

ok "Multi-instance verification completed successfully."
