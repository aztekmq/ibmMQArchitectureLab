# IBM MQ Business Applications & Architecture Trade‑offs (2025)

*Last updated: August 23, 2025*

## Executive Summary

IBM MQ remains a cornerstone for reliable, transactional messaging across industries where consistency, ordering, and operational resilience matter. This document delivers:

1. **Twenty common business applications** that use MQ with a short rationale for each.
2. **Twenty‑two architectural patterns** using MQ with clear pros/cons from both **business** and **software/operations** perspectives, plus pitfalls and fit‑criteria.

Use this as a decision aid when selecting a pattern for a new workload or when refactoring an existing system.

---

## Part I — 20 Typical Business Applications that Use IBM MQ

1. **Core Banking Transactions** — Debit/credit, ledger postings, balance updates; needs strict ordering and once‑only effects.
2. **Payment Processing** — Card authorization/clearing/settlement flows that must not be lost or duplicated.
3. **Trade Capture & Post‑Trade** — Front‑to‑back trade lifecycle (capture, allocation, confirmations, reporting).
4. **Insurance Policy Admin** — Quote/bind/issue/endorsement/cancel flows between portals, policy admin, billing, and data warehouses.
5. **Claims Intake & Adjudication** — FNOL intake from channels to adjudication engines with auditability.
6. **Loan Origination** — Multi‑party orchestration across bureaus, underwriting, e‑signature, and funding.
7. **Healthcare Eligibility & EDI** — HIPAA/EDI traffic (e.g., 270/271/837) where reliability and PHI protection are essential.
8. **Order Management (Retail/Wholesale)** — OMS ↔ WMS/ERP for order create/allocate/ship/invoice.
9. **Warehouse/Logistics** — WMS ↔ TMS updates for picking, packing, shipping, track‑and‑trace.
10. **Airline & Travel** — PNR/SSR updates, pricing/availability, loyalty events with strict sequencing.
11. **Telecom Provisioning** — Fulfillment flows across BSS/OSS (activate SIM, port numbers, service changes).
12. **Energy & Utilities** — Meter telemetry buffering, market bids, settlements, outage events.
13. **Public Sector Casework** — Case intake/route/escalate with immutable audit trails.
14. **Securities Reference Data** — Golden‑source distribution (instruments, counterparties, prices) to many consumers.
15. **eCommerce Checkout** — Async payment, tax/shipping, fulfillment orchestration behind web/API front ends.
16. **ERP Integration** — Cross‑module/event flows (FI/CO/MM/SD/PP/HR) and between ERP and satellite apps.
17. **IoT/Manufacturing** — Shop‑floor events, quality checks, and buffering for intermittently connected devices.
18. **Batch Offload/ETL** — Nightly movements of large volumes into analytics stores with flow control.
19. **Customer Communications** — Statement generation, notifications, print/mail vendors, with non‑repudiation.
20. **Risk & Compliance** — Surveillance events, limits/threshold breaches, SOX/PCI/GLBA/PSD2 audit needs.

---

## Part II — Architecture Patterns (Pros & Cons)

The following patterns are organized from foundational messaging styles to deployment topologies and hybrid integrations. For each pattern you’ll find: **What it is**, **Good for**, **Business Pros/Cons**, **Software/Ops Pros/Cons**, and **Pitfalls & Mitigations**.

### 1) Point‑to‑Point Work Queue (Competing Consumers)

**What**: Producers put messages on a queue; one of many consumers processes each message; scale by adding consumers.

**Good for**: Background processing, workload leveling, idempotent tasks.

**Business Pros**

* Predictable throughput via back‑pressure; smooths traffic spikes.
* Clear ownership of outcomes; easy to reason about SLAs.

**Business Cons**

* Coarse prioritization without additional queues.
* Longer tail latency during surges if capacity is capped.

**Software/Ops Pros**

* Simple model; aligns with MQ strengths (persistence, ordering per queue).
* Horizontal scale out; easy blue‑green of consumers.

**Software/Ops Cons**

* Message affinity can create hotspots (ordering constraints).
* Poison messages need DLQ/backout handling to avoid stalls.

**Pitfalls & Mitigations**

* *Pitfall*: Non‑idempotent handlers → duplicates cause data issues. *Mitigation*: Idempotency keys, transactional outbox, exactly‑once‑effects patterns.
* *Pitfall*: Oversized messages. *Mitigation*: Keep payloads small; stash large blobs in object storage and pass references.

---

### 2) Publish/Subscribe with Topics

**What**: Producers publish to a topic; multiple subscribers receive copies.

**Good for**: Fan‑out of events, reference data distribution, notifications.

**Business Pros**

* Enables many consumers (analytics, ops, downstream apps) without coupling.
* Faster time‑to‑value for new consumers; fewer change approvals.

**Business Cons**

* Harder cost attribution when many consumers exist.
* Need governance to prevent topic sprawl.

