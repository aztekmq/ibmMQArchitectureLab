#!/usr/bin/env bash
# =============================================================================
# Script Name : build_mq_crr.sh
# Description : Provision an IBM MQ Native-HA cross-region replication lab.
#               Creates a three-node primary region and a three-node replica
#               region using the icr.io/ibm-messaging/mq:latest image and
#               configures asynchronous CRR between them.
# =============================================================================

set -euo pipefail

IMAGE="icr.io/ibm-messaging/mq:latest"
COMPOSE_FILE="docker-compose-crr.yml"
QMGR_NAME="QMHA"
DATA_DIR="./data"

# ANSI colors
RED="\033[0;31m"; GREEN="\033[0;32m"; CYAN="\033[0;36m"; NC="\033[0m"
info(){ echo -e "${CYAN}$*${NC}"; }
ok(){ echo -e "${GREEN}$*${NC}"; }
die(){ echo -e "${RED}$*${NC}"; exit 1; }

needs_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

needs_bin docker

# --------- Create data directories ---------
info "Creating data directories..."
for d in qmha-a qmha-b qmha-c qmha-dr-a qmha-dr-b qmha-dr-c; do
  mkdir -p "${DATA_DIR}/${d}"
done
ok "Data directories ready."

# --------- Generate docker-compose file ---------
info "Generating ${COMPOSE_FILE}..."
cat > "$COMPOSE_FILE" <<'COMPOSE'
version: '3.8'
services:
  qmha-a:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-a
    container_name: qmha-a
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ./data/qmha-a:/mnt/mqm
    ports:
      - "1414:1414"
  qmha-b:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-b
    container_name: qmha-b
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ./data/qmha-b:/mnt/mqm
  qmha-c:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-c
    container_name: qmha-c
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ./data/qmha-c:/mnt/mqm
  qmha-dr-a:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-dr-a
    container_name: qmha-dr-a
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ./data/qmha-dr-a:/mnt/mqm
    ports:
      - "1514:1414"
  qmha-dr-b:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-dr-b
    container_name: qmha-dr-b
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ./data/qmha-dr-b:/mnt/mqm
  qmha-dr-c:
    image: icr.io/ibm-messaging/mq:latest
    hostname: qmha-dr-c
    container_name: qmha-dr-c
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ./data/qmha-dr-c:/mnt/mqm
COMPOSE
ok "${COMPOSE_FILE} generated."

# --------- Start containers ---------
info "Starting CRR environment..."
docker compose -f "$COMPOSE_FILE" up -d
ok "Containers started."

# --------- Configure cross-region replication ---------
info "Configuring cross-region replication..."
docker exec qmha-a bash -lc "mqcli crtmqha --dr-replica qmha-dr-a:1500 qmha-dr-b:1500 qmha-dr-c:1500" && \
  ok "Cross-region replication configured." || \
  die "Failed to configure cross-region replication."

info "Build complete. Primary listener exposed on port 1414, replica on 1514."
