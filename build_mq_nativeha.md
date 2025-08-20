IBM MQ Native-HA (Raft) – 3-Node Lab with HAProxy VIP

Status: Lab / Proof-of-Concept
Scope: Education & Demos only (not production)
Script: build_mq_nativeha.sh

This repository (or folder) contains a single command that provisions a three-node IBM MQ Native-HA (Raft) queue manager in Docker and generates a HAProxy VIP so clients have a stable TCP endpoint that always targets the active node.

The lab favors clarity over hardening: permissive channels, no TLS by default, and simple credentials. Use it to understand Native-HA behaviors (roles, replication, failover), verify client reconnect patterns, and demo operational flows.

⸻

Table of Contents
	•	What You Get
	•	Architecture
	•	Prerequisites
	•	Quick Start
	•	Configuration
	•	Ports
	•	Generated Files
	•	Makefile Targets
	•	Verification & Smoke Test
	•	Troubleshooting
	•	Security & Production Considerations
	•	Cleanup
	•	License

⸻

What You Get
	•	3 Docker containers: qmha-a, qmha-b, qmha-c
	•	One queue manager identity: QMHA (1 × Active, 2 × Replica)
	•	Per-node persistent data: ./nha/<node>/data
	•	Per-node configuration (INI + MQSC): ./nha/<node>/etc
	•	Host ports: 14181/14182/14183 mapped to container 1414 (one per node)
	•	VIP: HAProxy listening on :${VIP_PORT} (default 14180) with stats UI on :${VIP_STATS_PORT} (default 8404)
	•	Makefile with convenience targets for VIP lifecycle, status, and verification

⸻

Architecture

flowchart LR
  Client((MQ Clients)) -- MQI/JMS --> VIP[[HAProxy VIP :14180]]

  subgraph Cluster["IBM MQ Native-HA (Raft) Group"]
    direction LR
    A["qmha-a : QMHA\nROLE: Active/Replica\nListener 1414"]:::nha
    B["qmha-b : QMHA\nROLE: Replica\nNo listener"]:::nha
    C["qmha-c : QMHA\nROLE: Replica\nNo listener"]:::nha
  end

  VIP -->|tcp| A
  VIP -.failover.-> B
  VIP -.failover.-> C

  A <-. Raft Replication .-> B
  A <-. Raft Replication .-> C
  B <-. Raft Replication .-> C

  classDef nha stroke:#0d6efd,fill:#eef5ff,stroke-width:1.2px

How it works (high level):
	•	Each container hosts a local instance of the same queue manager (QMHA), with Raft peers declared via INI fragments under /etc/mqm (generated for you).
	•	Only the Active instance opens the listener (1414). Replicas remain closed for client connections.
	•	The HAProxy VIP performs simple TCP health checks and routes clients to whichever node is active.

⸻

Prerequisites
	•	Docker Engine and Docker Compose v2 (docker compose …)
	•	Host OS with bash and ss (or netstat)
	•	Container image: icr.io/ibm-messaging/mq (or compatible IBM MQ image)

The script is Linux/WSL2-friendly and expects GNU tooling.

⸻

Quick Start

# 1) Make the script executable
chmod +x build_mq_nativeha.sh

# 2) Build the lab (3 nodes + VIP stack + Makefile)
./build_mq_nativeha.sh

# 3) Bring up the VIP (HAProxy) if it didn't start automatically
make vip-up

# 4) (Optional) View VIP stats
open http://localhost:8404/stats    # user: admin  pass: admin

# 5) Point an MQ client at the VIP
export MQSERVER="DEV.APP.SVRCONN/TCP/localhost(14180)"
# ... then run your client or sample programs


⸻

Configuration

You can override any of the following environment variables before running the script:

Variable	Purpose	Default
IMAGE_NAME	MQ image reference	icr.io/ibm-messaging/mq
IMAGE_TAG	MQ image tag	9.4.3.0-r1
QM_NAME	Queue manager name	QMHA
MQ_ADMIN_PASSWORD	Admin password for MQ console (embedded)	adminpass
ENABLE_WEB	Enable embedded web console	true
ENABLE_METRICS	Enable Prometheus metrics	true
PORT_A / PORT_B / PORT_C	Host ports mapped to node listener (container 1414)	14181 / 14182 / 14183
REPL_PORT	Raft replication port on the Docker network	4444
VIP_PORT	HAProxy VIP listen port (host)	14180
VIP_STATS_PORT	HAProxy stats UI port (host)	8404
VIP_USER / VIP_PASS	HAProxy stats UI credentials	admin / admin
ROOT_DIR	Root folder for node data/config	./nha
COMPOSE_FILE	Compose file for nodes	docker-compose.nha.yml
VIP_COMPOSE	Compose file for VIP	docker-compose.vip.yml