**Software/Ops Pros**

* Decoupling; consumers evolve independently.
* Retained ordering per subscription when designed carefully.

**Software/Ops Cons**

* Subscription management/filters add complexity.
* Troubleshooting duplicates/late joins requires discipline.

**Pitfalls & Mitigations**

* *Pitfall*: Overloaded “catch‑all” topics. *Mitigation*: Topic taxonomies, naming standards, ACLs.

---

### 3) Request/Reply with Correlation IDs

**What**: Client sends request message, waits (sync/async) for reply correlated by ID.

**Good for**: RPC‑like interactions where durability and back‑pressure are desired.

**Business Pros**

* Reliable service calls across unreliable networks.
* Back‑office systems can throttle without outages.

**Business Cons**

* Higher perceived latency versus direct synchronous HTTP.
* More complex error semantics to explain to stakeholders.

**Software/Ops Pros**

* Avoids head‑of‑line blocking typical of HTTP in outages.
* Works well with transactions (commit on both request and reply).

**Software/Ops Cons**

* Correlation logic and temp‑reply queues to manage.
* Timeouts/retries need careful tuning.

**Pitfalls & Mitigations**

* *Pitfall*: Blocking client threads. *Mitigation*: Async receive, circuit breakers, bounded wait policies.

---

### 4) Transactional Outbox (CDC or Dual‑Write Avoidance)

**What**: App writes business data and an “outbox” record in one local transaction; a relay publishes from the outbox to MQ.

**Good for**: Consistent propagation of domain events without 2PC.

**Business Pros**

* Reduces data inconsistencies across services.
* Clear audit trail of emitted events.

**Business Cons**

* Slightly more storage/ops for the outbox table.
* Additional moving part (relay) to operate.

**Software/Ops Pros**

* Avoids XA/2PC; scales with the database.
* Replay/recovery from outbox is straightforward.

**Software/Ops Cons**

* Requires schema/governance for outbox payloads.
* Event duplication if relay isn’t idempotent.

**Pitfalls & Mitigations**

* *Pitfall*: Outbox bloat. *Mitigation*: TTL purges, partitioning, relay SLAs.

---

### 5) Event‑Driven Microservices on MQ

**What**: Services communicate via events/commands over MQ queues and topics.

**Good for**: Loose coupling, independent deployability, resilience.

**Business Pros**

* Faster feature delivery with team autonomy.
* Resilient to partial failures; graceful degradation.

**Business Cons**

* Harder to cost/benefit trace per feature.
* Strong platform governance required.

**Software/Ops Pros**

* Natural back‑pressure; predictable SLOs.
* Works on‑prem, cloud, and hybrid consistently.

**Software/Ops Cons**

* Observability (tracing across async hops) is non‑trivial.
* Contract/version management overhead.

**Pitfalls & Mitigations**

* *Pitfall*: Hidden synchronous dependencies. *Mitigation*: Architecture fitness functions, async APIs first.

---

### 6) ESB/SOA Hub‑and‑Spoke with MQ

**What**: Central integration bus mediates between producers and consumers using MQ for transport.

**Good for**: Organizations with shared canonical models and centralized control.

**Business Pros**

* Reuse of canonical transformations; reduced duplication.
* Strong governance/audit.

**Business Cons**

* Possible bottleneck for change; longer lead times.
* Bus team becomes a critical path resource.

**Software/Ops Pros**

* Centralized monitoring and policy enforcement.
* Consistent NFRs applied across integrations.

**Software/Ops Cons**

* Coupling to the ESB platform; risk of “big ball of mud.”
* Scaling the hub can be complex.

**Pitfalls & Mitigations**

* *Pitfall*: Over‑orchestration. *Mitigation*: Prefer choreography for simple flows.

---

### 7) Saga/Choreography via MQ

**What**: Distributed transaction split into local transactions with compensating actions; steps coordinated by events.

**Good for**: Long‑running, cross‑service workflows (orders, loans).

**Business Pros**

* High availability—no global locks.
* Clear compensations → better customer recovery paths.

**Business Cons**

* Business stakeholders must accept eventual consistency.
* Compensation logic increases complexity.

**Software/Ops Pros**

* Avoids XA; scales horizontally.
* Natural fit with MQ reliability.

**Software/Ops Cons**

* Failure scenarios multiply; needs robust state modeling.
* Testing end‑to‑end compensations is effortful.

**Pitfalls & Mitigations**

* *Pitfall*: Orchestrator as single point of failure. *Mitigation*: Choreography or HA orchestrator.

---

### 8) Batch Offload / ETL over MQ

**What**: Large, periodic data flows (files/records) move via MQ to downstream systems.

**Good for**: End‑of‑day processing; analytics staging; mainframe offload.

**Business Pros**

* Predictable windows; fits governance cycles.
* Smooth migration path from legacy SFTP to reliable messaging.

**Business Cons**

