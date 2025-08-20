#!/usr/bin/env bash
# =============================================================================
# Script      : build_mq_nativeha.sh
# Purpose     : Spin up a 3-node IBM MQ Native-HA (Raft) queue manager in Docker
#               AND generate an HAProxy VIP stack + Makefile convenience targets.
#
# What you get:
#   - 3 containers: qmha-a, qmha-b, qmha-c
#   - One queue manager identity: QMHA (Active elected + 2 Replicas)
#   - Per-node persistent data under ./nha/<node>/data
#   - Per-node INI fragments + dev MQSC under ./nha/<node>/etc
#   - Host MQ ports: 14181/14182/14183 map to container 1414 (per node)
#   - VIP: haproxy on host ${VIP_PORT} (default 14180) + stats on ${VIP_STATS_PORT}
#
# Disclaimer: Educational/lab use only (not production).
# =============================================================================
set -euo pipefail

# ---------- User-tunable defaults ----------
IMAGE_NAME="${IMAGE_NAME:-icr.io/ibm-messaging/mq}"
IMAGE_TAG="${IMAGE_TAG:-9.4.3.0-r1}"
QM_NAME="${QM_NAME:-QMHA}"

# Dev options
MQ_ADMIN_PASSWORD="${MQ_ADMIN_PASSWORD:-adminpass}"
ENABLE_WEB="${ENABLE_WEB:-true}"            # Embedded Web Console
ENABLE_METRICS="${ENABLE_METRICS:-true}"

# Host listener ports for each node (map to container 1414)
PORT_A="${PORT_A:-14181}"
PORT_B="${PORT_B:-14182}"
PORT_C="${PORT_C:-14183}"

# Native HA replication port (docker network)
REPL_PORT="${REPL_PORT:-4444}"

# VIP
VIP_PORT="${VIP_PORT:-14180}"
VIP_STATS_PORT="${VIP_STATS_PORT:-8404}"
VIP_USER="${VIP_USER:-admin}"
VIP_PASS="${VIP_PASS:-admin}"

# Paths
ROOT_DIR="${ROOT_DIR:-./nha}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.nha.yml}"
VIP_COMPOSE="${VIP_COMPOSE:-docker-compose.vip.yml}"

