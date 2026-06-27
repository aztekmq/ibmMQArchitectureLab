#!/usr/bin/env bash
# =============================================================================
# Script Name : build_mq_mft.sh
# Description : Provision an IBM MQ Managed File Transfer (MFT) environment:
#               - Container 1: QMCOORD + MFT Coordination Server
#               - Container 2: QMCMD   + MFT Command Server
#               - Container 3: QMAGENT + MFT Agent Server (local agent)
#               - Container 4: MFT Agent only (no queue manager; remote to QMAGENT)
#
# Author      : rob lee
# Maintainer  : rob@aztekmq.net
# Version     : 2.0.0
# Created     : 2025-08-19
# License     : MIT (SPDX-License-Identifier: MIT)
#
# Standards & Conventions:
#   - ISO 8601 dates; POSIX-y Bash; Compose v2; OCI metadata; RFC 2119 language.
#   - MQ Advanced / MFT CLI expected at /opt/mqm/mqft/bin
#   - Network: docker default bridge
# =============================================================================

set -euo pipefail

# --------- USER CONFIG (dev defaults: CHANGE for prod) ---------
IMAGE_NAME="${IMAGE_NAME:-ibmcom/mq}"   # Use an MQ Advanced-capable image
IMAGE_TAG="${IMAGE_TAG:-latest}"
COMPOSE_FILE="docker-compose.yml"
DATA_DIR="${DATA_DIR:-./data}"
MFT_DIR="${MFT_DIR:-./mft}"

# Queue manager names
COORD_QM="${COORD_QM:-QMCOORD}"
CMD_QM="${CMD_QM:-QMCMD}"
AGENT_QM="${AGENT_QM:-QMAGENT}"

# MFT Domain / Agent names
MFT_DOMAIN="${MFT_DOMAIN:-MFTDOM}"
AGENT_LOCAL_NAME="${AGENT_LOCAL_NAME:-AGENT_LCL}"     # runs in Container 3
AGENT_REMOTE_NAME="${AGENT_REMOTE_NAME:-AGENT_REM}"   # runs in Container 4

# Networking (host port mappings)
PORT_QMCOORD="${PORT_QMCOORD:-1415}"
PORT_QMCMD="${PORT_QMCMD:-1416}"
PORT_QMAGENT="${PORT_QMAGENT:-1417}"
PORT_WEB_COORD="${PORT_WEB_COORD:-9444}"
PORT_WEB_CMD="${PORT_WEB_CMD:-9445}"
PORT_WEB_AGENT="${PORT_WEB_AGENT:-9446}"

# Credentials (dev defaults)
MQ_ADMIN_PASSWORD="${MQ_ADMIN_PASSWORD:-adminpass}"
MQ_APP_PASSWORD="${MQ_APP_PASSWORD:-passw0rd}"

# Timeouts
START_TIMEOUT="${START_TIMEOUT:-120}"   # seconds per QM
RETRY_SLEEP="${RETRY_SLEEP:-4}"         # seconds between status polls

# --------- COLORS ---------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;36m"; NC="\033[0m"