* Not suitable for real‑time needs.
* Batch windows can constrain business hours.

**Software/Ops Pros**

* Back‑pressure avoids overload of receivers.
* Clear recovery/restart semantics.

**Software/Ops Cons**

* Large message handling needs tuning (segmentation).
* Operational runbooks must cover window misses.

**Pitfalls & Mitigations**

* *Pitfall*: DLQ floods after schema change. *Mitigation*: Versioned schemas, canary batches.

---

### 9) IBM MQ Managed File Transfer (MFT)

**What**: File transfer built on MQ for assured delivery, auditing, and automation.

**Good for**: Regulated file exchanges with non‑repudiation and traceability.

**Business Pros**

* End‑to‑end audit trails for compliance.
* Reduces partner onboarding friction.

**Business Cons**

* Licensed feature; additional cost.
* User training vs. familiar SFTP tools.

**Software/Ops Pros**

* Leverages MQ reliability/security; integrates with flows.
* Event hooks on completion; easy orchestration.

**Software/Ops Cons**

* Agent lifecycle management.
* Tuning for very large files required.

**Pitfalls & Mitigations**

* *Pitfall*: Treating MFT as a generic NAS sync. *Mitigation*: Use for transfers with clear endpoints and SLAs.

---

### 10) Classic MQ Cluster (Workload Balancing)

**What**: Multiple queue managers in a cluster provide location transparency and load distribution.

**Good for**: Horizontal scale and simplified routing between many QMs.

**Business Pros**

* Resilience to single QM failures.
* Easier growth without heavy reconfiguration.

**Business Cons**

* Requires operational maturity and standards.
* Hard to attribute incidents when topology is opaque.

**Software/Ops Pros**

* Built‑in workload balancing and discovery.
* Reduces static point‑to‑point definitions.

**Software/Ops Cons**

* Cluster administration (repositories, channels) complexity.
* Message ordering across multiple instances can be tricky.

**Pitfalls & Mitigations**

* *Pitfall*: Hidden asymmetric routes. *Mitigation*: Topology reviews, routing policies, naming conventions.

---

### 11) MQ Uniform Cluster (Client Rebalance)

**What**: Pool of identically configured QMs; clients auto‑rebalance connections for even load.

**Good for**: Elastic client farms, microservices, and containerized consumers.

**Business Pros**

* Better utilization → lower CapEx/OpEx.
* Fewer hotspots → steadier SLAs.

**Business Cons**

* Requires configuration discipline—“uniform” means uniform.
* Training/awareness for dev teams.

**Software/Ops Pros**

* Automatic connection balancing; graceful draining.
* Works well with Kubernetes and auto‑scaling.

**Software/Ops Cons**

* Requires compatible client levels and patterns.
* Diagnostics require good connection telemetry.

**Pitfalls & Mitigations**

* *Pitfall*: Non‑uniform queue names/policies. *Mitigation*: Automation to enforce config parity.

---

### 12) MQ Native HA (Raft‑based)

**What**: Three nodes replicate QM state; leader election provides HA without shared storage.

**Good for**: Container platforms and cloud where shared disks are undesirable.

**Business Pros**

* High availability without SAN complexity.
* Faster failover → tighter SLAs.

**Business Cons**

* Requires three suitable nodes per QM (capacity cost).
* Cross‑AZ traffic may incur cloud egress charges.

**Software/Ops Pros**

* No shared storage; simpler infra.
* Automates failover; integrates with modern schedulers.

**Software/Ops Cons**

* Quorum management and split‑brain avoidance.
* Log volume replication sensitivity to latency.

**Pitfalls & Mitigations**

* *Pitfall*: Placing nodes in distant zones. *Mitigation*: Keep latency low; cap round‑trip.

---

### 13) Multi‑Instance Queue Manager (Shared Storage)

**What**: Two nodes share disk; one active, one standby; failover via disk takeover.

**Good for**: Traditional data centers with reliable shared storage.

**Business Pros**

* Mature, well‑known pattern.
* Predictable fall‑back behavior.

**Business Cons**

* Shared storage as a single dependency.
* DR across sites can be complex.

**Software/Ops Pros**

* Low change for existing ops teams.
* Simple to reason about recovery.

**Software/Ops Cons**

* SAN/NAS performance and failover tuning required.
* Risk of storage‑level contention.

**Pitfalls & Mitigations**

* *Pitfall*: Split brain via storage misconfig. *Mitigation*: Strict fencing and cluster manager best practices.

---

### 14) RDQM High Availability / DR (Replicated Data Queue Manager)

**What**: Linux‑based synchronous HA or asynchronous DR replication of QM data across nodes.

**Good for**: VM/bare‑metal Linux estates seeking HA/DR without shared storage.

**Business Pros**

* Strong RPO/RTO options in one feature set.
* Avoids SAN cost/complexity.

**Business Cons**