# ---------- Colors ----------
GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; NC="\033[0m"
ok(){ echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
die(){ echo -e "${RED}❌ $*${NC}"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }
port_free() { ss -ltn | grep -qE "[:.]${1}[[:space:]]" && return 1 || return 0; }

# ---------- Pre-flight ----------
need docker; need ss
for p in "$PORT_A" "$PORT_B" "$PORT_C" "$VIP_PORT" "$VIP_STATS_PORT"; do
  port_free "$p" || die "Host TCP port $p already in use"
done
ok "Host ports ${PORT_A}/${PORT_B}/${PORT_C}, VIP ${VIP_PORT}, stats ${VIP_STATS_PORT} are free."

# Clean old lab
info "Cleaning previous lab ..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" -f "$VIP_COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
rm -f "$COMPOSE_FILE" "$VIP_COMPOSE"
rm -rf "$ROOT_DIR" haproxy Makefile
mkdir -p "$ROOT_DIR"/{qmha-a,qmha-b,qmha-c}/{data,etc}

# ---------- Generate INI and MQSC per node ----------
make_ini() {
  local node="$1"
  local lname="$2"
  cat > "${ROOT_DIR}/${node}/etc/20-nativeha.ini" <<EOF
NativeHAInstance:
  Name=qmha-a
  ReplicationAddress=qmha-a(${REPL_PORT})
NativeHAInstance:
  Name=qmha-b
  ReplicationAddress=qmha-b(${REPL_PORT})
NativeHAInstance:
  Name=qmha-c
  ReplicationAddress=qmha-c(${REPL_PORT})

NativeHALocalInstance:
  Name=${lname}
EOF
}

make_mqsc() {
  local node="$1"
  cat > "${ROOT_DIR}/${node}/etc/10-dev.mqsc" <<'MQSC'
* DEV listener & SVRCONN for client testing (lab-only)
DEFINE LISTENER(TCP.LST) TRPTYPE(TCP) PORT(1414) CONTROL(QMGR) REPLACE
START LISTENER(TCP.LST)
DEFINE CHANNEL(DEV.APP.SVRCONN) CHLTYPE(SVRCONN) TRPTYPE(TCP) REPLACE
ALTER AUTHINFO(SYSTEM.DEFAULT.AUTHINFO.IDPWOS) AUTHTYPE(IDPWOS) CHCKCLNT(REQUIRED)
REFRESH SECURITY TYPE(CONNAUTH)
MQSC
}

make_ini qmha-a qmha-a
make_ini qmha-b qmha-b
make_ini qmha-c qmha-c
make_mqsc qmha-a
make_mqsc qmha-b
make_mqsc qmha-c

# ---------- Generate docker-compose for MQ nodes ----------
info "Generating ${COMPOSE_FILE} ..."
cat > "$COMPOSE_FILE" <<EOF
version: "3.9"
name: mq-nativeha-lab
services:
  qmha-a:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmha-a
    hostname: qmha-a
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${QM_NAME}
      - MQ_NATIVE_HA=true
      - MQ_ENABLE_METRICS=${ENABLE_METRICS}
      - MQ_ENABLE_EMBEDDED_WEB_SERVER=${ENABLE_WEB}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
    ports:
      - "${PORT_A}:1414"
    volumes:
      - ./nha/qmha-a/data:/mnt/mqm
      - ./nha/qmha-a/etc:/etc/mqm
    restart: unless-stopped

  qmha-b:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmha-b
    hostname: qmha-b
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${QM_NAME}
      - MQ_NATIVE_HA=true
      - MQ_ENABLE_METRICS=${ENABLE_METRICS}
      - MQ_ENABLE_EMBEDDED_WEB_SERVER=${ENABLE_WEB}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
    ports:
      - "${PORT_B}:1414"
    volumes:
      - ./nha/qmha-b/data:/mnt/mqm
      - ./nha/qmha-b/etc:/etc/mqm
    restart: unless-stopped

  qmha-c:
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: qmha-c
    hostname: qmha-c
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${QM_NAME}
      - MQ_NATIVE_HA=true
      - MQ_ENABLE_METRICS=${ENABLE_METRICS}
      - MQ_ENABLE_EMBEDDED_WEB_SERVER=${ENABLE_WEB}
      - MQ_ADMIN_PASSWORD=${MQ_ADMIN_PASSWORD}
    ports:
      - "${PORT_C}:1414"
    volumes:
      - ./nha/qmha-c/data:/mnt/mqm
      - ./nha/qmha-c/etc:/etc/mqm
    restart: unless-stopped

networks:
  default:
    name: mq-nha-net
EOF

# ---------- Bring up MQ nodes ----------
info "Starting 3-node Native HA queue manager '${QM_NAME}' ..."
docker compose -f "$COMPOSE_FILE" up -d

# ---------- Wait for roles ----------
poll_role() {
  local cname="$1"
  local tries=60
  while (( tries-- > 0 )); do
    if docker exec "$cname" bash -lc "dspmq -m ${QM_NAME} -o nativeha 2>/dev/null | grep -E 'ROLE\\('"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
for c in qmha-a qmha-b qmha-c; do
  info "Waiting for Native HA status in ${c} ..."
  poll_role "$c" || die "Timed out waiting for ${c} to report Native HA status"
done

# ---------- Generate VIP compose + HAProxy cfg ----------
info "Generating VIP stack ..."
mkdir -p haproxy

cat > "$VIP_COMPOSE" <<EOF
version: "3.9"
services:
  mq-vip:
    image: haproxy:2.9
    container_name: mq-vip
    depends_on:
      - qmha-a
      - qmha-b
      - qmha-c
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - "${VIP_PORT}:${VIP_PORT}"
      - "${VIP_STATS_PORT}:8404"
    restart: unless-stopped
networks:
  default:
    name: mq-nha-net
EOF

cat > haproxy/haproxy.cfg <<EOF
global
  log stdout format raw local0

defaults
  log global
  mode tcp
  option tcplog
  timeout connect 3s
  timeout client  1h
  timeout server  1h
  default-server check inter 2000ms fall 2 rise 1

frontend mq_vip
  bind *:${VIP_PORT}
  default_backend mq_back

backend mq_back
  option tcp-check
  tcp-check connect
  server a qmha-a:1414 check
  server b qmha-b:1414 check
  server c qmha-c:1414 check

listen stats
  bind *:8404
  mode http
  stats enable
  stats uri /stats
  stats refresh 5s
  stats auth ${VIP_USER}:${VIP_PASS}
EOF

# ---------- Makefile convenience ----------
info "Writing Makefile ..."
cat > Makefile <<EOF
PROJECT=\$(shell basename \$(PWD))

up:
\tdocker compose -f ${COMPOSE_FILE} up -d

down:
\tdocker compose -f ${COMPOSE_FILE} down

vip-up:
\tdocker compose -f ${COMPOSE_FILE} -f ${VIP_COMPOSE} up -d mq-vip

vip-down:
\tdocker compose -f ${COMPOSE_FILE} -f ${VIP_COMPOSE} rm -s -f mq-vip || true
\tdocker compose -f ${COMPOSE_FILE} -f ${VIP_COMPOSE} stop mq-vip || true

vip-reload:
\tdocker kill -s HUP mq-vip || true

status:
\t@echo "-- MQ Node Status --"
\tdocker exec qmha-a bash -lc "dspmq -m ${QM_NAME} -o status -o nativeha" || true
\tdocker exec qmha-b bash -lc "dspmq -m ${QM_NAME} -o status -o nativeha" || true
\tdocker exec qmha-c bash -lc "dspmq -m ${QM_NAME} -o status -o nativeha" || true
\t@echo "-- VIP --"
\tdocker ps --format 'table {{.Names}}\\t{{.Status}}' | grep -E 'mq-vip|NAMES' || true

verify:
\t./verify_nativeha.sh

failover:
\t./verify_nativeha.sh --simulate-failover

clean: down vip-down
\trm -f ${VIP_COMPOSE}
\trm -rf haproxy
\trm -rf ${ROOT_DIR}
EOF

# ---------- Summary ----------
echo
ok "All nodes reporting Native HA. Current view (from each node):"
for c in qmha-a qmha-b qmha-c; do
  echo -e "${YELLOW}-- ${c}${NC}"
  docker exec "$c" bash -lc "dspmq -m ${QM_NAME} -o status -o nativeha"
done

echo
ok "VIP artifacts created:"
echo "  • ${VIP_COMPOSE}"
echo "  • haproxy/haproxy.cfg"
echo "  • Makefile  (targets: up, down, vip-up, vip-down, vip-reload, status, verify, failover)"

echo
ok "Next steps:"
echo "  make vip-up"
echo "  open http://localhost:${VIP_STATS_PORT}/stats  (user: ${VIP_USER}, pass: ${VIP_PASS})"
echo "  export MQSERVER=\"DEV.APP.SVRCONN/TCP/localhost(${VIP_PORT})\"   # clients"
echo
ok "Done."
