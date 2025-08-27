# IBM MQ Native-HA Cross-Region Replication (Docker)

**Purpose:** Demonstrate Native-HA queue manager disaster recovery by replicating a three-node Raft group to a remote region using IBM MQ 9.4's cross-region replication (CRR) capability.  This guide adapts IBM's OpenShift-focused documentation for a Docker-based lab running on Rocky Linux.

---

## 1. Scope & Audience
This document targets engineers and architects experimenting with IBM MQ cross‑region replication on non-production hosts.  It assumes familiarity with Docker, bash, and basic MQ administration.

---

## 2. Architecture Overview

```
+--------------------+         async replication        +--------------------+
|  Region A (primary)|  ------------------------------>  | Region B (replica) |
|  ┌──────────────┐  |                                 |  ┌──────────────┐  |
|  | qmha-a       |  |                                 |  | qmha-dr-a    |  |
|  | qmha-b       |  |        docker network(s)        |  | qmha-dr-b    |  |
|  | qmha-c       |  |                                 |  | qmha-dr-c    |  |
|  └──────────────┘  |                                 |  └──────────────┘  |
+--------------------+                                 +--------------------+
```

* Each region runs a **three-node Native‑HA** queue manager group.
* Region A acts as **primary**, Region B as **DR replica**.
* CRR ships raft log updates asynchronously from Region A to Region B.
* A simple **VIP/HAProxy** can front the active instance in each region if desired.

---

## 3. Requirements

| Item | Notes |
|---|---|
| Rocky Linux host(s) | One host can run both regions for lab purposes.  For realistic testing, use separate hosts or VMs. |
| Docker Engine + Compose v2 | `dnf install docker-ce docker-compose-plugin` |
| IBM MQ 9.4 container image | Pull `icr.io/ibm-messaging/mq:9.4.x.x` (accept license). |
| Open ports | Two sets of listener/admin ports plus replication ports (`1500+`). |
| Bash & coreutils | Used in sample scripts. |

---

## 4. Step-by-Step Setup

### 4.1 Create directories
```bash
mkdir -p primary data/primary-{a,b,c}
mkdir -p dr data/dr-{a,b,c}
```

### 4.2 Sample Compose for Region A (primary)
Create `primary/docker-compose.yml`:
```yaml
version: "3.9"
services:
  qmha-a:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-a
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ../data/primary-a:/mnt/mqm
    ports:
      - "1414:1414"
  qmha-b:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-b
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ../data/primary-b:/mnt/mqm
  qmha-c:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-c
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=PRIMARY
      - MQ_DR_REPLICA_HOSTS=qmha-dr-a:1500,qmha-dr-b:1500,qmha-dr-c:1500
    volumes:
      - ../data/primary-c:/mnt/mqm
```

### 4.3 Sample Compose for Region B (replica)
Create `dr/docker-compose.yml`:
```yaml
version: "3.9"
services:
  qmha-dr-a:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-dr-a
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ../data/dr-a:/mnt/mqm
  qmha-dr-b:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-dr-b
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ../data/dr-b:/mnt/mqm
  qmha-dr-c:
    image: icr.io/ibm-messaging/mq:9.4
    hostname: qmha-dr-c
    environment:
      - LICENSE=accept
      - MQ_NATIVE_HA=true
      - MQ_QMGR_NAME=QMHA
      - MQ_DR_ROLE=REPLICA
    volumes:
      - ../data/dr-c:/mnt/mqm
```

### 4.4 Start both regions
```bash
(cd primary && docker compose up -d)
(cd dr && docker compose up -d)
```

### 4.5 Enable cross-region replication
Run once inside any **primary** container (for example `qmha-a`):
```bash
docker exec -it qmha-a bash -lc "mqcli crtmqha --dr-replica qmha-dr-a:1500 qmha-dr-b:1500 qmha-dr-c:1500"
```
The command registers Region B nodes as asynchronous replicas.  Logs in `/var/mqm/errors/AMQERR01.LOG` confirm link activation.

---

## 5. Testing

1. **Put/Get via primary:**
   ```bash
   docker exec -it qmha-a bash -lc "/opt/mqm/samp/bin/amqsput TEST.QMGR QMHA"
   docker exec -it qmha-a bash -lc " /opt/mqm/samp/bin/amqsget TEST.QMGR QMHA"
   ```
2. **Verify replica sync:**
   ```bash
   docker exec -it qmha-dr-a bash -lc "dspmq"    # should show 'Replica'
   docker exec -it qmha-dr-a bash -lc "dspmq -o status"
   ```
3. **Failover simulation:** stop Region A containers and promote replica:
   ```bash
   docker compose -f primary/docker-compose.yml down
   docker exec -it qmha-dr-a bash -lc "mqcli rdqm --promote"
   ```
   Clients can now connect to Region B listener.

---

## 6. Troubleshooting

| Symptom | Possible Cause | Resolution |
|---|---|---|
| Replica containers show `ERROR: unknown option --dr-replica` | Using MQ image < 9.4 | Pull IBM MQ 9.4 or later image. |
| `mqcli crtmqha` fails with connectivity errors | Hostname resolution between regions | Ensure Docker networks allow cross‑region name/port reachability or use IPs. |
| Replica not catching up after network outage | Stale CRR session | Restart `mqcli` replica process: `docker restart qmha-dr-a` |
| Promotion fails | Replica not fully synchronized | Check `/var/mqm/errors/` and ensure `dspmq -o status` reports `REPLICA-SYNCED` before promotion. |

---

## 7. Cleanup
```bash
(cd primary && docker compose down)
(cd dr && docker compose down)
rm -rf data
```

---

## 8. References
* IBM MQ 9.4 documentation – *Native HA cross‑region replication* (requires IBM ID).
* `mqcli crtmqha` command reference.

---

## 9. Change History
| Date | Version | Change |
|---|---|---|
| 2025‑08‑27 | 0.1.0 | Initial Docker adaptation for CRR |

