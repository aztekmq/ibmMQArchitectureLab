#!/usr/bin/env bash
# =============================================================================
# Script Name : build_miqm.sh
# Purpose     : Provision IBM MQ Multi-Instance Queue Manager (1 ACTIVE + 1 STANDBY)
#               and fold in a VIP (HAProxy) with Makefile convenience targets.
#
# Outputs:
#   - docker-compose.yml            (MIQM)
#   - docker-compose.vip.yml        (VIP service)
#   - haproxy/haproxy.cfg           (VIP config)
#   - promote_standby.sh            (role swap helper)
#   - Makefile                      (up, down, vip-up, vip-down, promote, status, logs, clean)
#
# Author      : rob lee
# Maintainer  : rob@aztekmq.net
# Version     : 1.1.0
# Created     : 2025-08-19
# License     : MIT (SPDX-License-Identifier: MIT)
#
# Notes:
#   - For production, mount the same NFSv4 export (POSIX locks!) to both nodes.
#   - Demo mode uses a local ./shared bind. Change permissions: chown -R 1001:0.
#   - DEV-only CHLAUTH loosened for quick testing (adjust for real security).
# =============================================================================

set -euo pipefail

# ---------- USER CONFIG ----------
QM_NAME="${QM_NAME:-QM1}"

# Image (base MQ image is fine for MIQM)
IMAGE_NAME="${IMAGE_NAME:-ibmcom/mq}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Host ports -> container:1414 (keep distinct for multi-conn testing)
PORT_ACTIVE="${PORT_ACTIVE:-14151}"
PORT_STANDBY="${PORT_STANDBY:-14152}"

# Optional Admin Web (exposed if you enable it in the container)
WEB_ACTIVE="${WEB_ACTIVE:-9444}"
WEB_STANDBY="${WEB_STANDBY:-9445}"

# VIP (HAProxy)
VIP_PORT="${VIP_PORT:-14150}"
VIP_STATS_PORT="${VIP_STATS_PORT:-8404}"
VIP_USER="${VIP_USER:-admin}"
VIP_PASS="${VIP_PASS:-admin}"

# Storage
# If both set => NFS volume; else local bind: ./shared -> /mnt/mqm
NFS_SERVER="${NFS_SERVER:-}"    # e.g., 10.0.0.5
NFS_EXPORT="${NFS_EXPORT:-}"    # e.g., /exports/mqmshare

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_VIP="${COMPOSE_VIP:-docker-compose.vip.yml}"

RETRY_SLEEP="${RETRY_SLEEP:-3}"
START_TIMEOUT="${START_TIMEOUT:-120}"

# ---------- COLORS ----------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;36m"; NC="\033[0m"
die() { echo -e "${RED}❌ $*${NC}"; exit 1; }
ok()  { echo -e "${GREEN}✅ $*${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}"; }

# ---------- HELPERS ----------
needs_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

port_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -qE "[:.]${p}[[:space:]]" && return 1 || return 0
  else
    # netstat fallback (macOS/BSD)
    netstat -an 2>/dev/null | grep -E "[\.\:]${p}[[:space:]]" | grep -qi listen && return 1 || return 0
  fi
}

wait_role() {
  local cname="$1" qmgr="$2" role="$3" t=0
  info "Waiting for ${qmgr} in ${cname} to become ${role} (timeout ${START_TIMEOUT}s)..."
  while true; do
    local out
    out="$(docker exec "$cname" bash -lc ". /opt/mqm/bin/setmqenv -s; dspmq -m ${qmgr} -o status" 2>/dev/null || true)"
    if [[ "$role" == "active" ]]; then
      if echo "$out" | grep -q "RUNNING" && ! echo "$out" | grep -qi "standby"; then ok "${qmgr} ACTIVE in ${cname}"; return 0; fi
    else
      if echo "$out" | grep -qi "RUNNING as standby"; then ok "${qmgr} STANDBY in ${cname}"; return 0; fi
    fi
    sleep "$RETRY_SLEEP"; t=$((t+RETRY_SLEEP)); [[ $t -ge $START_TIMEOUT ]] && break
  done
  die "Timed out waiting for ${qmgr} in ${cname} to be ${role}"
}