* Platform constraints (Linux); not universal.
* Additional licensing/skills may apply.

**Software/Ops Pros**

* Integrated with MQ; consistent tooling.
* DR mode supports geo separation with async replication.

**Software/Ops Cons**

* Network latency sensitive; throughput vs. sync cost trade‑offs.
* Careful patch/version alignment across nodes.

**Pitfalls & Mitigations**

* *Pitfall*: Over‑subscribing network for sync HA. *Mitigation*: Capacity tests, QoS.

---

### 15) Active/Passive Multi‑Site DR (Storage/Backup‑Driven)

**What**: Primary site active; secondary kept warm via storage replication or log shipping; manual/automated cutover.

**Good for**: Compliance‑driven DR with clear runbooks.

**Business Pros**

* Meets regulatory DR mandates.
* Cost‑controllable standby footprint.

**Business Cons**

* Recovery drills required; business downtime during cutover.
* Risk of configuration drift between sites.

**Software/Ops Pros**

* Technology‑agnostic (fits many storage solutions).
* Clear, auditable procedures.

**Software/Ops Cons**

* Runbook complexity; DNS/routing updates.
* Message in‑flight reconciliation after failover.

**Pitfalls & Mitigations**

* *Pitfall*: Unreplicated local file paths/certs. *Mitigation*: Config as code; secret replication procedures.

---

### 16) Active/Active Across Regions (Asymmetric Routing)

**What**: Two or more active sites each handle a slice of traffic; avoid cross‑site ordering requirements.

**Good for**: Global scale with regional isolation.

**Business Pros**

* Low latency for local users.
* Resilience—one region failure only reduces capacity.

**Business Cons**

* Requires business partitioning by region/tenant.
* Complex incident communications.

**Software/Ops Pros**

* Reduces blast radius; independent changes by region.
* Easier scaling by adding regions.

**Software/Ops Cons**

* Data reconciliation across regions for global reporting.
* Complex topology/namespace management.

**Pitfalls & Mitigations**

* *Pitfall*: Cross‑region message affinity. *Mitigation*: Design for locality; idempotent consumers.

---

### 17) MQ ↔ Kafka Bridge (Event Mesh)

**What**: Bridge or connector moves events between MQ queues/topics and Kafka topics.

**Good for**: Mixing reliable command/event flows with analytics/stream processing.

**Business Pros**

* Leverage existing MQ investments while enabling streaming use cases.
* Reduces vendor lock‑in concerns.

**Business Cons**

* Two platforms to govern and cost.
* Data classification policies must align across both.

**Software/Ops Pros**

* Right‑tool for right‑job; durable commands on MQ, streams on Kafka.
* Incremental modernization path.

**Software/Ops Cons**

* Exactly‑once semantics differ; mapping required.
* Connector back‑pressure and DLQs on both sides to manage.

**Pitfalls & Mitigations**

* *Pitfall*: Schema drift between ecosystems. *Mitigation*: Central schema registry, versioning policy.

---

### 18) JMS Applications on MQ (Java EE/Spring)

**What**: Applications use JMS API with MQ as the JMS provider.

**Good for**: Java estates wanting standard APIs and container portability.

**Business Pros**

* Developer familiarity; lowers onboarding time.
* Portable across app servers.

**Business Cons**

* Platform bias (Java‑centric) vs. polyglot needs.
* Ties feature set to JMS abstractions.

**Software/Ops Pros**

* Mature patterns (MDBs, listeners, transactions).
* Rich client libraries, pooling, security options.

**Software/Ops Cons**

* Version mismatches between runtime and client libs.
* Tuning of listeners/session pools required.

**Pitfalls & Mitigations**

* *Pitfall*: Long‑running MDBs blocking threads. *Mitigation*: Concurrency controls, non‑blocking designs.

---

### 19) MQ Advanced Message Security (AMS)

**What**: Message‑level encryption/signing independent of transport.

**Good for**: PHI/PCI/PII where end‑to‑end confidentiality and integrity are required.

**Business Pros**

* Defense in depth beyond TLS; auditability.
* Enables partner integrations with strong trust boundaries.

**Business Cons**

* Key management overhead; staff training.
* Potential performance impact; capacity planning needed.

**Software/Ops Pros**

* Protects at rest and in transit.
* Granular policy per queue/topic.

**Software/Ops Cons**

* Certificate/keystore lifecycle complexity.
* Troubleshooting encrypted payloads is harder.

**Pitfalls & Mitigations**

* *Pitfall*: Shadow IT key stores. *Mitigation*: Central PKI, rotation policies, automated checks.

---

### 20) MQ Telemetry (MQTT) Gateway

**What**: MQTT devices publish/subscribe via MQ Telemetry to enterprise back‑ends.

**Good for**: IoT/edge scenarios needing reliable buffering and bridging to core systems.

**Business Pros**

* Extends enterprise reliability to edge devices.
* Offline tolerance for field operations.

