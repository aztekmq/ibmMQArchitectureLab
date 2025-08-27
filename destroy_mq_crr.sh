#!/usr/bin/env bash
# =============================================================================
# Script Name : destroy_mq_crr.sh
# Description : Tear down the IBM MQ CRR lab environment and clean data.
# =============================================================================

set -euo pipefail

COMPOSE_FILE="docker-compose-crr.yml"
DATA_DIR="./data"

if [[ -f "$COMPOSE_FILE" ]]; then
  docker compose -f "$COMPOSE_FILE" down
fi

rm -f "$COMPOSE_FILE"

# Remove only CRR data directories
for d in qmha-a qmha-b qmha-c qmha-dr-a qmha-dr-b qmha-dr-c; do
  rm -rf "${DATA_DIR}/${d}"
done

# Remove data dir if empty
rmdir "$DATA_DIR" 2>/dev/null || true

echo "CRR environment destroyed."