define_dev_objects() {
  local cname="$1" qmgr="$2"
  docker exec "$cname" bash -lc "cat <<'MQSC' | runmqsc ${qmgr}
* Listener + DEV channel (DEV ONLY!)
DEFINE LISTENER(TCP.LST) TRPTYPE(TCP) PORT(1414) CONTROL(QMGR) REPLACE
START LISTENER(TCP.LST)
DEFINE CHANNEL(DEV.APP.SVRCONN) CHLTYPE(SVRCONN) TRPTYPE(TCP) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(ADDRESSMAP) ADDRESS('*') USERSRC(MAP) MCAUSER('mqm') ACTION(ADD)
REFRESH SECURITY TYPE(CONNAUTH)
MQSC"
}

# ---------- PREFLIGHT ----------
needs_bin docker
port_free "$PORT_ACTIVE"   || die "Port $PORT_ACTIVE in use"
port_free "$PORT_STANDBY"  || die "Port $PORT_STANDBY in use"
port_free "$VIP_PORT"      || die "VIP port $VIP_PORT in use"
port_free "$VIP_STATS_PORT"|| die "VIP stats port $VIP_STATS_PORT in use"
ok "Ports look free."

# ---------- CLEAN PRIOR ----------
info "Stopping any previous stack..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" -f "$COMPOSE_VIP" down --remove-orphans >/dev/null 2>&1 || true

# ---------- STORAGE PREP ----------
if [[ -z "$NFS_SERVER" || -z "$NFS_EXPORT" ]]; then
  info "Using local bind ./shared as MIQM shared storage (demo mode)."
  mkdir -p ./shared
  sudo chown -R 1001:0 ./shared || true
else
  info "Using NFS ${NFS_SERVER}:${NFS_EXPORT} as shared storage."
fi

# ---------- GENERATE docker-compose.yml ----------
info "Generating ${COMPOSE_FILE} ..."
{
  cat <<EOF
version: "3.8"
EOF

  if [[ -n "$NFS_SERVER" && -n "$NFS_EXPORT" ]]; then
    cat <<EOF
volumes:
  qm1data:
    driver: local
    driver_opts:
      type: "nfs"
      o: "addr=${NFS_SERVER},rw,hard,nfsvers=4,timeo=600"
      device: ":${NFS_EXPORT}"
EOF
  fi

  cat <<'EOF'
services:
  qm1a:
    image: IMAGE_NAME_TAG_PLACEHOLDER
    container_name: qm1a
    environment:
      - LICENSE=accept
    volumes:
EOF

  if [[ -n "$NFS_SERVER" && -n "$NFS_EXPORT" ]]; then
    echo "      - qm1data:/mnt/mqm"
  else
    echo "      - ./shared:/mnt/mqm"
  fi

  cat <<EOF
    ports:
      - "${PORT_ACTIVE}:1414"
      - "${WEB_ACTIVE}:9443"
    entrypoint: ["/bin/bash","-lc","sleep infinity"]
    restart: unless-stopped

  qm1b:
    image: IMAGE_NAME_TAG_PLACEHOLDER
    container_name: qm1b
    environment:
      - LICENSE=accept
    volumes:
EOF

  if [[ -n "$NFS_SERVER" && -n "$NFS_EXPORT" ]]; then
    echo "      - qm1data:/mnt/mqm"
  else
    echo "      - ./shared:/mnt/mqm"
  fi

  cat <<EOF
    ports:
      - "${PORT_STANDBY}:1414"
      - "${WEB_STANDBY}:9443"
    entrypoint: ["/bin/bash","-lc","sleep infinity"]
    restart: unless-stopped
EOF
} > "$COMPOSE_FILE"

# Replace image tag once to avoid BSD sed drama
perl -pi -e "s|IMAGE_NAME_TAG_PLACEHOLDER|${IMAGE_NAME}:${IMAGE_TAG}|g" "$COMPOSE_FILE"

