# IBM MQ Managed File Transfer (MFT) — Container Quickstart

This README describes how to use `build_mq_mft.sh` to stand up a **4-container IBM MQ MFT lab**:

* **Container 1**: `qmcoord` — Queue Manager **`QMCOORD`** + **MFT Coordination Server**
* **Container 2**: `qmcmd` — Queue Manager **`QMCMD`** + **MFT Command Server**
* **Container 3**: `qmagent` — Queue Manager **`QMAGENT`** + **MFT Agent Server** (local agent host)
* **Container 4**: `mftagent` — **MFT Agent only** (no queue manager; remote to `QMAGENT`)

> ⚠️ **Dev-only defaults**: Open channel rules, plaintext credentials, no TLS. Use for labs/SIT only; tighten for production.

---

## Contents

- [IBM MQ Managed File Transfer (MFT) — Container Quickstart](#ibm-mq-managed-file-transfer-mft--container-quickstart)
  - [Contents](#contents)
  - [What this script does](#what-this-script-does)
  - [Prerequisites](#prerequisites)
  - [Quick start](#quick-start)
  - [Default topology \& ports](#default-topology--ports)
  - [Configuration (env vars)](#configuration-env-vars)
  - [What gets created](#what-gets-created)
  - [Health checks \& verification](#health-checks--verification)
    - [Container / QM status](#container--qm-status)
    - [MFT pings \& inventories](#mft-pings--inventories)
    - [Logs](#logs)
  - [Sample file transfer](#sample-file-transfer)
  - [Troubleshooting](#troubleshooting)
    - [“MFT CLI not found…”](#mft-cli-not-found)
    - [Port already in use](#port-already-in-use)
    - [`2035 MQRC_NOT_AUTHORIZED`](#2035-mqrc_not_authorized)
    - [Agent stuck in “Submitted”](#agent-stuck-in-submitted)
    - [DNS/hostnames](#dnshostnames)
  - [Security hardening (production)](#security-hardening-production)
  - [Cleanup](#cleanup)
  - [FAQ](#faq)
  - [License](#license)

---

## What this script does

1. **Validates** dependencies (`docker`, `docker compose`, `ss`/`netstat`) and that assigned ports are free.
2. **Cleans** any previous stack; recreates `./data` and `./mft` with correct ownership for MQ (`1001:0`).
3. **Generates** a `docker-compose.yml` with the four services listed above.
4. **Starts** the containers and **waits** for `QMCOORD`, `QMCMD`, `QMAGENT` to reach `RUNNING`.
5. **Verifies** the **MFT CLI** exists in each container (requires MQ Advanced image).
6. **Defines** a DEV listener and `DEV.APP.SVRCONN` channel on each QM.
7. **Configures** MFT:

   * Sets up **Coordination** on `QMCOORD`
   * Sets up **Command** on `QMCMD`
   * Creates & starts **local agent** on `QMAGENT` (`AGENT_LCL`)
   * Creates & starts **remote agent** inside `mftagent` (`AGENT_REM`), connected to `QMAGENT`
8. Prints a **deployment summary** with port mappings and quick commands.

---

## Prerequisites

* **Docker Engine** and **Docker Compose v2** (`docker compose …`)
* **Linux/macOS** shell with `bash` and `ss` (or `netstat`) for port checks
* **IBM MQ container image with MFT** (MQ Advanced capability). The script defaults to `ibmcom/mq:latest` — make sure your tag includes **MFT** tools under `/opt/mqm/mqft/bin`.

> If the image lacks MFT, the script will stop with:
> “MFT CLI not found… Switch IMAGE\_NAME/IMAGE\_TAG to an MQ Advanced build…”

---

## Quick start

```bash
# 1) Make it executable
chmod +x build_mq_mft.sh

# 2) (Optional) Choose an MQ Advanced image
export IMAGE_NAME=ibmcom/mq
export IMAGE_TAG=9.4.x-advanced   # example tag that includes MFT

# 3) Run it
./build_mq_mft.sh

# 4) Review the summary and try quick checks the script prints at the end
```

> Re-run the script to rebuild from scratch; it tears down the previous stack and recreates volumes under `./data` and `./mft`.

---

## Default topology & ports

```
Host                   Container        Role                         Ports
----                   ---------        ----                         -----
localhost:1415         qmcoord:1414     QMCOORD + MFT Coordination   localhost:9444 -> qmcoord:9443 (Admin Web)
localhost:1416         qmcmd:1414       QMCMD   + MFT Command        localhost:9445 -> qmcmd:9443
localhost:1417         qmagent:1414     QMAGENT + MFT Agent Server   localhost:9446 -> qmagent:9443
(n/a)                  mftagent         MFT Agent only (no QM)       (no ports)
```

---

## Configuration (env vars)

Override any of these before running the script:

| Variable            |              Default | Purpose                               |
| ------------------- | -------------------: | ------------------------------------- |
| `IMAGE_NAME`        |          `ibmcom/mq` | MQ container image (must include MFT) |
| `IMAGE_TAG`         |             `latest` | Image tag                             |
| `COMPOSE_FILE`      | `docker-compose.yml` | Compose filename to generate          |
| `DATA_DIR`          |             `./data` | Persistent MQ volumes per QM          |
| `MFT_DIR`           |              `./mft` | MFT home per container                |
| `COORD_QM`          |            `QMCOORD` | Coordination QM name                  |
| `CMD_QM`            |              `QMCMD` | Command QM name                       |
| `AGENT_QM`          |            `QMAGENT` | Agent host QM name                    |
| `MFT_DOMAIN`        |             `MFTDOM` | MFT domain name                       |
| `AGENT_LOCAL_NAME`  |          `AGENT_LCL` | Local agent name (on `qmagent`)       |
| `AGENT_REMOTE_NAME` |          `AGENT_REM` | Remote agent name (in `mftagent`)     |
| `PORT_QMCOORD`      |               `1415` | Host → `qmcoord:1414`                 |
| `PORT_QMCMD`        |               `1416` | Host → `qmcmd:1414`                   |
| `PORT_QMAGENT`      |               `1417` | Host → `qmagent:1414`                 |
| `PORT_WEB_COORD`    |               `9444` | Host → `qmcoord:9443`                 |
| `PORT_WEB_CMD`      |               `9445` | Host → `qmcmd:9443`                   |
| `PORT_WEB_AGENT`    |               `9446` | Host → `qmagent:9443`                 |
| `MQ_ADMIN_PASSWORD` |          `adminpass` | Admin password (dev)                  |
| `MQ_APP_PASSWORD`   |           `passw0rd` | App password (dev)                    |
| `START_TIMEOUT`     |                `120` | Seconds to wait for QMs to run        |
| `RETRY_SLEEP`       |                  `4` | Seconds between polls                 |

---

## What gets created

* **Compose stack** (`docker-compose.yml`) with services `qmcoord`, `qmcmd`, `qmagent`, `mftagent`
* **Per-QM data dirs**: `./data/QMCOORD`, `./data/QMCMD`, `./data/QMAGENT` (owned `1001:0`)
* **Per-container MFT dirs**: `./mft/QMCOORD`, `./mft/QMCMD`, `./mft/QMAGENT`, and `./mft/agent`
* **DEV listener & channel** on each QM:

  * `LISTENER(TCP.LST)` on port `1414`
  * `CHANNEL(DEV.APP.SVRCONN)` (open CHLAUTH mapping for labs)
* MFT **Coordination** bound to `QMCOORD`
* MFT **Command** bound to `QMCMD`
* Agents: **`AGENT_LCL`** on `QMAGENT`, **`AGENT_REM`** in `mftagent`

---

## Health checks & verification

### Container / QM status

```bash
docker ps
docker exec qmcoord bash -lc "dspmq -o status"
docker exec qmcmd   bash -lc "dspmq -o status"
docker exec qmagent bash -lc "dspmq -o status"
```

### MFT pings & inventories

```bash
# Ping agents from the command server
docker exec qmcmd bash -lc ". /opt/mqm/bin/setmqenv -s; /opt/mqm/mqft/bin/ftePingAgent -d MFTDOM AGENT_LCL"
docker exec qmcmd bash -lc ". /opt/mqm/bin/setmqenv -s; /opt/mqm/mqft/bin/ftePingAgent -d MFTDOM AGENT_REM"

# List agents and monitors
docker exec qmcoord bash -lc ". /opt/mqm/bin/setmqenv -s; /opt/mqm/mqft/bin/fteListAgents -d MFTDOM"
docker exec qmcmd   bash -lc ". /opt/mqm/bin/setmqenv -s; /opt/mqm/mqft/bin/fteListMonitors -d MFTDOM"
```

### Logs

```bash
# MQ error logs
docker exec qmagent bash -lc "tail -n 100 /var/mqm/errors/AMQERR01.LOG"

# MFT agent logs
docker exec qmagent  bash -lc "tail -n 100 /var/mqm/mqft/logs/AGENT_LCL/agent.log"
docker exec mftagent bash -lc "tail -n 100 /var/mqm/mqft/logs/AGENT_REM/agent.log"
```

---

## Sample file transfer

**Goal:** copy a test file from **`AGENT_REM`** (in `mftagent`) to **`AGENT_LCL`** (on `qmagent`).

1. Prepare source & destination paths:

```bash
# Source side (remote agent container)
docker exec mftagent bash -lc '
  mkdir -p /var/mqm/mqft/src &&
  echo "Hello from REM at $(date -Is)" > /var/mqm/mqft/src/hello.txt &&
  ls -l /var/mqm/mqft/src
'

# Destination side (local agent container)
docker exec qmagent bash -lc '
  mkdir -p /var/mqm/mqft/dst && ls -ld /var/mqm/mqft/dst
'
```

2. Create transfer from the **command server**:

```bash
docker exec qmcmd bash -lc '
  . /opt/mqm/bin/setmqenv -s
  /opt/mqm/mqft/bin/fteCreateTransfer \
    -d MFTDOM \
    -sa AGENT_REM \
    -da AGENT_LCL \
    -sm once \
    -de overwrite \
    -v \
    -s "/var/mqm/mqft/src/hello.txt" \
    -d "/var/mqm/mqft/dst/hello.txt"
'
```

3. Verify at destination:

```bash
docker exec qmagent bash -lc '
  ls -l /var/mqm/mqft/dst &&
  echo "---- DEST CONTENT ----" &&
  head -n 2 /var/mqm/mqft/dst/hello.txt
'
```

> Want more? Run a wildcard sync:

```bash
docker exec mftagent bash -lc '
  for i in 1 2 3; do echo "file $i @ $(date -Is)" > /var/mqm/mqft/src/file${i}.txt; done
'
docker exec qmcmd bash -lc "
  . /opt/mqm/bin/setmqenv -s
  /opt/mqm/mqft/bin/fteCreateTransfer -d MFTDOM -sa AGENT_REM -da AGENT_LCL \
    -sm once -de overwrite -v \
    -s '/var/mqm/mqft/src/*.txt' -d '/var/mqm/mqft/dst/'
"
docker exec qmagent bash -lc 'ls -l /var/mqm/mqft/dst'
```

---

## Troubleshooting

### “MFT CLI not found…”

Use an **MQ Advanced** image that includes `/opt/mqm/mqft/bin/*`.
Set:

```bash
export IMAGE_NAME=ibmcom/mq
export IMAGE_TAG=9.4.x-advanced   # example tag
```

### Port already in use

Change `PORT_QMCOORD`, `PORT_QMCMD`, `PORT_QMAGENT`, `PORT_WEB_*` or stop conflicting services.

### `2035 MQRC_NOT_AUTHORIZED`

For quick lab testing (DEV ONLY), the script opens `DEV.APP.SVRCONN` CHLAUTH to `mqm`. In controlled environments, tighten CHLAUTH and/or use **TLS + user auth**.

### Agent stuck in “Submitted”

* Check both **Coordination** (`QMCOORD`) and **Command** (`QMCMD`) are reachable.
* Verify listener on `QMAGENT` is **running**.
* Inspect agent logs:

  ```bash
  docker exec qmagent  bash -lc "tail -n 100 /var/mqm/mqft/logs/AGENT_LCL/agent.log"
  docker exec mftagent bash -lc "tail -n 100 /var/mqm/mqft/logs/AGENT_REM/agent.log"
  ```

### DNS/hostnames

Compose network DNS resolves service names: `qmcoord`, `qmcmd`, `qmagent`. The `mftagent` container connects to `qmagent(1414)` over channel `DEV.APP.SVRCONN`.

---

## Security hardening (production)

* **TLS everywhere**: channels (mutual TLS), REST/WEB admin, agent comms.
* **CHLAUTH**: remove permissive rules; implement least-privilege mappings.
* **Credentials**: set strong `MQ_ADMIN_PASSWORD`, `MQ_APP_PASSWORD`; rotate regularly.
* **Principals & MQ auth**: allocate non-`mqm` MCAUSERs; object-level permissions.
* **SIEM**: ship MQ and MFT logs to Splunk/QRadar with appropriate retention.
* **Secrets**: provide certs/keys/passwords via Docker secrets or bind-mounts; never bake into images.

---

## Cleanup

```bash
# Stop and remove containers
docker compose down --remove-orphans

# Remove generated compose file and all volumes (⚠️ deletes MQ/MFT state)
rm -f docker-compose.yml
sudo rm -rf ./data ./mft
```

---

## FAQ

**Q: Can I point `AGENT_REM` at a different queue manager?**
Yes. Set `MQSERVER` in the `mftagent` service to the appropriate `SVRCONN`/host\:port and ensure CHLAUTH/TLS allow the connection.

**Q: Where are MFT configs stored?**
Under each container’s mounted path, e.g., `./mft/<QMNAME>` or `./mft/agent` (mapped to `/var/mqm/mqft`).

**Q: How do I add monitors/schedules?**
Use `fteCreateMonitor` and `fteListMonitors` from `qmcmd`, targeting `MFTDOM`. Add your XML rules under the agent’s directory as needed.

---

## License

This project is licensed under the **MIT License** (SPDX-License-Identifier: MIT). See script header for details.