**Business Cons**

* Device management at scale is non‑trivial.
* Radio/last‑mile constraints affect SLAs.

**Software/Ops Pros**

* MQTT fits constrained devices; MQ adds durability.
* Rules/transform to enterprise topics/queues.

**Software/Ops Cons**

* Protocol translation and security hardening per device class.
* Monitoring fleet health at scale.

**Pitfalls & Mitigations**

* *Pitfall*: Oversharing topics. *Mitigation*: Device‑scoped namespaces, ACLs, rate limits.

---

### 21) API Gateway Front‑End with MQ Back‑Ends

**What**: External/API traffic via gateway; backend services consume/produce via MQ.

**Good for**: Protecting core systems while offering APIs to partners/apps.

**Business Pros**

* Monetizable APIs without exposing fragile cores.
* Throttling/SLA tiers per consumer.

**Business Cons**

* Perceived latency vs. synchronous backends.
* Product management overhead for API lifecycle.

**Software/Ops Pros**

* Gateway policies (auth, quota) + MQ back‑pressure.
* Decouples API contracts from system internals.

**Software/Ops Cons**

* Correlation handling between HTTP and MQ.
* End‑to‑end tracing across boundary.

**Pitfalls & Mitigations**

* *Pitfall*: Blocked API threads on slow backends. *Mitigation*: Async patterns, callbacks/webhooks.

---

### 22) Mainframe ↔ Distributed Bridging via MQ

**What**: MQ on z/OS (CICS/IMS/Batch) exchanges with distributed QMs.

**Good for**: Modernizing interfaces while preserving mainframe strengths.

**Business Pros**

* Low‑risk modernization; reuse core assets.
* Strong audit/compliance alignment.

**Business Cons**

* Cross‑platform skills and governance required.
* Chargeback/MLC optics for added traffic.

**Software/Ops Pros**

* Mature adapters; predictable performance.
* SMF/operational telemetry on z/OS.

**Software/Ops Cons**

* Code page/EBCDIC vs UTF‑8 handling.
* Channel security and certificate operations across platforms.

**Pitfalls & Mitigations**

* *Pitfall*: Large messages over high‑latency links. *Mitigation*: Compression, segmentation, payload minimization.

---

## Quick Selection Guide

