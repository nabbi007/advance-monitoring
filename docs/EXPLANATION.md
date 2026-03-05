# Project Explanation — Advanced Monitoring & Observability

This document explains the **Advanced Monitoring & Observability** project from the ground up. It starts with **why the architecture is shaped the way it is**, walks through each infrastructure layer, and only then dives into the application code and instrumentation. Every decision is explained in context so a reader can follow the reasoning from infrastructure to code.

---

## Table of Contents

1. [What This Project Does](#1-what-this-project-does)
2. [Architecture Overview](#2-architecture-overview)
   - [Two-Instance Design](#two-instance-design)
   - [Network Topology](#network-topology)
   - [Data Flows](#data-flows)
3. [AWS Infrastructure — Terraform](#3-aws-infrastructure--terraform)
   - [Module Structure](#module-structure)
   - [VPC Module](#vpc-module)
   - [EC2-Instance Module](#ec2-instance-module)
   - [App Module](#app-module)
   - [Observability Module](#observability-module)
   - [ECR Module](#ecr-module)
   - [IAM, SSH Keys, and State](#iam-ssh-keys-and-state)
4. [Configuration Management — Ansible](#4-configuration-management--ansible)
   - [Inventory and Playbooks](#inventory-and-playbooks)
   - [Roles Breakdown](#roles-breakdown)
5. [CI/CD Pipeline — GitHub Actions](#5-cicd-pipeline--github-actions)
   - [CI Workflow](#ci-workflow)
   - [CD Workflow](#cd-workflow)
6. [The Monitoring Stack](#6-the-monitoring-stack)
   - [Prometheus — Metrics Collection](#prometheus--metrics-collection)
   - [Grafana — Dashboards](#grafana--dashboards)
   - [Jaeger — Distributed Tracing](#jaeger--distributed-tracing)
   - [Three Pillars Working Together](#three-pillars-working-together)
7. [Application Code](#7-application-code)
   - [Backend — REST API and Redis](#backend--rest-api-and-redis)
   - [Frontend — Proxy and SPA](#frontend--proxy-and-spa)
   - [OpenTelemetry Instrumentation](#opentelemetry-instrumentation)
   - [Prometheus Metrics Instrumentation](#prometheus-metrics-instrumentation)
   - [Structured Logging with Trace Correlation](#structured-logging-with-trace-correlation)
   - [Docker Configuration](#docker-configuration)
8. [Alert Rules](#8-alert-rules)
9. [Load Testing and Validation](#9-load-testing-and-validation)
10. [Incident Investigation — End-to-End Example](#10-incident-investigation--end-to-end-example)

---

## 1. What This Project Does

This project deploys a **Quick Poll** voting web application on AWS and wraps it with a complete observability stack covering the three pillars of observability: **Metrics**, **Traces**, and **Logs**.

A user visits the application, creates polls with multiple-choice options, casts votes, and views live results. Behind the scenes, every HTTP request generates a distributed trace (collected by **Jaeger**), every response is counted and timed as a metric (scraped by **Prometheus**, visualised in **Grafana**), and every log line is enriched with trace context so that a single `trace_id` links a metric anomaly to the exact request trace and its associated log entries.

The entire lifecycle — infrastructure provisioning, application deployment, monitoring configuration, and health verification — is automated through **Terraform**, **Ansible**, and **GitHub Actions**.

---

## 2. Architecture Overview

> Open [`docs/aws-architecture.drawio`](aws-architecture.drawio) in [diagrams.net](https://app.diagrams.net) or the VS Code Draw.io extension for the full visual diagram with native AWS icons, connection labels, and a legend.

### Two-Instance Design

The infrastructure runs on **two EC2 instances** in AWS region `eu-west-1`:

| Instance | Hostname | Type | Purpose |
|----------|----------|------|---------|
| **app-01** | Application server | t3.medium | Runs the voting app (frontend, backend, Redis) in Docker Compose, plus Node Exporter and Redis Exporter as native systemd services |
| **obs-01** | Observability server | t3.medium | Runs Prometheus and Grafana as native systemd services, plus Jaeger (all-in-one) in Docker Compose, plus Node Exporter as a systemd service |

Separating the application from the monitoring stack is deliberate — it mirrors real-world production environments where monitoring infrastructure is isolated so it remains operational even when the application has issues. If the app instance's CPU spikes to 100%, Prometheus and Grafana on the observability instance continue to function and alert you.

### Network Topology

```
AWS Cloud
└── Region: eu-west-1
    └── VPC: 10.0.0.0/16
        └── Public Subnet: 10.0.1.0/24
            ├── Internet Gateway (for inbound/outbound traffic)
            │
            ├── Security Group: app-sg
            │   └── EC2: app-01
            │       ├── Docker: frontend (:3000), backend (:3001), redis (:6379)
            │       ├── systemd: node_exporter (:9100)
            │       └── systemd: redis_exporter (:9121)
            │
            └── Security Group: obs-sg
                └── EC2: obs-01
                    ├── systemd: prometheus (:9090)
                    ├── systemd: grafana (:3000)
                    ├── systemd: node_exporter (:9100)
                    └── Docker: jaeger (:16686, :4317, :4318)
```

Both instances sit in the same public subnet. Each has its own security group with tightly scoped ingress rules. **Cross-security-group rules** allow:

- **App → Obs**: OTLP trace export on ports 4317 (gRPC) and 4318 (HTTP)
- **Obs → App**: Prometheus metric scraping on ports 3000, 3001, 9100, and 9121

### Data Flows

There are four distinct data flows in the architecture:

**1. User Traffic (solid black arrows)**
Users send HTTP requests to the frontend on port 3000. The frontend serves the single-page application and proxies all `/api/*` requests to the backend on port 3001. The backend reads from and writes to Redis on port 6379. Users can also access the Grafana dashboard (obs-01:3000) and Jaeger UI (obs-01:16686) directly.

**2. Trace Export (teal arrows)**
Both the frontend and backend contain an OpenTelemetry SDK that automatically instruments Express HTTP handling, outgoing HTTP calls, and Redis commands. The SDK batches completed spans and exports them over OTLP/HTTP to Jaeger on obs-01 port 4318. The SDK auto-appends `/v1/traces` to the base endpoint.

**3. Metric Scraping (purple dashed arrows)**
Prometheus on obs-01 scrapes six targets every 15 seconds: the backend's `/metrics` endpoint, the frontend's `/metrics` endpoint, Node Exporter on both instances, the Redis Exporter on the app instance, and Prometheus itself. Each scrape pulls the current counter and histogram values.

**4. CI/CD Operations (orange dashed arrows)**
GitHub Actions runs `terraform apply` against AWS (creating the VPC, EC2 instances, security groups, ECR repos), pushes Docker images to ECR, and then runs `ansible-playbook` over SSH to configure both instances.

---

## 3. AWS Infrastructure — Terraform

All infrastructure is defined as code in the `terraform/` directory. Terraform v1.5+ is required, and the AWS provider version is pinned to `~> 5.0`.

### Module Structure

```
terraform/
├── main.tf              # Root module — wires all sub-modules together
├── variables.tf         # 8 input variables (region, CIDRs, instance types, AMI, etc.)
├── outputs.tf           # 14 outputs (IPs, ECR URLs, SSH key, convenience URLs)
├── provider.tf          # AWS + TLS providers, S3 backend configuration
└── modules/
    ├── vpc/             # Network layer
    ├── ec2-instance/    # Reusable single-instance resource
    ├── app/             # App instance + security group
    ├── observability/   # Obs instance + security group + cross-SG rules
    └── ecr/             # Container image repositories
```

The root `main.tf` orchestrates everything. It calls the VPC module first (since all other modules depend on the VPC ID and subnet ID), then the App and Observability modules (which each call the EC2-Instance sub-module internally), and finally the ECR module.

### VPC Module

Creates:
- **VPC** with CIDR `10.0.0.0/16`
- **Public Subnet** with CIDR `10.0.1.0/24` in availability zone `eu-west-1a`
- **Internet Gateway** attached to the VPC
- **Route Table** with a `0.0.0.0/0` route through the IGW, associated with the public subnet

Every instance launched in this subnet automatically receives a public IP address, which is necessary for SSH access from GitHub Actions and for users to reach the application.

### EC2-Instance Module

A reusable module that both the App and Observability modules call. It creates a single EC2 instance with:

- **AMI**: Ubuntu 22.04 LTS (Jammy) — `ami-0d75513e7706cf2d9` in eu-west-1
- **Root Volume**: 30 GB, encrypted, gp3 type
- **IMDSv2 Enforcement**: `http_tokens = "required"` — blocks the legacy IMDSv1 metadata endpoint, which is a security best practice
- **IAM Instance Profile**: Attached for ECR pull access, CloudWatch, and SSM
- **Tags**: Standardised with project name and managed-by-terraform labels

### App Module

Calls the EC2-Instance module and creates the **app-sg** security group:

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | Allowed SSH CIDR | SSH access for deployment |
| 3000 | TCP | 0.0.0.0/0 | Frontend HTTP |
| 3001 | TCP | 0.0.0.0/0 | Backend HTTP |
| 9100 | TCP | obs-sg | Node Exporter (Prometheus scrape) |
| 9121 | TCP | obs-sg | Redis Exporter (Prometheus scrape) |

Ports 9100 and 9121 only allow traffic from the observability security group — the exporters are not publicly exposed.

### Observability Module

Calls the EC2-Instance module and creates the **obs-sg** security group plus **cross-SG rules**:

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | Allowed SSH CIDR | SSH access for deployment |
| 3000 | TCP | 0.0.0.0/0 | Grafana UI |
| 9090 | TCP | 0.0.0.0/0 | Prometheus UI |
| 9100 | TCP | obs-sg (self) | Node Exporter (self-scrape) |
| 16686 | TCP | 0.0.0.0/0 | Jaeger UI |
| 4317 | TCP | app-sg | Jaeger OTLP gRPC (trace ingestion) |
| 4318 | TCP | app-sg | Jaeger OTLP HTTP (trace ingestion) |

The cross-SG rules are the mechanism that ties the two instances together — the app can send traces to obs, and obs can scrape metrics from the app, but no other unexpected traffic is allowed.

### ECR Module

Creates two Elastic Container Registry repositories:

- `advance-monitoring-voting-backend`
- `advance-monitoring-voting-frontend`

Both have **scan-on-push enabled** (images are scanned for vulnerabilities on every push) and a **lifecycle policy** that retains only the 10 most recent images, preventing unbounded storage costs.

### IAM, SSH Keys, and State

**IAM Role** — A single IAM role (`advance-monitoring-ec2-role`) is created with three AWS managed policies attached:
- `AmazonEC2ContainerRegistryReadOnly` — Allows instances to pull Docker images from ECR
- `CloudWatchAgentServerPolicy` — CloudWatch integration
- `AmazonSSMManagedInstanceCore` — SSM Session Manager access as a fallback if SSH is unavailable

**SSH Key** — Instead of requiring a pre-existing key pair, Terraform uses the `tls_private_key` resource to generate an RSA 4096-bit key pair at apply time. The public key is registered as an `aws_key_pair`, and the private key is exposed as a sensitive output. The CD pipeline extracts this key for Ansible to use during deployment.

**State Management** — Terraform state is stored remotely in an S3 bucket (`advance-monitoring-tfstate`) with encryption enabled. This ensures consistent state between local development and CI/CD runs.

---

## 4. Configuration Management — Ansible

Once Terraform creates the infrastructure, Ansible configures everything that runs on the instances — Docker, exporters, Prometheus, Grafana, and Jaeger.

### Inventory and Playbooks

The Ansible inventory is **dynamically generated** from Terraform outputs. The CD pipeline (or `deploy.sh` script) writes an inventory file that looks like:

```ini
[app]
<app_public_ip> observability_private_ip=<obs_private_ip>

[observability]
<obs_public_ip> app_private_ip=<app_private_ip>
```

The key variables here are:
- `observability_private_ip` on the app group — tells Docker Compose where to send OTLP traces (i.e. which IP Jaeger is running on)
- `app_private_ip` on the observability group — tells Prometheus which IP to scrape metrics from

Three playbooks orchestrate the deployment:

| Playbook | Targets | Roles |
|----------|---------|-------|
| `site.yml` | All hosts | Imports `app.yml` and `observability.yml` |
| `app.yml` | app group | common → app_docker → node_exporter → redis_exporter |
| `observability.yml` | observability group | common → node_exporter → prometheus → grafana → jaeger |

### Roles Breakdown

**common** — Waits for cloud-init to finish (important on fresh EC2 instances), installs base packages (curl, wget, jq, htop, net-tools, Docker), configures chrony for NTP, sets UTC timezone, and tunes kernel parameters:
- `net.core.somaxconn=65535` — increases the listen backlog for high-connection scenarios
- `vm.overcommit_memory=1` — required by Redis for background saves

**app_docker** — Authenticates with ECR, templates the Docker Compose file (injecting the correct ECR image tags, environment variables including `OTEL_EXPORTER_OTLP_ENDPOINT`), pulls images, and starts the stack. Health checks verify all three containers (frontend, backend, redis) are running and healthy before the role completes.

**node_exporter** — Downloads Node Exporter v1.8.1 binary, creates a dedicated `node_exporter` system user, installs a systemd unit file, and starts the service. Deployed on both instances. The task is idempotent — it checks if the binary already exists at the correct version before downloading.

**redis_exporter** — Downloads Redis Exporter v1.62.0, creates a dedicated system user, installs a systemd unit pointing at `redis://localhost:6379`. Deployed only on the app instance.

**prometheus** — Downloads Prometheus v2.51.2, creates directories and a system user, templates `prometheus.yml` (with all six scrape targets using the app's private IP) and `alert_rules.yml`, validates the rules with `promtool check rules`, and starts the systemd service with `--web.enable-lifecycle` (allowing hot-reload via `POST /-/reload`). Data retention is set to 15 days.

**grafana** — Adds the Grafana APT repository, installs Grafana 10.4.2, templates `grafana.ini` (unified alerting, admin credentials), provisions two datasources (Prometheus with `uid: prometheus`, Jaeger with `uid: jaeger` and `tracesToLogsV2` + `nodeGraph` enabled), and deploys a 37-panel dashboard JSON. Includes diagnostic tasks that capture `journalctl` output if Grafana fails to start — critical for debugging in CI/CD where you cannot SSH in interactively.

**jaeger** — Templates a Docker Compose file for Jaeger all-in-one v1.57, pulls the image, and starts the container with in-memory storage (50,000 max traces limit), OTLP collection enabled, and health checks via `wget --spider`.

---

## 5. CI/CD Pipeline — GitHub Actions

### CI Workflow

**File:** `.github/workflows/ci.yml`
**Trigger:** Pull requests to `main`/`develop`, and pushes to any non-main branch.

Runs five parallel validation jobs:

| Job | What It Validates |
|-----|------------------|
| **lint** | `npm ci --omit=dev` + `npm audit` for both backend and frontend |
| **build-images** | Docker Buildx builds for both images (build-only, no push) |
| **terraform-validate** | `terraform fmt -check -recursive`, `terraform init` (local backend), `terraform validate` |
| **validate-prometheus** | Downloads `promtool`, runs `promtool check rules alert_rules.yml` |
| **ansible-lint** | Runs `ansible-lint` and `ansible-playbook --syntax-check` on `site.yml` |

These gates run fast (2-3 minutes) and catch formatting issues, dependency vulnerabilities, invalid Terraform config, Prometheus rule syntax errors, and Ansible playbook issues before any code reaches `main`.

### CD Workflow

**File:** `.github/workflows/deploy.yml`
**Trigger:** Pushes to `main`, or manual dispatch.

Runs four **sequential** jobs (each depends on the previous):

**Job 1: setup**
- Initialises Terraform with the S3 backend
- Runs `terraform plan` and `terraform apply -auto-approve`
- Extracts 14 outputs (public/private IPs for both instances, ECR URLs, SSH key, region)
- Passes them to subsequent jobs via GitHub Actions outputs

**Job 2: build-and-push**
- Authenticates to ECR using the region from Job 1
- Builds both Docker images via Buildx
- Tags each with `$GITHUB_SHA` (immutable, traceable to the exact commit) and `latest`
- Pushes all tags to ECR

**Job 3: ansible-deploy**
- Re-reads Terraform state to get current IPs
- Generates the Ansible inventory dynamically
- Writes the SSH private key (from Terraform output) to disk with `chmod 600`
- Installs Ansible
- Runs `ansible-playbook site.yml` to configure both instances

**Job 4: smoke-test**
- Waits for services to stabilise
- Verifies eight health endpoints are responding with HTTP 200:

```
Frontend (:3000/health)       Backend (:3001/health)
Node Exporter app (:9100)     Node Exporter obs (:9100)
Redis Exporter (:9121)        Prometheus (:9090/-/healthy)
Grafana (:3000/api/health)    Jaeger (:16686)
```

The pipeline uses temporary AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) stored as GitHub Secrets.

---

## 6. The Monitoring Stack

### Prometheus — Metrics Collection

Prometheus sits on the observability instance and acts as the central metrics store. It **pulls** (scrapes) metrics from six targets every 15 seconds:

| Job Name | Target | What It Collects |
|----------|--------|-----------------|
| `prometheus` | localhost:9090 | Self-monitoring (scrape durations, rule evaluation times) |
| `voting-backend` | app:3001/metrics | RED metrics, vote counters, Redis operation durations, active connections, Node.js process metrics |
| `voting-frontend` | app:3000/metrics | Frontend RED metrics, Node.js process metrics |
| `redis` | app:9121/metrics | Redis memory usage, connected clients, commands/sec, keys, evictions, hit rate |
| `node-exporter-app` | app:9100/metrics | CPU, memory, disk, network, filesystem for the app instance |
| `node-exporter-observability` | localhost:9100/metrics | Same host metrics for the observability instance |

Prometheus also evaluates **8 alert rules** every 15 seconds (see [Section 8](#8-alert-rules)).

### Grafana — Dashboards

Grafana is provisioned with two datasources and a single comprehensive dashboard containing **37 panels** across **6 sections**:

**Section 1 — Service Health**: Six stat panels showing UP/DOWN status for Backend, Frontend, Redis, Prometheus, Node Exporter (app), and Node Exporter (obs). These use `up{job="..."}` queries and turn green (UP) or red (DOWN).

**Section 2 — Backend RED Metrics**: Request rate per route, error ratio with threshold lines at 1% and 5%, latency percentiles (P50/P95/P99) with a 300ms threshold, requests by method/route, and active connections.

**Section 3 — Redis Performance**: Memory usage vs max, connected clients, commands/sec, operation duration P95, keys and evictions, cache hit rate.

**Section 4 — System Saturation**: CPU usage, memory usage, disk usage, network I/O, load averages, memory breakdown, disk I/O throughput — for both instances.

**Section 5 — App Metrics**: Votes per option (rate), cumulative vote totals, frontend request rate and latency, Node.js heap memory, event loop lag.

**Section 6 — Distributed Tracing**: Two Jaeger trace search panels for `voting-backend` and `voting-frontend` services, using the `traces` visualisation type.

The two datasources are configured with explicit UIDs (`uid: prometheus` and `uid: jaeger`) so that every panel reference resolves correctly. The Jaeger datasource has `tracesToLogsV2` configured to link traces to correlated metrics, and `nodeGraph` enabled for the service dependency graph view.

### Jaeger — Distributed Tracing

Jaeger runs as the `all-in-one` image (v1.57) — a single container that includes the OTLP collector, span storage, query service, and web UI. It accepts traces on:

| Port | Protocol | Purpose |
|------|----------|---------|
| 4317 | gRPC | OTLP trace ingestion |
| 4318 | HTTP | OTLP trace ingestion (used by the app) |
| 16686 | HTTP | Query API and web UI |

Traces are stored **in memory** with a maximum of 50,000 traces before eviction. This is sufficient for a development/demo environment and avoids the need for an external database like Elasticsearch or Cassandra.

### Three Pillars Working Together

The true value of this stack is how the three pillars correlate:

```
Metric Alert (Prometheus)
    ↓ click time range in Grafana
Trace Search (Jaeger via Grafana panel)
    ↓ click a specific trace
Trace Detail (Jaeger waterfall)
    ↓ copy trace_id
Log Search (docker logs | jq 'select(.trace_id == "...")')
    ↓ full request context in structured JSON
Root Cause
```

A Prometheus alert tells you *something is wrong*. Jaeger traces tell you *which request is failing and where*. Structured logs enriched with `trace_id` tell you *exactly why*. This is the metric → trace → log correlation loop that the entire project is designed to demonstrate.

---

## 7. Application Code

With the architecture and infrastructure covered, here is how the application code is structured and instrumented.

### Backend — REST API and Redis

**Location:** `app/backend/src/server.js`

The backend is a Node.js/Express REST API with 11 endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/polls` | GET | List all polls (with vote counts) |
| `/api/polls` | POST | Create a new poll |
| `/api/polls/:id` | GET | Get a single poll with results |
| `/api/polls/:id/vote` | POST | Cast a vote |
| `/api/polls/:id/close` | PATCH | Close a poll to further voting |
| `/api/polls/:id/reset` | POST | Reset votes on a poll |
| `/api/polls/:id` | DELETE | Delete a poll |
| `/health` | GET | Health check (tests Redis connectivity) |
| `/metrics` | GET | Prometheus metrics endpoint |
| `/api/simulate/error` | GET | Returns a 500 (for load testing) |
| `/api/simulate/latency` | GET | Adds 0.5–2.5s delay (for load testing) |

**Key implementation details:**

- **Atomic Voting**: Votes are cast using a **Redis Lua script** (`EVAL`). The Lua script checks poll existence, verifies the poll is not closed, validates the option ID, increments the vote count, and updates the poll — all in a single atomic operation. This prevents race conditions when multiple users vote simultaneously.

- **In-Memory Cache**: Poll data is cached in a `Map` with a 15-second TTL. The cache is invalidated on any write (vote, reset, delete, close). This reduces Redis reads on frequently accessed polls while keeping data reasonably fresh.

- **Redis Client**: Uses `ioredis` with retry strategy (exponential backoff up to 5 seconds) and a max of 3 retries per request. The client emits `connect` and `error` events that are logged via Winston.

- **Health Check**: The `/health` endpoint pings Redis and returns `{ status: "healthy", redis: "connected", uptime, cache_ttl_ms }` on success, or a 503 with `{ status: "unhealthy" }` on failure. This is used by Docker's HEALTHCHECK and the CI/CD smoke test.

### Frontend — Proxy and SPA

**Location:** `app/frontend/src/server.js`

The frontend is a separate Express process that:

1. Serves the static single-page application from `src/public/index.html`
2. Proxies all `/api/*` requests to the backend using `axios`
3. Exposes its own `/metrics` endpoint for Prometheus
4. Has its own `/health` endpoint that also checks backend connectivity

This separation mirrors real-world architectures where frontend and backend are independently deployable services. In a production system, the frontend would typically be served by a CDN or a dedicated web server, but for observability demonstration purposes, having it as a separate instrumented Express service creates an additional hop in the distributed trace.

Every proxy route wraps the `axios` call in a try/catch. On failure, it extracts the status code and error payload from the backend's response (if available) or returns a `502 Backend unavailable` error. All failures are logged with `logger.error()`.

### OpenTelemetry Instrumentation

**Location:** `app/backend/src/tracing.js` and `app/frontend/src/tracing.js`

Both services use `@opentelemetry/sdk-node` to set up distributed tracing. The tracing file is loaded **before** the application code via Node's `--require` flag:

```
CMD ["node", "--require", "./src/tracing.js", "src/server.js"]
```

This is critical — the OpenTelemetry SDK must initialise before Express, HTTP, and ioredis are loaded so it can **monkey-patch** them for automatic instrumentation.

**SDK Configuration:**

```javascript
const traceExporter = new OTLPTraceExporter();
// Reads OTEL_EXPORTER_OTLP_ENDPOINT from environment
// Automatically appends /v1/traces to the base URL

const sdk = new NodeSDK({
  resource: new Resource({
    "service.name": "voting-backend",   // Identifies this service in Jaeger
    "service.version": "1.0.0",
    "deployment.environment": "production",
  }),
  spanProcessor: new BatchSpanProcessor(traceExporter),
  instrumentations: [
    getNodeAutoInstrumentations({
      "@opentelemetry/instrumentation-fs": { enabled: false },  // Too noisy
      "@opentelemetry/instrumentation-express": { enabled: true },
      "@opentelemetry/instrumentation-http": { enabled: true },
      "@opentelemetry/instrumentation-ioredis": { enabled: true },
    }),
  ],
});
```

**What gets auto-instrumented:**
- **Express**: Every route handler becomes a span with attributes like `http.method`, `http.route`, `http.status_code`
- **HTTP (outgoing)**: When the frontend calls `axios.get(BACKEND_URL/...)`, a span is created for the outgoing HTTP request with trace context propagated via W3C Trace Context headers
- **ioredis**: Every Redis command (GET, SET, EVAL, MGET, DEL, etc.) becomes a child span showing the exact Redis operation and its duration

**Why the exporter has no constructor arguments:**
The `OTLPTraceExporter` is instantiated with no explicit URL. It reads `OTEL_EXPORTER_OTLP_ENDPOINT` from the environment (set by Docker Compose, templated by Ansible), and the SDK **automatically appends** `/v1/traces` to the base URL. Passing a `url` directly to the constructor bypasses this auto-append behaviour, which was the root cause of a tracing bug that was fixed during development.

### Prometheus Metrics Instrumentation

**Location:** `app/backend/src/metrics.js`

The backend uses the `prom-client` library to expose RED metrics and custom application metrics:

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `http_request_duration_seconds` | Histogram | method, route, status_code | Request latency distribution (buckets: 10ms to 5s) |
| `http_requests_total` | Counter | method, route, status_code | Total request count (the "Rate" in RED) |
| `http_errors_total` | Counter | method, route, status_code | Total error count — incremented for any 4xx or 5xx (the "Errors" in RED) |
| `votes_total` | Counter | option | Tracks which poll option was voted for |
| `active_connections` | Gauge | — | Currently open HTTP connections |
| `redis_operation_duration_seconds` | Histogram | operation, status | Redis operation latency (buckets: 1ms to 1s) |

An Express middleware function (`metricsMiddleware`) runs on every request. It records the start time using `process.hrtime.bigint()`, increments `active_connections`, and listens for the `res.finish` event to calculate the duration and record all labels. This provides the data foundation for the RED dashboards in Grafana.

Default Node.js process metrics (heap size, GC duration, event loop lag, active handles) are also collected with the prefix `voting_backend_`.

### Structured Logging with Trace Correlation

**Location:** `app/backend/src/logger.js` and `app/frontend/src/logger.js`

Both services use **Winston** with a custom format that injects OpenTelemetry trace context into every log line:

```javascript
const span = api.trace.getActiveSpan();
const spanContext = span ? span.spanContext() : {};
return JSON.stringify({
  timestamp,
  level,
  message,
  trace_id: spanContext.traceId || "N/A",
  span_id: spanContext.spanId || "N/A",
  service: "voting-backend",
  ...meta,
});
```

This produces structured JSON like:

```json
{
  "timestamp": "2026-03-05T10:30:00.123Z",
  "level": "info",
  "message": "Vote recorded",
  "trace_id": "abc123def456...",
  "span_id": "789xyz...",
  "service": "voting-backend",
  "pollId": "poll_abc",
  "optionId": "opt_2",
  "totalVotes": 42
}
```

The `trace_id` in the log matches the trace ID in Jaeger. This is what enables the final leg of the metric → trace → log correlation: given a trace ID from Jaeger, you can grep the application logs to find every log entry associated with that specific request.

### Docker Configuration

**Location:** `app/backend/Dockerfile` and `app/frontend/Dockerfile`

Both services use **multi-stage builds** with `node:18-alpine`:

```dockerfile
FROM node:18-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --production

FROM node:18-alpine
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./
COPY src/ ./src/
USER appuser
EXPOSE 3001
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "const http=require('http'); ..."
CMD ["node", "--require", "./src/tracing.js", "src/server.js"]
```

Key details:
- **Non-root user**: The `appuser` user is created and used to run the process — a security best practice
- **No curl/wget needed**: The HEALTHCHECK uses a Node.js one-liner with the `http` module, since Alpine doesn't include curl
- **`--require` flag**: Ensures `tracing.js` runs before `server.js`, which is mandatory for OpenTelemetry auto-instrumentation to work
- **30-second start period**: Gives the container time to boot and connect to Redis before health checks begin failing

---

## 8. Alert Rules

Eight Prometheus alert rules are defined in `monitoring/prometheus/alert_rules.yml` and deployed by the Prometheus Ansible role. All rules are validated at deploy time with `promtool check rules`.

| Alert | Expression | Duration | Severity |
|-------|-----------|----------|----------|
| **HighErrorRate** | Error ratio > 5% | 5 min | critical |
| **HighLatencyP95** | P95 latency > 300ms | 10 min | warning |
| **BackendDown** | `up{job="voting-backend"} == 0` | 1 min | critical |
| **FrontendDown** | `up{job="voting-frontend"} == 0` | 1 min | critical |
| **RedisDown** | `up{job="redis"} == 0` | 1 min | critical |
| **RedisHighMemory** | Redis memory > 80% of max | 5 min | warning |
| **HighCPUUsage** | CPU > 80% | 5 min | warning |
| **HighMemoryUsage** | Memory > 85% | 5 min | warning |

Every alert annotation includes a `runbook` field that describes how to investigate using Jaeger traces and logs. The `for` duration prevents transient spikes from triggering false alarms — for example, `HighErrorRate` must persist for 5 continuous minutes before it fires.

---

## 9. Load Testing and Validation

### Load Test Script

**Location:** `scripts/load-test.sh`

```bash
./scripts/load-test.sh <APP_HOST> [DURATION_SECONDS]
```

Runs four phases to generate a realistic traffic pattern and intentionally trigger alerts:

| Phase | % of Duration | Purpose |
|-------|--------------|---------|
| **Warm-up** | 30% | Normal traffic — creates polls, casts votes |
| **Error Burst** | 20% | Hits `/api/simulate/error` to spike the error rate and fire `HighErrorRate` |
| **Latency Burst** | 20% | Hits `/api/simulate/latency` to inject delays and fire `HighLatencyP95` |
| **Sustained Mixed** | 30% | Combines normal traffic, errors, and latency simultaneously |

### Validation Script

**Location:** `scripts/validate.sh`

```bash
./scripts/validate.sh <APP_HOST> <OBS_HOST>
```

An end-to-end observability validation that checks:
1. Application health endpoints (frontend + backend)
2. Metrics endpoints (verifies specific metric names like `http_requests_total` are present)
3. Monitoring stack health (Prometheus, Grafana, Jaeger all reachable)
4. Prometheus targets (all six targets in UP state)
5. Trace pipeline (casts a vote, then queries Jaeger's API for traces from `voting-backend`)
6. Alert rule loading (verifies all eight rules are present in Prometheus)

---

## 10. Incident Investigation — End-to-End Example

This is a concrete walkthrough demonstrating how the observability stack is used to investigate a production incident.

### Scenario: The `HighErrorRate` Alert Fires

**Step 1 — Alert triggers.** After running the load test's error burst phase, Prometheus evaluates the error rate expression every 15 seconds. When `sum(rate(http_errors_total[5m])) / sum(rate(http_requests_total[5m])) > 0.05` holds true for 5 continuous minutes, the `HighErrorRate` alert transitions to FIRING state.

**Step 2 — Identify the symptom in Grafana.** Open the dashboard. The **Error Rate** panel in the Backend RED Metrics section shows a sharp spike above the 5% threshold line. The time range pinpoints when the issue started.

**Step 3 — Find the failing trace in Jaeger.** In the dashboard's Distributed Tracing section, the Jaeger panel shows recent traces. Traces with error spans are marked with red icons. Click one to see the full waterfall — you see a span for `POST /api/simulate/error` with `http.status_code: 500`.

**Step 4 — Correlate with logs.** Copy the `trace_id` from the Jaeger trace. SSH into the app instance and search backend logs:

```bash
docker logs voting-app-backend-1 2>&1 | jq 'select(.trace_id == "abc123...")'
```

The matching log entry shows `"level": "error"`, `"message": "Simulated 500 error for testing"`, along with the timestamp, service name, and span ID.

**Step 5 — Root cause identified.** The trace and log together confirm: the `/api/simulate/error` endpoint was deliberately called during load testing. In a real incident, the same path would reveal actual problems — unhandled exceptions, database timeouts, or malformed requests — instead of simulated errors.

The same investigation flow applies to `HighLatencyP95` alerts: Grafana shows the P95 line crossing 300ms, Jaeger shows spans with long durations, and the trace waterfall reveals whether the slowness is in the Express handler, a Redis command, or network transit.

---

*This documentation accompanies the draw.io architecture diagram at [`docs/aws-architecture.drawio`](aws-architecture.drawio) and the comprehensive README at the repository root.*
