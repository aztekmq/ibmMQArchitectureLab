#!/usr/bin/env bash
# =============================================================================
# Script   : verify_nativeha.sh
# Purpose  : Verify the Native-HA 3-node lab: roles, quorum, listener behavior,
#            optional failover simulation and re-election checks.
# Usage    : ./verify_nativeha.sh [--simulate-failover]
# =============================================================================
set -euo pipefail

QM_NAME="${QM_NAME:-QMHA}"
NODES=(qmha-a qmha-b qmha-c)
PORTS=("${PORT_A:-14181}" "${PORT_B:-14182}" "${PORT_C:-14183}")

Y="\033[0;33m"; G="\033[0;32m"; R="\033[0;31m"; C="\033[0;36m"; N="\033[0m"
ok(){ echo -e "${G}✅ $*${N}"; }
info(){ echo -e "${C}ℹ️  $*${N}"; }
warn(){ echo -e "${Y}⚠️  $*${N}"; }
die(){ echo -e "${R}❌ $*${N}"; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }

tcp_open() { # usage: tcp_open HOST PORT
  (exec 3<>/dev/tcp/"$1"/"$2") >/dev/null 2>&1 && { exec 3>&-; return 0; } || return 1
}

# --- Gather status from each container ---
declare -A ROLE INSYNC QUORUM

for i in "${!NODES[@]}"; do
  c="${NODES[$i]}"
  info "Reading dspmq status from ${c}..."
  out="$(docker exec "$c" bash -lc "dspmq -m ${QM_NAME} -o nativeha -o status -n")" || die "Failed dspmq in $c"
  echo "$out"
  ROLE["$c"]="$(echo "$out" | sed -n 's/.*ROLE(\([^)]*\)).*/\1/p')"
  INSYNC["$c"]="$(echo "$out" | sed -n 's/.*INSYNC(\([^)]*\)).*/\1/p')"
  QUORUM["$c"]="$(echo "$out" | sed -n 's/.*QUORUM(\([^)]*\)).*/\1/p')"
done

# --- Determine the ACTIVE node ---
ACTIVE=""
for c in "${NODES[@]}"; do
  [[ "${ROLE[$c]}" == "Active" ]] && ACTIVE="$c"
done
[[ -n "$ACTIVE" ]] || die "No Active node detected"

ok "Active node: ${ACTIVE}"
info "Replica nodes: $(printf "%s " "${NODES[@]}" | sed "s/${ACTIVE}//")"

# --- Listener behavior: only Active should accept 1414 ---
for i in "${!NODES[@]}"; do
  c="${NODES[$i]}"; p="${PORTS[$i]}"
  if tcp_open "127.0.0.1" "$p"; then
    if [[ "$c" == "$ACTIVE" ]]; then ok "${c} listener on ${p} is open (expected Active)"; else die "${c} listener on ${p} is open but node is ${ROLE[$c]}"; fi
  else
    if [[ "$c" == "$ACTIVE" ]]; then die "Active ${c} listener ${p} is not accepting"; else ok "${c} listener on ${p} is closed (expected Replica)"; fi
  fi
done

# --- Optional failover test ---
if [[ "${1:-}" == "--simulate-failover" ]]; then
  info "Simulating failover by stopping ${ACTIVE} ..."
  docker stop "$ACTIVE" >/dev/null

  # wait for a new Active
  tries=60
  NEW_ACTIVE=""
  while (( tries-- > 0 )); do
    for c in "${NODES[@]}"; do
      [[ "$c" == "$ACTIVE" ]] && continue
      out="$(docker exec "$c" bash -lc "dspmq -m ${QM_NAME} -o nativeha -n" 2>/dev/null || true)"
      role="$(echo "$out" | sed -n 's/.*ROLE(\([^)]*\)).*/\1/p')"
      if [[ "$role" == "Active" ]]; then NEW_ACTIVE="$c"; break; fi
    done
    [[ -n "$NEW_ACTIVE" ]] && break
    sleep 2
  done
  [[ -n "$NEW_ACTIVE" ]] || die "Failover did not elect a new Active within timeout"
  ok "New Active elected: ${NEW_ACTIVE}"

  # Start old node back and confirm it returns as Replica
  info "Restarting ${ACTIVE} ..."
  docker start "$ACTIVE" >/dev/null
  tries=60
  while (( tries-- > 0 )); do
    out="$(docker exec "$ACTIVE" bash -lc "dspmq -m ${QM_NAME} -o nativeha -n" 2>/dev/null || true)"
    role="$(echo "$out" | sed -n 's/.*ROLE(\([^)]*\)).*/\1/p')"
    [[ "$role" == "Replica" ]] && break
    sleep 2
  done
  [[ "$role" == "Replica" ]] || die "${ACTIVE} did not rejoin as Replica"
  ok "${ACTIVE} rejoined as Replica"
fi

echo
ok "Native-HA verification complete."