ok "Base compose written."

# ---------- START BASE CONTAINERS ----------
info "Starting MIQM containers..."
docker compose -f "$COMPOSE_FILE" up -d

# ---------- INITIALIZE QM ON SHARE (first run) ----------
info "Ensuring ${QM_NAME} exists on shared storage..."
if ! docker exec qm1a bash -lc "[ -d /mnt/mqm/qmgrs/${QM_NAME} ]"; then
  info "Creating ${QM_NAME} (first-time)..."
  docker exec qm1a bash -lc "
    . /opt/mqm/bin/setmqenv -s
    crtmqm ${QM_NAME}
    strmqm ${QM_NAME}
    endmqm -i ${QM_NAME}
  "
  ok "${QM_NAME} created."
else
  ok "${QM_NAME} already present."
fi

# ---------- START ACTIVE & STANDBY ----------
info "Starting ACTIVE on qm1a..."
docker exec qm1a bash -lc ". /opt/mqm/bin/setmqenv -s; strmqm ${QM_NAME}" || true
info "Starting STANDBY on qm1b..."
docker exec qm1b bash -lc ". /opt/mqm/bin/setmqenv -s; strmqm -x ${QM_NAME}" || true

wait_role "qm1a" "${QM_NAME}" "active"
wait_role "qm1b" "${QM_NAME}" "standby"

# DEV objects on ACTIVE
define_dev_objects "qm1a" "${QM_NAME}"

# ---------- VIP FILES ----------
info "Generating VIP compose + HAProxy config..."
mkdir -p haproxy

cat > "$COMPOSE_VIP" <<EOF
version: "3.8"
services:
  haproxy:
    image: haproxy:2.9
    container_name: mq-vip
    depends_on:
      - qm1a
      - qm1b
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - "${VIP_PORT}:${VIP_PORT}"
      - "${VIP_STATS_PORT}:8404"
    restart: unless-stopped
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
  server qm1a qm1a:1414 check
  server qm1b qm1b:1414 check
  # Prefer qm1a when both up? Uncomment backup:
  # server qm1b qm1b:1414 check backup

listen stats
  bind *:8404
  mode http
  stats enable
  stats uri /stats
  stats refresh 5s
  stats auth ${VIP_USER}:${VIP_PASS}
EOF

ok "VIP files ready (ports: ${VIP_PORT}, stats: ${VIP_STATS_PORT})."

# ---------- PROMOTE SCRIPT ----------
info "Writing promote_standby.sh ..."
cat > promote_standby.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
A_CNAME="${A_CNAME:-qm1a}"
B_CNAME="${B_CNAME:-qm1b}"
QM_NAME="${QM_NAME:-QM1}"
MODE="${MODE:-immediate}"   # immediate|quiesce
TIMEOUT="${TIMEOUT:-120}"
RETRY="${RETRY:-3}"

die(){ echo "ERROR: $*" >&2; exit 1; }
role_of() {
  local c="$1" out
  out="$(docker exec "$c" bash -lc ". /opt/mqm/bin/setmqenv -s; dspmq -m ${QM_NAME} -o status" 2>/dev/null || true)"
  if   echo "$out" | grep -qi "RUNNING as standby"; then echo "standby"
  elif echo "$out" | grep -q  "RUNNING";            then echo "active"
  else echo "down"; fi
}
wait_role() {
  local c="$1" want="$2" t=0
  while true; do
    [[ "$(role_of "$c")" == "$want" ]] && return 0
    sleep "$RETRY"; t=$((t+RETRY)); [[ $t -ge $TIMEOUT ]] && break
  done
  return 1
}
end_active() {
  local c="$1"
  case "$MODE" in
    immediate) docker exec "$c" bash -lc ". /opt/mqm/bin/setmqenv -s; endmqm -i ${QM_NAME}" ;;
    quiesce)   docker exec "$c" bash -lc ". /opt/mqm/bin/setmqenv -s; endmqm -s ${QM_NAME}" ;;
    *) die "MODE must be immediate|quiesce" ;;
  esac
}
start_standby(){ docker exec "$1" bash -lc ". /opt/mqm/bin/setmqenv -s; strmqm -x ${QM_NAME}" >/dev/null 2>&1 || true; }