Below, patterns are named explicitly so you don’t need to cross‑reference numbers. The trailing **(#)** is the pattern number from this document for anyone who wants to jump to details.

| Business Goal                     | Recommended Patterns                                                                                                                                                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Smooth bursts / backlog control   | **Work Queue / Competing Consumers** (#1), **Classic MQ Cluster** (#10), **Uniform Cluster** (#11)                                                                                                                           |
| Add new consumers quickly         | **Publish/Subscribe with Topics** (#2), **API Gateway Front‑End with MQ Back‑Ends** (#21), **MQ ↔ Kafka Bridge** (#17)                                                                                                       |
| Strict reliability and audit      | **Work Queue** (#1), **Request/Reply with Correlation IDs** (#3), **Transactional Outbox** (#4), **Managed File Transfer (MFT)** (#9), **Advanced Message Security (AMS)** (#19), **Mainframe ↔ Distributed Bridging** (#22) |
| Modernize mainframe safely        | **Mainframe ↔ Distributed Bridging** (#22), **Transactional Outbox** (#4), **Event‑Driven Microservices on MQ** (#5)                                                                                                         |
| Global scale / regional isolation | **Active/Active Across Regions** (#16), **Uniform Cluster** (#11), **MQ Native HA (Raft)** (#12)                                                                                                                             |
| Real‑time IoT buffering           | **MQ Telemetry (MQTT) Gateway** (#20)                                                                                                                                                                                        |
| HA without SAN                    | **MQ Native HA (Raft)** (#12), **RDQM (HA/DR)** (#14)                                                                                                                                                                        |
| DR compliance                     | **RDQM in DR mode** (#14), **Active/Passive Multi‑Site DR** (#15)                                                                                                                                                            |

---

## Cross‑Cutting Considerations

* **Idempotency & Exactly‑Once Effects**: MQ provides *at‑least‑once delivery*; design consumers to produce exactly‑once **effects**.
* **Poison Message Strategy**: Backout thresholds, DLQ handlers, and replay tools are must‑haves.
* **Schema & Versioning**: Use explicit schemas; additive changes; contract tests; schema registry where appropriate.
* **Security**: TLS on channels, AMS for message‑level, strong ACLs, cert rotation runbooks, and secrets management.
* **Observability**: Correlation IDs, end‑to‑end tracing, queue depth/age SLOs, consumer lag, and dead‑letter metrics.
* **Capacity & Performance**: Keep messages small; avoid chatty patterns; batch logically; monitor log I/O; understand persistence/write‑ahead logging impacts.
* **Cost & Licensing**: Model per‑QM/CPU licensing; plan for MFT/AMS/HA features; weigh cloud egress for cross‑AZ replication.

---

## Business Cases vs. IBM MQ **Lab** Architectures (Containers)

> **A)** Standalone QMs · **B)** MFT Domain · **C)** Multi‑Instance (Active/Standby) + VIP · **D)** Native‑HA (Raft) + VIP.
> These are **education/demo** patterns, not production‑hardened. Suitability ratings reflect **lab fit** and what they teach, with brief pros/cons.

**Legend**: ✔ Good fit · △ Conditional / partial fit · ✖ Poor fit

### At‑a‑Glance Suitability Matrix

|  # | Business Application                         | A) Standalone | B) MFT | C) MI + VIP | D) Native‑HA + VIP |
| -: | -------------------------------------------- | :-----------: | :----: | :---------: | :----------------: |
|  1 | Core Banking Transactions                    |       △       |    ✖   |      ✔      |          ✔         |
|  2 | Payment Processing                           |       △       |    △   |      ✔      |          ✔         |
|  3 | Trade Capture & Post‑Trade                   |       △       |    △   |      ✔      |          ✔         |
|  4 | Insurance Policy Admin                       |       △       |    △   |      ✔      |          ✔         |
|  5 | Claims Intake & Adjudication                 |       △       |    △   |      ✔      |          ✔         |
|  6 | Loan Origination                             |       △       |    △   |      ✔      |          ✔         |
|  7 | Healthcare Eligibility & EDI                 |       △       |    △   |      ✔      |          ✔         |
|  8 | Order Management (Retail/Wholesale)          |       △       |    △   |      ✔      |          ✔         |
|  9 | Warehouse/Logistics                          |       △       |    △   |      ✔      |          ✔         |
| 10 | Airline & Travel (PNR/SSR)                   |       △       |    ✖   |      ✔      |          ✔         |
| 11 | Telecom Provisioning (BSS/OSS)               |       △       |    △   |      ✔      |          ✔         |
| 12 | Energy & Utilities (metering/events)         |       △       |    △   |      △      |          ✔         |
| 13 | Public Sector Casework                       |       △       |    △   |      ✔      |          ✔         |
| 14 | Securities Reference Data                    |       △       |    ✖   |      ✔      |          ✔         |
| 15 | eCommerce Checkout Orchestration             |       △       |    ✖   |      ✔      |          ✔         |
| 16 | ERP Integration                              |       △       |    △   |      ✔      |          ✔         |
| 17 | IoT/Manufacturing (shop‑floor)               |       △       |    ✖   |      △      |          △         |
| 18 | Batch Offload / ETL                          |       ✔       |    ✔   |      ✔      |          ✔         |
| 19 | Customer Communications (statements/notices) |       △       |    ✔   |      ✔      |          ✔         |
| 20 | Risk & Compliance Events                     |       △       |    △   |      ✔      |          ✔         |

> **Notes**: Many of these production‑class use cases ultimately need enterprise security (TLS/AMS), governance, and platform SRE runbooks not present in the labs. The matrix indicates what each lab best **demonstrates** when teaching or prototyping.

### Pros & Cons by Business Case and Architecture

Below, each business case lists short pros/cons for **A–D**. This format is **GitHub‑friendly** (headings + bullets) so it renders cleanly.

**Legend:** ✔ Good fit · △ Conditional/partial fit · ✖ Poor fit

---

#### 1) Core Banking Transactions

* **A) Standalone** △

  * **Pros:** Simple dev/test for message flows.
  * **Cons:** No HA/DR; not suitable for real SLAs.
* **B) MFT** ✖

  * **Pros:** —
  * **Cons:** File‑centric; doesn’t model online transactional messaging.
* **C) MI + VIP** ✔

  * **Pros:** Demonstrates failover of a single QM identity; good for resilience drills.
  * **Cons:** Shared storage complexity; not cloud‑native.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA without SAN; quicker failover.
  * **Cons:** Needs 3 nodes; replication overhead.

#### 2) Payment Processing

* **A) Standalone** △

  * **Pros:** Useful for prototyping auth/settlement flows.
  * **Cons:** No availability guarantees.
* **B) MFT** △

  * **Pros:** Good for batch clearing/settlement files.
  * **Cons:** Not for real‑time authorizations.
* **C) MI + VIP** ✔

  * **Pros:** Active/standby models gateway resilience.
  * **Cons:** Storage locking prerequisites.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft HA for online flows.
  * **Cons:** Requires careful latency budgeting.

#### 3) Trade Capture & Post‑Trade

* **A) Standalone** △

  * **Pros:** Quick sandbox for event schemas.
  * **Cons:** No resilience.
* **B) MFT** △

  * **Pros:** End‑of‑day file drops.
  * **Cons:** Not event‑rich; limited to file patterns.
