#!/bin/bash
# =============================================================================
# Script Name : build_mq_qmgrs.sh
# Description : Provision N IBM MQ queue managers as Docker containers, with
#               Admin Web Console and REST Admin endpoints exposed. Generates
#               a docker-compose.yml and starts the services.
#
# Author      : rob lee
# Maintainer  : rob@aztekmq.net
# Version     : 1.0.0
# Created     : 2025-04-14
# Last Update : 2025-08-19
# License     : MIT (SPDX-License-Identifier: MIT)
#
# Standards & Conventions:
#   - Dates use ISO 8601 (YYYY-MM-DD).
#   - Shell is Bash using POSIX-compatible patterns where practical.
#   - External tools: Docker Engine + Docker Compose v2, ss(8) for port checks.
#   - Documentation language uses RFC 2119 keywords (MUST/SHOULD/MAY).
#   - Container metadata aligns with OCI/Docker Compose format 3.8.
#
# Usage:
#   ./build_mq_qmgrs.sh <number_of_qmgrs>
#
#   Example:
#     ./build_mq_qmgrs.sh 3
#
# Behavior Summary:
#   1) Validates the numeric argument (N >= 1).
#   2) Verifies that computed host ports are not already in use.
#   3) Stops/removes previous Compose stack (if present) and deletes data dir.
#   4) Creates per-QM data directories with ownership matching the MQ image.
#   5) Generates docker-compose.yml with one service per queue manager.
#   6) Starts containers and prints a summary table.
#
# Exit Codes:
#   0  Successful completion.
#   1  Usage error, invalid argument, or port conflict detected.
#
# Security Notes (Informational):
#   - Default credentials (e.g., MQ_APP_PASSWORD) are placeholders and MUST be
#     changed for non-development use.
#   - Consider setting MQ_ADMIN_PASSWORD and enabling TLS for production.
#
# Dependencies (Informational):
#   - docker (Engine & Compose v2: `docker compose` CLI)
#   - ss(8) for port conflict detection (iproute2). If unavailable, substitute
#     with `netstat -ltn` and adjust the check accordingly.
#
# Shell Quality:
#   - This script intentionally avoids `set -euo pipefail` to preserve original
#     behavior. If you adopt it, test thoroughly in your environment.
#   - Recommended linting with ShellCheck: https://www.shellcheck.net/
# =============================================================================
 
# --------- CONFIG ---------
# Number of queue managers to create; required positional argument.
NUM_QMGRS="$1"
# Base ports for host mappings. Each QM uses base + i (i in 1..N).
BASE_LISTENER_PORT=1414   # Maps to container port 1414 (MQ listener)
BASE_WEB_PORT=9443        # Maps to container port 9443 (Admin Web)
BASE_REST_PORT=9449       # Maps to container port 9449 (Admin REST)
# Root data directory for persistent volumes (one subdir per QM).
DATA_DIR="./data"
# Container image name and tag. Ensure the image is available locally/remotely.
IMAGE_NAME="ibmcom/mq"
# Output path for the generated Docker Compose definition.
COMPOSE_FILE="docker-compose.yml"
 
# --------- COLORS ---------
# ANSI color escape codes for user-friendly terminal output.
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color
 