RA="$(role_of "$A_CNAME")"; RB="$(role_of "$B_CNAME")"
if   [[ "$RA" == "active" && "$RB" == "standby" ]]; then ACTIVE="$A_CNAME"; TARGET="$B_CNAME"
elif [[ "$RB" == "active" && "$RA" == "standby" ]]; then ACTIVE="$B_CNAME"; TARGET="$A_CNAME"
else die "Expect one active, one standby (qm1a=$RA, qm1b=$RB)"; fi

start_standby "$TARGET"
wait_role "$TARGET" "standby" || die "Target not standby"

end_active "$ACTIVE"
wait_role "$TARGET" "active" || die "Promotion failed"

start_standby "$ACTIVE" || true
wait_role "$ACTIVE" "standby" || echo "Old active not standby yet (check logs)"

echo "Promotion complete: qm1a=$(role_of qm1a), qm1b=$(role_of qm1b)"
EOS
chmod +x promote_standby.sh
ok "promote_standby.sh ready."

# ---------- MAKEFILE ----------
info "Writing Makefile ..."
cat > Makefile <<EOF
PROJECT_FILES=${COMPOSE_FILE} ${COMPOSE_VIP} haproxy/haproxy.cfg promote_standby.sh

up:
\tdocker compose -f ${COMPOSE_FILE} up -d

down:
\tdocker compose -f ${COMPOSE_FILE} down

vip-up:
\tdocker compose -f ${COMPOSE_FILE} -f ${COMPOSE_VIP} up -d haproxy

vip-down:
\tdocker compose -f ${COMPOSE_FILE} -f ${COMPOSE_VIP} rm -s -f haproxy || true
\tdocker compose -f ${COMPOSE_FILE} -f ${COMPOSE_VIP} stop haproxy || true

promote:
\t./promote_standby.sh

status:
\tdocker exec qm1a bash -lc ". /opt/mqm/bin/setmqenv -s; dspmq -m ${QM_NAME} -o status" || true
\tdocker exec qm1b bash -lc ". /opt/mqm/bin/setmqenv -s; dspmq -m ${QM_NAME} -o status" || true

logs:
\tdocker logs --tail=80 qm1a || true
\tdocker logs --tail=80 qm1b || true

clean: down vip-down
\trm -f ${COMPOSE_VIP}
\trm -f Makefile promote_standby.sh
\trm -rf haproxy
\t# Uncomment to wipe shared data (DANGER):
\t# sudo rm -rf ./shared
EOF
ok "Makefile ready."

# ---------- SUMMARY ----------
echo ""
echo -e "${YELLOW}📄 MIQM + VIP Summary${NC}"
printf "%-11s %-8s %-18s %-18s\n" "SERVICE" "ROLE" "LISTEN" "WEB"
printf "%-11s %-8s %-18s %-18s\n" "qm1a" "ACTIVE"  "localhost:${PORT_ACTIVE}->1414" "localhost:${WEB_ACTIVE}->9443"
printf "%-11s %-8s %-18s %-18s\n" "qm1b" "STANDBY" "localhost:${PORT_STANDBY}->1414" "localhost:${WEB_STANDBY}->9443"
printf "%-11s %-8s %-18s %-18s\n" "haproxy" "VIP"   "localhost:${VIP_PORT}"         "stats: ${VIP_USER}:${VIP_PASS}@${VIP_STATS_PORT}"

echo ""
ok "Next steps:"
echo "  make vip-up                 # start VIP (haproxy) on ${VIP_PORT}"
echo "  export MQSERVER=\"DEV.APP.SVRCONN/TCP/localhost(${VIP_PORT})\""
echo "  make promote                # swap roles (standby -> active)"
echo "  make status                 # show MIQM status"
echo "  open http://localhost:${VIP_STATS_PORT}/stats  (user: ${VIP_USER}, pass: ${VIP_PASS})"
echo ""
ok "Done."