* **C) MI + VIP** ✔

  * **Pros:** Sustains order/event queues through failover.
  * **Cons:** Shared storage risk.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Teaches quorum HA; resilient during node loss.
  * **Cons:** 3‑node footprint.

#### 4) Insurance Policy Administration

* **A) Standalone** △

  * **Pros:** Validate flows between policy/billing.
  * **Cons:** Single‑QM outages.
* **B) MFT** △

  * **Pros:** Document pack/file exchanges.
  * **Cons:** Not for interactive workflows.
* **C) MI + VIP** ✔

  * **Pros:** Steady back‑office throughput with HA.
  * **Cons:** SAN/NFS dependency.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA without SAN.
  * **Cons:** Replica‑lag considerations.

#### 5) Claims Intake & Adjudication

* **A) Standalone** △

  * **Pros:** Prototype intake/queueing.
  * **Cons:** No HA.
* **B) MFT** △

  * **Pros:** Ingest scanned docs/exports.
  * **Cons:** Not for real‑time adjudication steps.
* **C) MI + VIP** ✔

  * **Pros:** Keeps intake live during node failures.
  * **Cons:** Storage‑lock sensitivity.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Active/Replica continuity.
  * **Cons:** Requires 3 containers.

#### 6) Loan Origination

* **A) Standalone** △

  * **Pros:** Model async bureau calls.
  * **Cons:** Single point of failure.
* **B) MFT** △

  * **Pros:** Batch document/file handoffs.
  * **Cons:** Doesn’t cover online steps.
* **C) MI + VIP** ✔

  * **Pros:** Good failover story.
  * **Cons:** Shared‑disk ops overhead.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft‑based HA.
  * **Cons:** Network latency must be low.

#### 7) Healthcare Eligibility & EDI

* **A) Standalone** △

  * **Pros:** Test X12 message envelopes.
  * **Cons:** Lacks HIPAA‑grade controls.
* **B) MFT** △

  * **Pros:** Suits EDI batch file transfers.
  * **Cons:** Not for real‑time eligibility checks.
* **C) MI + VIP** ✔

  * **Pros:** HA for clearinghouse bridges.
  * **Cons:** Storage design adds ops risk.
* **D) Native‑HA + VIP** ✔

  * **Pros:** No SAN; strong availability.
  * **Cons:** Key/cert & PHI hardening not shown in lab.

#### 8) Order Management (Retail/Wholesale)

* **A) Standalone** △

  * **Pros:** Easy to demo OMS↔WMS events.
  * **Cons:** No uptime guarantees.
* **B) MFT** △

  * **Pros:** Bulk pick/pack files.
  * **Cons:** Limited near‑real‑time orchestration.
* **C) MI + VIP** ✔

  * **Pros:** Handles spikes with HA.
  * **Cons:** Stateful storage.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft HA for orchestration.
  * **Cons:** 3‑node overhead.

#### 9) Warehouse & Logistics

* **A) Standalone** △

  * **Pros:** Prototype TMS/WMS queues.
  * **Cons:** Single‑host risk.
* **B) MFT** △

  * **Pros:** Manifest/label batch transfers.
  * **Cons:** Not for event bursts.
* **C) MI + VIP** ✔

  * **Pros:** HA during shift peaks.
  * **Cons:** NFS/SAN dependence.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Resilient without SAN.
  * **Cons:** Replica‑sync costs.

#### 10) Airline & Travel (PNR/SSR)

* **A) Standalone** △

  * **Pros:** Mock PNR/SSR events.
  * **Cons:** No HA.
* **B) MFT** ✖

  * **Pros:** —
  * **Cons:** Use messaging, not file transfer, for live inventory.
* **C) MI + VIP** ✔

  * **Pros:** HA for reservation queues.
  * **Cons:** Shared‑storage caveats.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft HA for live ops.
  * **Cons:** Needs three nodes.

#### 11) Telecom Provisioning (BSS/OSS)

* **A) Standalone** △

  * **Pros:** Demo order→activation flows.
  * **Cons:** No fault tolerance.
* **B) MFT** △

  * **Pros:** Nightly config‑push files.
  * **Cons:** Not for service‑activation events.
* **C) MI + VIP** ✔

  * **Pros:** Upgrades without downtime (failover).
  * **Cons:** Storage complexity.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Node‑failure tolerance.
  * **Cons:** Network/latency tuning.

#### 12) Energy & Utilities (metering/events)

* **A) Standalone** △

  * **Pros:** Prototype outage events.
  * **Cons:** Not sized for telemetry scale.
* **B) MFT** △

  * **Pros:** Meter‑read batch files.
  * **Cons:** No real‑time streaming.
* **C) MI + VIP** △

  * **Pros:** HA for control messages.
  * **Cons:** Shared storage; still lacks telemetry gateway.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA for control/market events.
  * **Cons:** For device telemetry, prefer MQTT gateway (not in this lab).

#### 13) Public Sector Casework