Example:

IMAGE_TAG=9.4.2.0 MQ_ADMIN_PASSWORD='S3cure!' VIP_PORT=19000 ./build_mq_nativeha.sh


⸻

Ports

Component	Host Port(s)	Container Port	Notes
qmha-a	14181	1414	Active only node accepts connections
qmha-b	14182	1414	Replica – listener typically closed
qmha-c	14183	1414	Replica – listener typically closed
VIP (HAProxy)	14180	14180	Client entrypoint (TCP)
VIP Stats	8404	8404	http://localhost:8404/stats (auth required)


⸻

Generated Files

After a successful run you’ll see:

./docker-compose.nha.yml         # 3-node MQ stack
./docker-compose.vip.yml         # HAProxy VIP service
./haproxy/haproxy.cfg            # HAProxy configuration
./Makefile                       # Convenience targets

./nha/qmha-a/data                # Node A data (persistent)
./nha/qmha-a/etc/20-nativeha.ini # Node A Raft peers + LocalInstance
./nha/qmha-a/etc/10-dev.mqsc     # Dev listener + SVRCONN (lab only)
# ... same structure for qmha-b and qmha-c


⸻

Makefile Targets

Target	Description
make up	Start the three MQ nodes (from docker-compose.nha.yml)
make down	Stop the three MQ nodes
make vip-up	Start HAProxy VIP (mq-vip) on the same network
make vip-down	Stop/remove VIP container
make vip-reload	Reload HAProxy config (SIGHUP)
make status	Show MQ roles on each node and VIP container status
make verify	Run ./verify_nativeha.sh (if present)
make failover	Run verifier with simulated failover


⸻

Verification & Smoke Test

Check roles and listeners:

# On each node (example for qmha-a)
docker exec qmha-a bash -lc "dspmq -m QMHA -o status -o nativeha"
# Expect exactly one ROLE(Active); replicas show ROLE(Replica)

Test client connectivity via VIP:

# From your shell (or inside any container with MQ samples)
export MQSERVER="DEV.APP.SVRCONN/TCP/localhost(14180)"

# Put & get with IBM sample programs (if available in image)
docker exec qmha-a bash -lc "
  printf 'hello-vip\n' | /opt/mqm/samp/bin/amqsputc NHA.VERIFY.Q && \
  /opt/mqm/samp/bin/amqsgetc NHA.VERIFY.Q
"

Simulate failover (optional):

# Stop the active node (replace qmha-a with whichever is active)
docker stop qmha-a

# Watch a new Active get elected
make status

# Re-run the VIP put/get to confirm continuity

If you have verify_nativeha.sh, use:

./verify_nativeha.sh
./verify_nativeha.sh --simulate-failover



⸻

Troubleshooting
	•	Port already in use
Adjust PORT_A/B/C, VIP_PORT, VIP_STATS_PORT, or stop the conflicting service.
	•	Roles never settle / no Active
Confirm container hostnames (qmha-a/b/c) match the INI peer entries. Ensure containers share the mq-nha-net network and that REPL_PORT is reachable.
	•	VIP doesn’t route
make vip-up and open http://localhost:8404/stats (user/pass from env). Only the Active node should have an open listener; check with ss -ltn and dspmq.
	•	Client 2035 (Not Authorized)
This lab enables a DEV SVRCONN for simplicity. If you tightened CHLAUTH or set TLS, adjust client auth accordingly or use bindings mode for admin tests.

⸻

Security & Production Considerations

This lab is not production-grade:
	•	No TLS on channels or admin endpoints; no PKI integration
	•	Permissive channel/CHLAUTH rules (DEV listener & SVRCONN)
	•	No external identity (LDAP/OIDC), SIEM, or enterprise backup/restore
	•	Single host, single network; no multi-AZ/host HA

For real environments, enforce TLS, least-privilege CHLAUTH, external identity, observability, backups, and an orchestrated platform (e.g., Kubernetes with the MQ Operator).

⸻

Cleanup

# Stop VIP and nodes
make vip-down || true
make down || true

# Remove generated files and data
rm -f docker-compose.nha.yml docker-compose.vip.yml
rm -rf haproxy
sudo rm -rf ./nha   # ⚠️ deletes all queue manager data for this lab


⸻

License

MIT © The Authors. See script header for SPDX identifier.
