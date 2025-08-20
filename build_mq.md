
# IBM MQ Multi–Queue Manager Builder (Docker)

**Script:** `build_mq_qmgrs.sh`  
**Purpose:** Provision **N** IBM MQ queue managers as Docker containers with the **Admin Web Console** and **REST Admin** endpoints exposed.  
**Author:** Aztekmq, LLC  
**Initial Release:** 2025‑04‑14 (ISO 8601)

---

## 1. Scope & Audience
This document describes how to use, operate, and maintain the `build_mq_qmgrs.sh` utility. It follows widely recognized software documentation practices aligned with international conventions (e.g., POSIX-compatible shell usage, OCI/Docker Compose specifications, ISO 8601 date formats, and security hardening guidance inspired by OWASP).  
**Audience:** DevOps engineers, MQ administrators, and testers needing quickly repeatable MQ lab environments.

---

## 2. Overview
The script generates a `docker-compose.yml` and launches **N** IBM MQ containers. For each container:
- A unique **listener port** (external) is mapped to container MQ port **1414**.
- A unique **Admin Web** port (external) is mapped to container port **9443**.
- A unique **Admin REST** port (external) is mapped to container port **9449**.
- A persistent data directory is created under `./data/QM<i>` and owned by UID:GID `1001:0` (the MQ container process).

The script also implements:
- **Port conflict detection** (fails fast if any computed port is already bound).
- **Idempotent cleanup** of old Compose stacks and data (optional, see §9 Safe Use).  
- **Healthchecks** via `mqcli status` in each service.

> **Important**: This utility is designed for development/test environments. For production, see §10 Security Hardening.

---

## 3. System Requirements

### 3.1 Software
- **Docker Engine** with **Docker Compose v2** (`docker compose …` CLI).
- **Bash** on a POSIX-like OS (Linux/macOS).  
- **ss(8)** (from `iproute2`) used for local port checks. On systems without `ss`, consider adding a fallback to `netstat`.

### 3.2 Network & Host
- Host firewall should allow chosen external ports (see §6).
- Sufficient disk space for MQ data under `./data/`.

### 3.3 IBM MQ Container Image
- Image: `ibmcom/mq`  
- EULA acceptance: `LICENSE=accept` is set by the script.
- Ensure your host has access to the image (Docker Hub, IBM Container Registry mirror, or local cache).

---

## 4. Parameters & Configuration

### 4.1 CLI Argument
| Parameter | Required | Type | Description | Example |
|---|---|---|---|---|
| `<number_of_qmgrs>` | Yes | Positive integer | Number of queue managers to create | `3` |

### 4.2 Script Constants (edit inside the script if needed)
| Variable | Default | Description |
|---|---|---|
| `BASE_LISTENER_PORT` | `1414` | Base host port; each QM uses `BASE_LISTENER_PORT + i` mapped to container `1414` |
| `BASE_WEB_PORT` | `9443` | Base host port; each QM uses `BASE_WEB_PORT + i` mapped to container `9443` |
| `BASE_REST_PORT` | `9449` | Base host port; each QM uses `BASE_REST_PORT + i` mapped to container `9449` |
| `DATA_DIR` | `./data` | Root directory for per‑QM data volumes |
| `IMAGE_NAME` | `ibmcom/mq` | Container image name |
| `COMPOSE_FILE` | `docker-compose.yml` | Generated Compose file path |

### 4.3 Environment Variables (inside Compose service)
| Variable | Meaning | Notes |
|---|---|---|
| `LICENSE=accept` | Accepts IBM MQ container license | Required to run containers |
| `MQ_QMGR_NAME` | Queue manager name (e.g., `QM1`) | Set per service |
| `MQ_APP_PASSWORD=passw0rd` | Password for **application** user | **Not recommended** for production; change per §10 |
| `MQ_ENABLE_METRICS=true` | Enables Prometheus‑style metrics | Optional |
| `MQ_ENABLE_ADMIN_WEB=true` | Enables Admin Web console | Requires secure configuration per §10 |

> **Admin credentials:** The image supports `MQ_ADMIN_PASSWORD` to set the Admin user’s password. This script does **not** set it; configure explicitly for secure access (see §10).

---

## 5. Usage

### 5.1 Run
```bash
chmod +x build_mq_qmgrs.sh
./build_mq_qmgrs.sh 3
```

### 5.2 What Happens
1. **Validation:** Confirms the argument is a positive integer.  
2. **Port Check:** Verifies that ports `{1414+i, 9443+i, 9449+i}` for `i ∈ [1,N]` are free using `ss -ltn`.  
3. **Cleanup:** Executes `docker compose down --remove-orphans`, removes any existing `docker-compose.yml`, and deletes `./data` (if present).  
4. **Directories:** Creates `./data/QM<i>` and sets ownership to `1001:0`.  
5. **Compose Generation:** Writes a `version: "3.8"` Compose file with one service per QM (`qm1`, `qm2`, …).  
6. **Startup:** Runs `docker compose up -d`.  
7. **Summary:** Prints a table mapping QMGR → container → ports.

---

## 6. Port Mapping
For `N` managers numbered `i=1..N`:

| Item | Host Port | Container Port |
|---|---:|---:|
| Listener (SVRCONN, channels) | `1414 + i` | `1414` |
| Admin Web Console (HTTPS) | `9443 + i` | `9443` |
| Admin REST API (HTTPS) | `9449 + i` | `9449` |

**Example (`N=2`):**
- `QM1` → listener `1415`, web `9444`, REST `9450`
- `QM2` → listener `1416`, web `9445`, REST `9451`

---

## 7. Data Persistence
Each service mounts `./data/QM<i>` to `/mnt/mqm` inside the container. The script sets ownership to UID:GID `1001:0` to match the MQ process user inside the image.  
> On SELinux-enabled hosts, you may need a `:Z` flag in the volume mapping for proper labeling (not included by default).

---

## 8. Health & Verification

### 8.1 Container Health
- Healthcheck: `mqcli status` (interval 30s; timeout 10s; 5 retries)
- Verify status:
  ```bash
  docker compose ps
  docker logs qm1 --tail=100
  docker exec -it qm1 bash -lc 'dspmq && runmqsc $(dspmq -o command | sed -n "s/.*-m \([^ ]*\).*/\1/p") <<EOF
  DISPLAY QMGR
  END
  EOF'
  ```

### 8.2 Endpoint Reachability (examples)
- Web Console (HTTPS): `https://<host>:9444/ibmmq/console/`  
- REST Admin (HTTPS): `https://<host>:9450/ibmmq/rest/v2/`  
> **Credentials:** Configure `MQ_ADMIN_PASSWORD` to access administrative endpoints securely (see §10).

---

## 9. Safe Use & Idempotency
The script **removes** prior deployments:
- `docker compose down --remove-orphans`
- Deletes the previous `docker-compose.yml`
- **Deletes the entire `./data` directory**

> **Warning:** This will remove **all** persisted MQ data under `./data`. For safer re-runs, comment out the deletion section or back up data first.

---

## 10. Security Hardening (Recommended for Non‑Lab Use)
- **Set Admin Password:** Add `MQ_ADMIN_PASSWORD=<strong>` to the environment for each service before first start.
- **Disable Public Exposure:** Bind to loopback or restricted interfaces, or use reverse proxies/VPN.
- **TLS:** Configure TLS for channel 1414 and for the web/REST interfaces.
- **Least Privilege:** Avoid running the script with `sudo` unless required for file ownership; prefer managed users and groups.
- **Secrets Management:** Use Compose `.env` or Docker secrets for credentials.
- **Firewall/ACLs:** Limit access to administrative ports (9443/9449).
- **CHLAUTH & CONNAUTH:** Enforce MQ channel and connection authentication policies on each QM.
- **Rotate Credentials:** Regularly change any static passwords (`MQ_APP_PASSWORD`, `MQ_ADMIN_PASSWORD`).

---

## 11. Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `❌ Port <X> already in use` | Another process bound to computed port | Adjust base ports or stop conflicting service |
| Permission denied writing `./data` | Insufficient host FS perms | Run with a user that can write to project dir; verify `chown 1001:0` success |
| Containers start but unhealthy | QM initialization issues | `docker logs <container>`; inspect `/var/mqm/errors/` inside container |
| Cannot log in to Web Console | Admin creds not set | Define `MQ_ADMIN_PASSWORD` and recreate the service |
| SELinux volume errors | Missing labels | Use `:Z` volume option or configure SELinux contexts |
| `docker compose` not found | Compose v1 vs v2 | Install Compose v2 or alias `docker-compose` → `docker compose` |

---

## 12. Extensibility
- Add per‑QM overlays (TLS/certs, mqsc scripts, CHLAUTH policies).
- Parameterize via environment (`.env`) instead of editing the script.
- Emit the generated `docker-compose.yml` to a configurable path.
- Add an option **not** to delete `./data` for incremental runs.

---

## 13. Operational Runbook (Checklist)
1. Ensure Docker Engine + Compose v2 installed.
2. Choose **N** and verify port ranges are free.
3. Run `./build_mq_qmgrs.sh N`.
4. Confirm `docker compose ps` shows **healthy**.
5. Set **Admin credentials**, if not already, and validate web/REST endpoints.
6. Capture logs and configuration (for audit) if needed.

---

## 14. Compliance & Conventions
- **Shell:** POSIX‑compatible Bash script, portable core utilities.
- **Containers:** OCI/Docker image practices; Compose format **3.8**.
- **Time/Date:** ISO 8601 for documentation timestamps.
- **Security:** OWASP-inspired hardening guidelines for admin services.
- **Versioning:** Suggest Semantic Versioning for script releases.

---

## 15. Change History
| Date (YYYY‑MM‑DD) | Version | Author | Change |
|---|---:|---|---|
| 2025‑04‑14 | 1.0.0 | Aztekmq, LLC | Initial release |
| 2025‑08‑19 | 1.0.1 | Rob Lee | Documentation prepared; security guidance & runbook added |

---

## 16. License
This documentation and script may be used under the terms you designate (e.g., MIT). Include a `LICENSE` file as appropriate for your project.