# --------- Validation ---------
# Validate that NUM_QMGRS is a non-empty, positive integer.
if [[ -z "$NUM_QMGRS" || ! "$NUM_QMGRS" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ Usage: $0 <number_of_qmgrs>${NC}"
  exit 1
fi
 
# --------- Port Conflict Detection ---------
# For each queue manager instance i (1..N), compute external host ports and
# ensure none is currently bound. Fails fast on first conflict encountered.
echo -e "${CYAN}🔎 Checking for port conflicts...${NC}"
 
for ((i=1; i<=NUM_QMGRS; i++)); do
  LISTENER_PORT=$((BASE_LISTENER_PORT + i))
  WEB_PORT=$((BASE_WEB_PORT + i))
  REST_PORT=$((BASE_REST_PORT + i))
 
  for PORT in $LISTENER_PORT $WEB_PORT $REST_PORT; do
    # Uses ss(8) to check for an existing listening TCP socket on the host.
    # Note: Some platforms require sudo for ss; adapt as needed.
    if ss -ltn | grep -q ":$PORT "; then
      echo -e "${RED}❌ Port $PORT already in use. Cannot continue.${NC}"
      exit 1
    fi
  done
done
 
echo -e "${GREEN}✅ No port conflicts detected.${NC}"
 
# --------- Cleanup Old Environment ---------
# Bring down any prior Compose stack in the current directory and remove
# the previously generated Compose file and data directory (if present).
# WARNING: Deleting DATA_DIR removes persisted MQ data for all instances.
echo -e "${CYAN}🧹 Cleaning up old containers and volumes...${NC}"
 
docker compose down --remove-orphans >/dev/null 2>&1
rm -f "$COMPOSE_FILE"
 
if [[ -d "$DATA_DIR" ]]; then
  sudo rm -rf "$DATA_DIR"
fi
 
# --------- Create Data Directories ---------
# Create per-instance data subdirectories and set ownership to 1001:0 to match
# the MQ process user within the official container image.
echo -e "${CYAN}📂 Creating data directories...${NC}"
 
for ((i=1; i<=NUM_QMGRS; i++)); do
  QMGR_NAME="QM${i}"
  mkdir -p "${DATA_DIR}/${QMGR_NAME}"
  sudo chown -R 1001:0 "${DATA_DIR}/${QMGR_NAME}"
done
 
# --------- Generate docker-compose.yml ---------
# Compose file aligns with version 3.8 schema. For each QM instance, create
# a service named as the lowercase QMGR name (e.g., qm1), mapping computed
# host ports to the container's standard MQ ports. Healthcheck uses `mqcli`.
echo -e "${CYAN}🛠 Generating $COMPOSE_FILE...${NC}"
 
cat <<EOF > "$COMPOSE_FILE"
version: '3.8'
services:
EOF
 
for ((i=1; i<=NUM_QMGRS; i++)); do
  QMGR_NAME="QM${i}"
  LISTENER_PORT=$((BASE_LISTENER_PORT + i))
  WEB_PORT=$((BASE_WEB_PORT + i))
  REST_PORT=$((BASE_REST_PORT + i))
 
  cat <<EOF >> "$COMPOSE_FILE"
  ${QMGR_NAME,,}:
    image: $IMAGE_NAME
    container_name: ${QMGR_NAME,,}
    environment:
      - LICENSE=accept
      - MQ_QMGR_NAME=${QMGR_NAME}
      - MQ_APP_PASSWORD=passw0rd
      - MQ_ENABLE_METRICS=true
      - MQ_ENABLE_ADMIN_WEB=true
    ports:
      - "${LISTENER_PORT}:1414"
      - "${WEB_PORT}:9443"
      - "${REST_PORT}:9449"
    volumes:
      - ./data/${QMGR_NAME}:/mnt/mqm
    healthcheck:
      test: ["CMD", "mqcli", "status"]
      interval: 30s
      timeout: 10s
      retries: 5
    restart: unless-stopped
 
EOF
done
 
# --------- Start Containers ---------
# Start all services in detached mode. On success, Compose exits 0 and the
# script proceeds to print a structured summary of the deployment.
echo -e "${CYAN}🚀 Starting up $NUM_QMGRS IBM MQ containers...${NC}"
docker compose up -d
 
# --------- Summary ---------
# Present a clean table of the deployed instances, including container names
# and host port mappings for listener, admin web, and admin REST endpoints.
echo -e "${GREEN}✅ All containers started successfully.${NC}"
echo ""
echo -e "${YELLOW}📄 Deployment Summary:${NC}"
 
printf "%-10s %-20s %-15s %-15s %-15s\n" "QMGR" "CONTAINER NAME" "LISTENER PORT" "WEB PORT" "REST PORT"
printf "%-10s %-20s %-15s %-15s %-15s\n" "----" "---------------" "-------------" "---------" "---------"
 
for ((i=1; i<=NUM_QMGRS; i++)); do
  QMGR_NAME="QM${i}"
  CONTAINER_NAME="${QMGR_NAME,,}"
  LISTENER_PORT=$((BASE_LISTENER_PORT + i))
  WEB_PORT=$((BASE_WEB_PORT + i))
  REST_PORT=$((BASE_REST_PORT + i))
 
  printf "%-10s %-20s %-15s %-15s %-15s\n" "$QMGR_NAME" "$CONTAINER_NAME" "$LISTENER_PORT" "$WEB_PORT" "$REST_PORT"
done
 
echo ""
echo -e "${CYAN}👉 To connect to a container: ${NC}"
echo -e "${CYAN}docker exec -it <container_name> bash${NC}"
echo ""
 
# =============================================================================
# End of file
# =============================================================================