# --------- Helpers ---------
die() { echo -e "${RED}❌ $*${NC}"; exit 1; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
ok()  { echo -e "${GREEN}✅ $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }

needs_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

port_free() {
  local p="$1"
  if ss -ltn | grep -qE "[:.]${p}[[:space:]]"; then return 1; else return 0; fi
}

wait_qm_running() {
  local cname="$1" qmgr="$2" t=0
  info "Waiting for ${qmgr} in ${cname} to become RUNNING (timeout ${START_TIMEOUT}s)..."
  until docker exec "$cname" bash -lc "dspmq -m ${qmgr} -o status | grep -q 'RUNNING'" >/dev/null 2>&1; do
    sleep "${RETRY_SLEEP}"
    t=$((t+RETRY_SLEEP))
    if (( t >= START_TIMEOUT )); then
      die "Queue manager ${qmgr} in ${cname} did not reach RUNNING within ${START_TIMEOUT}s"
    fi
  done
  ok "${qmgr} is RUNNING in ${cname}"
}

check_mft_cli() {
  local cname="$1"
  if ! docker exec "$cname" bash -lc "[ -x /opt/mqm/mqft/bin/fteCreateAgent ]"; then
    warn "MFT CLI not found in ${cname}. You likely need an MQ Advanced image."
    warn "Tried: /opt/mqm/mqft/bin/fteCreateAgent"
    die  "Switch IMAGE_NAME/IMAGE_TAG to an MQ Advanced build that includes MFT."
  fi
}

define_dev_objects() {
  # Create DEV listener & channel for simple client access in each QM (as needed by MFT agents)
  local cname="$1" qmgr="$2" port="$3"
  docker exec "$cname" bash -lc "cat <<'MQSC' | runmqsc ${qmgr}
DEFINE LISTENER(TCP.LST) TRPTYPE(TCP) PORT(${port}) CONTROL(QMGR) REPLACE
START LISTENER(TCP.LST)
* Dev channel for app/MFT traffic
DEFINE CHANNEL(DEV.APP.SVRCONN) CHLTYPE(SVRCONN) TRPTYPE(TCP) REPLACE
ALTER AUTHINFO(SYSTEM.DEFAULT.AUTHINFO.IDPWOS) AUTHTYPE(IDPWOS) CHCKCLNT(REQUIRED)
REFRESH SECURITY TYPE(CONNAUTH)
MQSC"
}

# --------- Pre-flight ---------
needs_bin docker
needs_bin ss

for p in "$PORT_QMCOORD" "$PORT_QMCMD" "$PORT_QMAGENT" "$PORT_WEB_COORD" "$PORT_WEB_CMD" "$PORT_WEB_AGENT"; do
  port_free "$p" || die "Port $p is in use"
done
ok "Ports are free."

info "Cleaning previous compose/data..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
rm -f "$COMPOSE_FILE"
sudo rm -rf "$DATA_DIR" "$MFT_DIR"
mkdir -p "$DATA_DIR/$COORD_QM" "$DATA_DIR/$CMD_QM" "$DATA_DIR/$AGENT_QM"
mkdir -p "$MFT_DIR/$COORD_QM" "$MFT_DIR/$CMD_QM" "$MFT_DIR/$AGENT_QM" "$MFT_DIR/agent"
sudo chown -R 1001:0 "$DATA_DIR" "$MFT_DIR" || true

# --------- Generate docker-compose.yml ---------
info "Generating ${COMPOSE_FILE}..."
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  qmcoord:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmcoord
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${COORD_QM}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
      - MQ_APP_PASSWORD=${MQ_APP_PASSWORD}
      - MQ_ENABLE_ADMIN_WEB=true
      - MQ_ENABLE_METRICS=true
    ports:
      - "${PORT_QMCOORD}:1414"
      - "${PORT_WEB_COORD}:9443"
    volumes:
      - ./data/${COORD_QM}:/mnt/mqm
      - ./mft/${COORD_QM}:/var/mqm/mqft
    healthcheck:
      test: ["CMD-SHELL","dspmq -m ${COORD_QM} -o status | grep RUNNING"]
      interval: 20s
      timeout: 10s
      retries: 10
    restart: unless-stopped

  qmcmd:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmcmd
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${CMD_QM}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
      - MQ_APP_PASSWORD=${MQ_APP_PASSWORD}
      - MQ_ENABLE_ADMIN_WEB=true
      - MQ_ENABLE_METRICS=true
    ports:
      - "${PORT_QMCMD}:1414"
      - "${PORT_WEB_CMD}:9443"
    volumes:
      - ./data/${CMD_QM}:/mnt/mqm
      - ./mft/${CMD_QM}:/var/mqm/mqft
    healthcheck:
      test: ["CMD-SHELL","dspmq -m ${CMD_QM} -o status | grep RUNNING"]
      interval: 20s
      timeout: 10s
      retries: 10
    restart: unless-stopped

  qmagent:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmagent
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${AGENT_QM}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
      - MQ_APP_PASSWORD=${MQ_APP_PASSWORD}
      - MQ_ENABLE_ADMIN_WEB=true
      - MQ_ENABLE_METRICS=true
    ports:
      - "${PORT_QMAGENT}:1414"
      - "${PORT_WEB_AGENT}:9443"
    volumes:
      - ./data/${AGENT_QM}:/mnt/mqm
      - ./mft/${AGENT_QM}:/var/mqm/mqft
    healthcheck:
      test: ["CMD-SHELL","dspmq -m ${AGENT_QM} -o status | grep RUNNING"]
      interval: 20s
      timeout: 10s
      retries: 10
    restart: unless-stopped

  mftagent:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: mftagent
    environment:
      - LICENSE=accept
      - MQ_ENABLE_METRICS=false
      # MQ client to reach QMAGENT (service name 'qmagent' in Compose network)
      - MQSERVER=DEV.APP.SVRCONN/TCP/qmagent(1414)
      - MQ_APP_PASSWORD=${MQ_APP_PASSWORD}
    depends_on:
      - qmagent
    volumes:
      - ./mft/agent:/var/mqm/mqft
    entrypoint: ["/bin/bash","-lc","sleep infinity"]
    restart: unless-stopped
EOF

# --------- Bring up containers ---------
info "Starting containers..."
docker compose up -d

# --------- Wait for QMs ---------
wait_qm_running "qmcoord" "${COORD_QM}"
wait_qm_running "qmcmd"   "${CMD_QM}"
wait_qm_running "qmagent" "${AGENT_QM}"

# --------- Ensure MFT CLI exists ---------
check_mft_cli "qmcoord"
check_mft_cli "qmcmd"
check_mft_cli "qmagent"
check_mft_cli "mftagent"

# --------- Define DEV objects on each QM (listener+SVRCONN) ---------
define_dev_objects "qmcoord" "${COORD_QM}" 1414
define_dev_objects "qmcmd"   "${CMD_QM}"   1414
define_dev_objects "qmagent" "${AGENT_QM}" 1414

ok "DEV listeners and DEV.APP.SVRCONN defined."

# --------- MFT Domain & Components Setup ---------
info "Configuring MFT Coordination on ${COORD_QM}..."
docker exec qmcoord bash -lc "
  . /opt/mqm/bin/setmqenv -s;
  export MQSNOAUT=yes;
  if /opt/mqm/mqft/bin/fteCreateCoordinationQMgr -p ${COORD_QM} -q ${COORD_QM} -d ${MFT_DOMAIN} -y >/tmp/mft_coord.out 2>&1; then
    echo 'fteCreateCoordinationQMgr completed';
  else
    echo 'fteCreateCoordinationQMgr failed, trying fteSetupCoordination...';
    /opt/mqm/mqft/bin/fteSetupCoordination -autoAcceptCertificates \
      -coordinationQMgr ${COORD_QM} -f -loggingConfigurations default -createCoordinationQMgr no
  fi
"

ok "Coordination configured (domain: ${MFT_DOMAIN})."

info "Configuring MFT Command on ${CMD_QM}..."
docker exec qmcmd bash -lc "
  . /opt/mqm/bin/setmqenv -s;
  export MQSNOAUT=yes;
  if /opt/mqm/mqft/bin/fteCreateCommandQMgr -p ${CMD_QM} -q ${CMD_QM} -d ${MFT_DOMAIN} -y >/tmp/mft_cmd.out 2>&1; then
    echo 'fteCreateCommandQMgr completed';
  else
    echo 'fteCreateCommandQMgr failed, trying fteSetupCommands...';
    /opt/mqm/mqft/bin/fteSetupCommands -autoAcceptCertificates \
      -commandQMgr ${CMD_QM} -f -createCommandQMgr no
  fi
"

ok "Command manager configured."

info "Creating & starting local Agent (${AGENT_LOCAL_NAME}) on ${AGENT_QM}..."
docker exec qmagent bash -lc "
  . /opt/mqm/bin/setmqenv -s;
  export MQSNOAUT=yes;
  /opt/mqm/mqft/bin/fteCreateAgent -d ${MFT_DOMAIN} -p ${AGENT_QM} -q ${AGENT_QM} -agt ${AGENT_LOCAL_NAME} -f -y
  /opt/mqm/mqft/bin/fteStartAgent ${AGENT_LOCAL_NAME}
"

ok "Local agent ${AGENT_LOCAL_NAME} created and started on ${AGENT_QM}."

info "Creating & starting remote Agent (${AGENT_REMOTE_NAME}) in mftagent (no QM; uses ${AGENT_QM})..."
docker exec mftagent bash -lc "
  . /opt/mqm/bin/setmqenv -s;
  export MQSNOAUT=yes;
  # Agent connects via MQSERVER to DEV.APP.SVRCONN on qmagent:1414
  /opt/mqm/mqft/bin/fteCreateAgent -d ${MFT_DOMAIN} -agt ${AGENT_REMOTE_NAME} -f -y \
    -r QMGR -q ${AGENT_QM}
  /opt/mqm/mqft/bin/fteStartAgent ${AGENT_REMOTE_NAME}
"

ok "Remote agent ${AGENT_REMOTE_NAME} created and started (container: mftagent)."

# --------- Summary ---------
echo ""
echo -e "${YELLOW}📄 MQ/MFT Deployment Summary${NC}"
printf "%-12s %-14s %-12s %-10s\n" "SERVICE" "QMGR" "PORT(1414)" "WEB(9443)"
printf "%-12s %-14s %-12s %-10s\n" "--------" "------------" "----------" "--------"
printf "%-12s %-14s %-12s %-10s\n" "qmcoord" "${COORD_QM}" "${PORT_QMCOORD}" "${PORT_WEB_COORD}"
printf "%-12s %-14s %-12s %-10s\n" "qmcmd"   "${CMD_QM}"   "${PORT_QMCMD}"   "${PORT_WEB_CMD}"
printf "%-12s %-14s %-12s %-10s\n" "qmagent" "${AGENT_QM}" "${PORT_QMAGENT}" "${PORT_WEB_AGENT}"
printf "%-12s %-14s %-12s %-10s\n" "mftagent" "— (none)"    "n/a"            "n/a"

echo ""
ok "MFT domain: ${MFT_DOMAIN}"
ok "Agents: ${AGENT_LOCAL_NAME} (on ${AGENT_QM}), ${AGENT_REMOTE_NAME} (agent-only container)"

echo ""
info "Quick checks:"
echo "  docker exec qmcoord  bash -lc '/opt/mqm/mqft/bin/fteListAgents -d ${MFT_DOMAIN}'"
echo "  docker exec qmcmd    bash -lc '/opt/mqm/mqft/bin/fteListMonitors -d ${MFT_DOMAIN}'"
echo "  docker exec qmagent  bash -lc 'dspmq -m ${AGENT_QM} -o status'"
echo "  docker exec mftagent bash -lc '/opt/mqm/mqft/bin/ftePingAgent ${AGENT_LOCAL_NAME}'"

# =============================================================================
# End of file
# =============================================================================