* **A) Standalone** △

  * **Pros:** Simple case event queues.
  * **Cons:** Single QM.
* **B) MFT** △

  * **Pros:** Document/file routing.
  * **Cons:** Not interactive.
* **C) MI + VIP** ✔

  * **Pros:** HA for intake/backlogs.
  * **Cons:** Storage‑lock risks.
* **D) Native‑HA + VIP** ✔

  * **Pros:** No‑SAN HA.
  * **Cons:** Three containers to operate.

#### 14) Securities Reference Data (distribution)

* **A) Standalone** △

  * **Pros:** Prototype pub/sub fan‑out.
  * **Cons:** No HA.
* **B) MFT** ✖

  * **Pros:** —
  * **Cons:** Distribution is event‑driven, not file‑based.
* **C) MI + VIP** ✔

  * **Pros:** Keeps distribution live during failover.
  * **Cons:** Storage complexity.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA without SAN.
  * **Cons:** Needs uniform topic config.

#### 15) eCommerce Checkout Orchestration

* **A) Standalone** △

  * **Pros:** Demo async payment/fulfillment.
  * **Cons:** No availability guarantees.
* **B) MFT** ✖

  * **Pros:** —
  * **Cons:** Not suitable for real‑time checkout.
* **C) MI + VIP** ✔

  * **Pros:** HA for order orchestration.
  * **Cons:** Shared storage.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft HA.
  * **Cons:** Replication overhead under spikes.

#### 16) ERP Integration

* **A) Standalone** △

  * **Pros:** Good sandbox for ERP adapters.
  * **Cons:** No HA.
* **B) MFT** △

  * **Pros:** Bulk master‑data file moves.
  * **Cons:** Not for event APIs.
* **C) MI + VIP** ✔

  * **Pros:** HA for ERP queues.
  * **Cons:** NFS/SAN requirements.
* **D) Native‑HA + VIP** ✔

  * **Pros:** SAN‑less HA.
  * **Cons:** Multi‑node ops learning curve.

#### 17) IoT / Manufacturing (shop‑floor)

* **A) Standalone** △

  * **Pros:** Prototype event buffering.
  * **Cons:** Lacks MQTT gateway.
* **B) MFT** ✖

  * **Pros:** —
  * **Cons:** File transfer doesn’t fit device telemetry.
* **C) MI + VIP** △

  * **Pros:** HA for control messages.
  * **Cons:** Still missing MQTT.
* **D) Native‑HA + VIP** △

  * **Pros:** HA core; can bridge to MQTT externally.
  * **Cons:** Needs separate Telemetry gateway.

#### 18) Batch Offload / ETL

* **A) Standalone** ✔

  * **Pros:** Easy to demo batch queues.
  * **Cons:** No HA if host fails.
* **B) MFT** ✔

  * **Pros:** Native fit for file transfers.
  * **Cons:** Not for real‑time feeds.
* **C) MI + VIP** ✔

  * **Pros:** HA through batch windows.
  * **Cons:** Storage dependency.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA without SAN.
  * **Cons:** Replica overhead even for batch.

#### 19) Customer Communications (statements/notices)

* **A) Standalone** △

  * **Pros:** Prototype message→print vendor.
  * **Cons:** No HA.
* **B) MFT** ✔

  * **Pros:** Strong for print/file vendors with audit.
  * **Cons:** Requires MQ Advanced image.
* **C) MI + VIP** ✔

  * **Pros:** HA during statement runs.
  * **Cons:** Storage setup.
* **D) Native‑HA + VIP** ✔

  * **Pros:** Raft HA.
  * **Cons:** Operational overhead for a batchy workload.

#### 20) Risk & Compliance Events

* **A) Standalone** △

  * **Pros:** Prototype event capture.
  * **Cons:** No AMS/TLS or HA shown.
* **B) MFT** △

  * **Pros:** Batch evidence/exports.
  * **Cons:** Not for streaming alerts.
* **C) MI + VIP** ✔

  * **Pros:** HA for surveillance/event queues.
  * **Cons:** Shared storage.
* **D) Native‑HA + VIP** ✔

  * **Pros:** HA without SAN.
  * **Cons:** Needs security hardening beyond lab.

---

## Appendix — Checklist for New MQ Integrations

1. Define business SLAs (latency, throughput, availability, RPO/RTO).
2. Choose delivery semantics (at‑least‑once) and consumer idempotency strategy.
3. Decide on message size limits and externalize large blobs.
4. Establish topic/queue naming standards and ACLs.
5. Pick HA/DR model (12/13/14/15) with tested runbooks.
6. Decide on observability (correlation IDs, trace, queue depth SLOs).
7. DLQ/backout/retry policies and playbooks.
8. Versioning and schema registry policy.
9. Security choices (TLS, AMS, secrets, cert rotation cadence).
10. Performance test with production‑like payloads and failure injection.
