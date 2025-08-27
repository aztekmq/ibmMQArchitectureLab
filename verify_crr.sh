#!/usr/bin/env bash
# =============================================================================
# Script Name : verify_crr.sh
# Description : Basic verification for the IBM MQ CRR lab. Ensures containers
#               are running, queue managers are RUNNING, and displays
#               cross-region replication status.
# =============================================================================

set -euo pipefail

QMGR_NAME="${QMGR_NAME:-QMHA}"
SERVICES=(qmha-a qmha-b qmha-c qmha-dr-a qmha-dr-b qmha-dr-c)

RED="\033[0;31m"; GREEN="\033[0;32m"; CYAN="\033[0;36m"; NC="\033[0m"
die(){ echo -e "${RED}❌ $*${NC}"; exit 1; }
ok(){ echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }

command -v docker >/dev/null 2>&1 || die "docker not found"

for s in "${SERVICES[@]}"; do
  info "Checking container ${s}..."
  docker ps --format '{{.Names}}' | grep -qx "$s" || die "Container $s not running"
  docker exec "$s" bash -lc "dspmq -m ${QMGR_NAME} -o status" | grep -q 'RUNNING' || die "Queue manager in $s not RUNNING"
  ok "$s is RUNNING"
done

info "Retrieving replication status from primary..."
docker exec qmha-a bash -lc "mqcli rdqmstatus -m ${QMGR_NAME}" || die "mqcli rdqmstatus failed"

ok "CRR verification completed."
