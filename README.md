# ibmMQArchitecture
---

# A) Multiple Standalone IBM MQ Queue Managers

### Purpose

Spin up **N independent queue managers** for workshops, demos, and API exploration (Admin Web + REST), each with its own persistent volume.

### Scope

* One Docker host and network.
* Each QM runs its own listener (1414) and optional Admin Web (9443) / REST Admin (9449).
* No HA/DR or cross-QM clustering implied.

### Caveats (container-based)

* Ephemeral networking; no service discovery beyond Docker DNS.
* Local volumes ≠ enterprise storage (I/O latency & durability vary).
* Default CHLAUTH/channel settings in labs are permissive; **not secure**.
* No TLS, SIEM integration, or formal capacity/SLOs.

```mermaid
flowchart LR
  subgraph Host["Docker Host (single)"]
    direction LR
    subgraph Net["Docker Network"]
      direction TB
      QM1["qm1 : QM1\n1414 | 9443 | 9449"] --- V1[("Vol: ./data/QM1")]
      QM2["qm2 : QM2\n1415 | 9444 | 9450"] --- V2[("Vol: ./data/QM2")]
      QMn["qmN : QMN\n…"] --- Vn[("Vol: ./data/QMN")]
    end
  end

  Clients((Clients / Tools))
  Admin[[Admin UI / REST]]

  Clients -->|MQI/JMS\nSVRCONN| QM1
  Clients -->|MQI/JMS\nSVRCONN| QM2
  Clients -->|...| QMn

  Admin -->|HTTPS 9443 / 9449| QM1
  Admin -->|HTTPS 9443 / 9449| QM2
  Admin -->|...| QMn
```

---

# B) IBM MQ Managed File Transfer (MFT) Lab

### Purpose

Demonstrate a canonical **MFT domain** with **Coordination**, **Command**, and **Agents** (one agent co-located with a QM; one **agent-only** container using MQ client).

### Scope

* `QMCOORD` hosts **Coordination** repository.
* `QMCMD` hosts **Command** services.
* `QMAGENT` hosts **Agent Server** and local agent `AGENT_LCL`.
* `mftagent` runs **`AGENT_REM`** (no QM; connects to `QMAGENT` via SVRCONN).

### Caveats (container-based)

* Requires an **MQ Advanced** image (MFT CLI under `/opt/mqm/mqft/bin`).
* Lab uses **DEV.APP.SVRCONN** and relaxed CHLAUTH; **do not** reuse in prod.
* No TLS or enterprise auth; file paths are container filesystems.
* Single network / single host — no DR, no hardened storage.

```mermaid
flowchart LR
  subgraph Net["Docker Network"]
    direction TB
    QMCOORD["qmcoord : QMCOORD\nMFT Coordination"]:::qm
    QMCMD["qmcmd : QMCMD\nMFT Command"]:::qm
    QMAGENT["qmagent : QMAGENT\nAgent Server + AGENT_LCL"]:::qm
    AGENTREM["mftagent : AGENT_REM\n(no QM; MQ client)"]:::agent
  end

  style QMCOORD fill:#f3f7ff,stroke:#6b8cff
  style QMCMD fill:#f3f7ff,stroke:#6b8cff
  style QMAGENT fill:#f3f7ff,stroke:#6b8cff
  classDef qm stroke:#6b8cff,fill:#eef3ff,color:#222,stroke-width:1.2px
  classDef agent stroke:#7c4dff,fill:#f7f2ff,color:#222,stroke-width:1.2px

  AGENT_LCL[[AGENT_LCL]]:::agent --> QMAGENT
  AGENT_REM[[AGENT_REM]]:::agent --> AGENTREM

  %% Agent registration & status with Coordination
  AGENT_LCL -.register/status.-> QMCOORD
  AGENT_REM -.register/status.-> QMCOORD

  %% Commands and monitoring flow
  QMCMD -->|fteCreateTransfer\nfteListMonitors| QMCOORD
  QMCMD -->|agent commands| AGENT_LCL
  QMCMD -->|agent commands| AGENT_REM

  %% MQ client path from agent-only container to QMAGENT
  AGENTREM -->|SVRCONN\nqmagent:1414| QMAGENT

  %% Data movement (conceptual)
  AGENT_REM ===>|file copy| AGENT_LCL
```

---

# C) Multi-Instance Queue Manager (MI) — Active/Standby + VIP

### Purpose

Illustrate **MIQM** behavior: one **ACTIVE** instance and one **STANDBY** reading the **same shared storage** (POSIX-locking NFS/EFS). Optional **VIP** (HAProxy) points clients to the active node.

### Scope

* Single QM identity (e.g., `QM1`) across two containers.
* Both mount **the same** `/mnt/mqm` share; only ACTIVE opens the listener.
* HAProxy offers a **stable TCP endpoint** that follows the active.

### Caveats (container-based)

* **Shared storage must support locking** (NFSv4). Misconfigured NFS can cause failover issues or data risk.
* Standby shouldn’t run a listener; health is inferred via TCP checks.
* No RDQM (kernel modules) in standard containers.
* One host / bridge network; not a full production HA design (no multi-AZ, no VIP failover IP/VRRP).

```mermaid
flowchart LR
  Client((Clients)) -- MQI/JMS --> VIP[[HAProxy VIP\n:14150]]

  subgraph Containers
    direction LR
    A["qm1a : QM1 (ACTIVE)\nListener 1414"]:::active
    B["qm1b : QM1 (STANDBY)\nNo listener"]:::standby
  end

  subgraph Storage["Shared Storage (NFSv4/EFS)\nPOSIX byte-range locks required"]
    VOL[("/mnt/mqm : QM1 data + logs")]
  end

  VIP -->|tcp| A
  VIP -.failover.-> B

  A --- VOL
  B --- VOL

  classDef active stroke:#28a745,fill:#eaffea,stroke-width:1.4px,color:#1e4620
  classDef standby stroke:#c0a000,fill:#fffbe6,stroke-width:1.2px,color:#4d3b00
```

---

## General Notes — **Education/Concept Only (Not Production)**

* These designs are **teaching aids**: they show how components relate and how flows work, but they **intentionally omit** enterprise-grade controls (PKI/TLS, CHLAUTH hardening, LDAP/OIDC, secrets management, SIEM, backup, SRE runbooks).
* **Container storage** choices in demos (local bind paths, simple NFS) do **not** reflect production durability, latency, or compliance requirements.
* **Networking** here is the default Docker bridge; no east-west firewalls, no VRRP/VIP floating IPs, no multi-AZ placement.
* **Operational behavior** (failover promotion, channel auth rules, agent file paths) is simplified to make the flows visible and repeatable in a lab.

If you’d like, I can bundle these Mermaid diagrams and notes into a single `README.md` (or an **architect’s one-pager PDF**) with a quick-start “Try it” section for each pattern.
