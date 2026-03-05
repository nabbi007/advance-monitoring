# Advanced Monitoring and Observability — Voting Application

## Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Application Code and Instrumentation](#application-code-and-instrumentation)
4. [Infrastructure as Code — Terraform](#infrastructure-as-code--terraform)
5. [Configuration Management — Ansible](#configuration-management--ansible)
6. [CI/CD Pipeline — GitHub Actions](#cicd-pipeline--github-actions)
7. [Prometheus — Metrics Collection and Alerting](#prometheus--metrics-collection-and-alerting)
8. [Grafana — Dashboards and Visualisation](#grafana--dashboards-and-visualisation)
9. [Jaeger — Distributed Tracing](#jaeger--distributed-tracing)
10. [Structured Logging with Trace Correlation](#structured-logging-with-trace-correlation)
11. [Load Testing and Chaos Simulation](#load-testing-and-chaos-simulation)
12. [Incident Investigation Walkthrough](#incident-investigation-walkthrough)
13. [Repository Structure](#repository-structure)
14. [Deployment Guide](#deployment-guide)
15. [Screenshots and Evidence](#screenshots-and-evidence)

---

## Project Overview

This project implements a full-stack observability solution for a custom-built **Voting Application** deployed on AWS. The entire stack — infrastructure provisioning, application deployment, monitoring configuration, and CI/CD — is automated end-to-end.

The application is a **Quick Poll** web app where users can create polls, cast votes, view live results, and manage poll lifecycle (close, reset, delete). It uses a Node.js/Express backend with Redis for persistence and a Node.js/Express frontend that serves a single-page application and proxies API requests to the backend.

The observability stack covers **all three pillars**:

| Pillar | Tool | Purpose |
|--------|------|---------|
| **Metrics** | Prometheus + Grafana | RED metrics (Rate, Errors, Duration), system saturation, Redis health, custom vote counters |
| **Traces** | Jaeger (via OpenTelemetry) | Distributed request tracing across frontend → backend → Redis, with automatic context propagation |
| **Logs** | Winston (structured JSON) | Every log line carries `trace_id` and `span_id` for direct correlation with Jaeger traces |

The infrastructure runs on two AWS EC2 instances in `eu-west-1`:

- **app-01** — Runs the voting application (backend + frontend + Redis) as Docker containers, plus node_exporter and redis_exporter as native systemd services.
- **obs-01** — Runs Prometheus and Grafana as native systemd services, plus Jaeger all-in-one in Docker.

---

## Architecture

> **Full architecture diagram:** open [`docs/aws-architecture.drawio`](docs/aws-architecture.drawio) in [diagrams.net](https://app.diagrams.net) or the VS Code Draw.io extension for the complete AWS architecture with native icons, data-flow arrows, and legend.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS VPC (10.0.0.0/16)                          │
│                         Public Subnet (10.0.1.0/24)                         │
│                                                                             │
│  ┌──────────────────────────┐      ┌──────────────────────────────────────┐ │
│  │   app-01 (t3.medium)     │      │   obs-01 (t3.medium)                │ │
│  │                          │      │                                      │ │
│  │  Docker Compose:         │      │  Systemd:                            │ │
│  │   ├─ frontend  (:3000)   │      │   ├─ Prometheus 2.51.2  (:9090)     │ │
│  │   ├─ backend   (:3001)   │      │   ├─ Grafana 10.4.2     (:3000)     │ │
│  │   └─ redis     (:6379)   │      │   └─ node_exporter      (:9100)     │ │
│  │                          │      │                                      │ │
│  │  Systemd:                │      │  Docker Compose:                     │ │
│  │   ├─ node_exporter (:9100)│     │   └─ Jaeger 1.57        (:16686)    │ │
│  │   └─ redis_exporter(:9121)│     │       OTLP HTTP          (:4318)    │ │
│  │                          │      │                                      │ │
│  └──────────┬───────────────┘      └──────────────────┬───────────────────┘ │
│             │                                          │                     │
│             │  ── OTLP traces (HTTP :4318) ──────────►│                     │
│             │  ◄── Prometheus scrape (:3000,3001,      │                     │
│             │       9100,9121) ──────────────────────  │                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **User** sends HTTP requests to the frontend on port 3000.
2. **Frontend** proxies `/api/*` to the backend on port 3001; both emit OpenTelemetry traces to Jaeger on obs-01 via OTLP/HTTP (port 4318).
3. **Backend** performs Redis operations (votes, poll CRUD) — ioredis calls are auto-instrumented and appear as child spans in traces.
4. **Prometheus** on obs-01 scrapes all six targets every 15 seconds.
5. **Grafana** on obs-01 queries Prometheus for metrics and Jaeger for traces, presenting everything in a unified dashboard.
6. **Winston loggers** on both services inject `trace_id` and `span_id` from the active OpenTelemetry span into every structured JSON log line.

---

## Application Code and Instrumentation

### Backend (`app/backend/`)

The backend is a Node.js/Express REST API with 11 endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/polls` | GET | List all polls with vote counts |
| `/api/polls` | POST | Create a new poll |
| `/api/polls/:id` | GET | Get poll details with results |
| `/api/polls/:id/vote` | POST | Cast a vote (atomic via Lua script) |
| `/api/polls/:id/close` | PATCH | Close a poll to further voting |
| `/api/polls/:id/reset` | POST | Reset all votes on a poll |
| `/api/polls/:id` | DELETE | Delete a poll and all vote data |
| `/health` | GET | Health check (tests Redis connectivity) |
| `/metrics` | GET | Prometheus metrics endpoint |
| `/api/simulate/error` | POST | Simulates a 500 error (for load testing) |
| `/api/simulate/latency` | POST | Simulates 2–5 second latency (for load testing) |

**Key implementation details:**

- **Atomic voting** — Uses a Redis Lua script to check poll existence, verify the poll is open, validate the option index, and increment the vote count in a single atomic transaction. This prevents race conditions under concurrent load.
- **In-memory cache** — Poll data is cached locally with a 15-second TTL to reduce Redis reads. The cache is invalidated on writes (votes, resets, deletes).
- **Tracing** — The `tracing.js` file is loaded before `server.js` via Node's `--require` flag in the Dockerfile. This ensures the OpenTelemetry SDK initialises before any application code runs, allowing it to monkey-patch Express, HTTP, and ioredis for automatic trace instrumentation.

### Frontend (`app/frontend/`)

The frontend serves a static single-page application (`public/index.html`) and proxies all `/api/*` requests to the backend. It is a separate Express process because this mirrors real-world architectures where frontend and backend run independently. The frontend has its own tracing and metrics:

- `frontend_http_request_duration_seconds` — Request duration histogram.
- `frontend_http_requests_total` — Request count by method, route, status code.
- Default Node.js process metrics (heap, GC, event loop) prefixed with `voting_frontend_`.

### Metrics Instrumentation (`app/backend/src/metrics.js`)

I used the `prom-client` library to expose RED metrics and custom application metrics:

```
http_request_duration_seconds  — Histogram (buckets: 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s)
http_requests_total            — Counter  (labels: method, route, status_code)
http_errors_total              — Counter  (incremented for any 4xx or 5xx response)
votes_total                    — Counter  (label: option — tracks which poll option was voted for)
active_connections             — Gauge    (currently active HTTP connections)
redis_operation_duration_seconds — Histogram (buckets: 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 1s)
```

Every Express request passes through middleware that records the method, route, status code, and duration automatically. This provides the foundation for the RED (Rate, Errors, Duration) dashboards in Grafana.

### OpenTelemetry Setup (`app/backend/src/tracing.js`, `app/frontend/src/tracing.js`)

Both services use `@opentelemetry/sdk-node` with the following configuration:

- **Exporter**: `@opentelemetry/exporter-trace-otlp-http` — sends traces to Jaeger's OTLP HTTP endpoint on port 4318. The SDK automatically appends `/v1/traces` to the base URL.
- **Span Processor**: `BatchSpanProcessor` — batches spans before export for efficiency.
- **Auto-instrumentation**: `@opentelemetry/auto-instrumentations-node` — automatically instruments Express (creates spans for each route handler), HTTP (creates spans for outgoing requests), and ioredis (creates child spans for every Redis command). File system instrumentation is disabled to reduce noise.
- **Resource Attributes**: `service.name` (e.g., `voting-backend`), `service.version` (`1.0.0`), `deployment.environment` (from `NODE_ENV`).

The `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable is set in the Docker Compose template to point at the observability instance's private IP. This is populated dynamically by Ansible using Terraform output values.

### Docker Configuration

Both services use multi-stage Docker builds:

```dockerfile
FROM node:18-alpine
# ... install dependencies in a clean layer ...
USER appuser
CMD ["node", "--require", "./src/tracing.js", "src/server.js"]
```

The `--require ./src/tracing.js` flag ensures OpenTelemetry initialises before any application code, which is critical for the auto-instrumentation to patch Express/HTTP/ioredis correctly.

Health checks use a lightweight Node.js one-liner instead of curl or wget (which are not available in Alpine):

```dockerfile
HEALTHCHECK CMD node -e "require('http').get('http://localhost:3001/health', (r) => { process.exit(r.statusCode === 200 ? 0 : 1) })"
```

---

## Infrastructure as Code — Terraform

### Module Structure

The infrastructure is organised into five reusable Terraform modules:

```
terraform/
├── modules/
│   ├── vpc/              # VPC, subnet, IGW, route table
│   ├── app/              # App instance security group and EC2
│   ├── observability/    # Monitoring instance SG, EC2, cross-SG rules
│   ├── ec2-instance/     # Reusable EC2 resource (used by app and observability)
│   └── ecr/              # ECR repositories with lifecycle policies
├── main.tf               # Root module: wires everything together
├── variables.tf          # 8 input variables
├── outputs.tf            # 14 outputs
└── provider.tf           # AWS + TLS providers, S3 backend
```

### What Each Module Does

**VPC Module** — Creates a VPC (`10.0.0.0/16`), a single public subnet (`10.0.1.0/24`), an internet gateway, and a route table. All instances get public IPs for direct SSH and HTTP access.

**EC2-Instance Module** — A reusable module that both `app` and `observability` call. It provisions an EC2 instance with: a 30 GB encrypted gp3 root volume, IMDSv2 enforcement (`http_tokens = "required"`), an IAM instance profile (for ECR read access), a userdata script, and standard tagging.

**App Module** — Defines the security group for the app instance. Inbound: SSH (22), HTTP frontend (3000), HTTP backend (3001), node_exporter (9100), redis_exporter (9121). Creates the EC2 instance via the ec2-instance sub-module.

**Observability Module** — Defines the security group for the monitoring instance plus the cross-security-group rules. The observability SG gets: SSH (22), Grafana (3000), Prometheus (9090), Jaeger UI (16686), Jaeger OTLP HTTP (4318), Jaeger OTLP gRPC (4317), node_exporter (9100). Additional ingress rules allow traffic from the app's SG to the observability SG (for OTLP) and from the observability SG to the app's SG (for Prometheus scraping).

**ECR Module** — Creates two ECR repositories (`advance-monitoring-voting-backend` and `advance-monitoring-voting-frontend`) with scan-on-push enabled and a lifecycle policy that retains the 10 most recent images.

### SSH Key Auto-Generation

Rather than requiring a pre-existing SSH key, Terraform uses the `tls_private_key` resource to generate an RSA 4096-bit key pair. The public key is registered as an `aws_key_pair`, and the private key is available as a sensitive output. The CI/CD pipeline extracts this key from Terraform output for Ansible to use.

### State Management

Terraform state is stored remotely in S3:

```hcl
backend "s3" {
  bucket = "advance-monitoring-tfstate"
  key    = "dev/terraform.tfstate"
  region = "eu-west-1"
}
```

This ensures consistent state across local development and CI/CD runs.

---

## Configuration Management — Ansible

### Inventory and Playbook Structure

Ansible manages all software installation and configuration on both instances. The inventory is dynamically generated by the deploy script (or CI/CD pipeline) using Terraform outputs:

```ini
[app]
<app_public_ip> ansible_host=<app_public_ip> observability_private_ip=<obs_private_ip>

[observability]
<obs_public_ip> ansible_host=<obs_public_ip> app_private_ip=<app_private_ip>
```

The `observability_private_ip` variable on the app group tells Docker Compose where to send OTLP traces. The `app_private_ip` variable on the observability group tells Prometheus where to scrape metrics.

Three playbooks orchestrate the deployment:

| Playbook | Target | Roles Applied |
|----------|--------|---------------|
| `site.yml` | All | Master — imports app.yml and observability.yml |
| `app.yml` | app group | common → app_docker → node_exporter → redis_exporter |
| `observability.yml` | observability group | common → node_exporter → prometheus → grafana → jaeger |

### Roles

**common** — Waits for cloud-init to finish, installs base packages (curl, wget, jq, htop, net-tools, etc.), configures chrony NTP, sets UTC timezone, and tunes kernel parameters (`net.core.somaxconn=65535`, `vm.overcommit_memory=1` for Redis).

**app_docker** — Authenticates with ECR, templates the Docker Compose file with the correct image tags and environment variables (including `OTEL_EXPORTER_OTLP_ENDPOINT`), pulls images, and starts the stack. Health checks verify all three containers (frontend, backend, redis) are running and healthy.

**node_exporter** — Downloads and installs Prometheus Node Exporter v1.8.1 as a binary, creates a dedicated `node_exporter` user, and configures a systemd service. Deployed on both instances. The install task is idempotent — it checks if the binary already exists at the correct version before downloading.

**redis_exporter** — Downloads and installs the Redis Exporter v1.62.0, creates a dedicated `redis_exporter` user, and configures a systemd service pointing at `redis://localhost:6379`. Deployed only on the app instance.

**prometheus** — Downloads and installs Prometheus v2.51.2, creates a dedicated `prometheus` user, templates `prometheus.yml` (with all six scrape targets) and `alert_rules.yml`, validates the rules with `promtool`, and configures a systemd service with lifecycle API enabled (for hot-reloading via `/-/reload`). Data retention is set to 15 days.

**grafana** — Installs Grafana 10.4.2 from the official APT repository, templates `grafana.ini` (with unified alerting enabled, anonymous auth disabled, admin credentials), provisions two datasources (Prometheus and Jaeger with `tracesToLogsV2` integration), and deploys the dashboard JSON. The role includes diagnostic tasks that capture `journalctl` output if Grafana fails to start, so I can debug issues from CI/CD logs.

**jaeger** — Templates a Docker Compose file for Jaeger all-in-one v1.57, pulls the image, and starts the container. Jaeger is configured with in-memory storage (50,000 max traces), OTLP collection enabled, and health checks via `wget --spider`. The role uses `ansible.builtin.command` for Docker operations instead of community Docker modules to avoid compatibility issues.

### Group Variables

Configuration values are organised into three group variable files:

- `all.yml` — Project name, common packages, NTP settings.
- `app.yml` — Application directory paths, ports, exporter versions.
- `observability.yml` — Prometheus version/retention/scrape interval, Grafana version/credentials, Jaeger version/image/ports/storage settings.

---

## CI/CD Pipeline — GitHub Actions

### CI Pipeline (`.github/workflows/ci.yml`)

Triggered on pull requests to `main`/`develop` and pushes to non-main branches. It runs five parallel validation jobs:

| Job | What It Checks |
|-----|---------------|
| **lint** | `npm ci --omit=dev` + `npm audit` for both backend and frontend |
| **build-images** | Docker Buildx builds for both images (no push, cache only) |
| **terraform-validate** | `terraform fmt -check -recursive`, `terraform init` (local backend), `terraform validate` |
| **validate-prometheus** | Downloads `promtool`, validates `alert_rules.yml` syntax |
| **ansible-lint** | Runs `ansible-lint` and `ansible-playbook --syntax-check` on `site.yml` |

### CD Pipeline (`.github/workflows/deploy.yml`)

Triggered on pushes to `main` or manual dispatch. It runs four sequential jobs:

**Job 1: setup** — Initialises Terraform with the S3 backend, runs `terraform plan` and `terraform apply -auto-approve`. Extracts 14 outputs (IPs, ECR URLs, SSH key) and passes them to subsequent jobs via GitHub Actions outputs.

**Job 2: build-and-push** — Builds both Docker images using the ECR URLs from the setup job. Tags each image with both `$GITHUB_SHA` (for immutable versioning) and `latest`. Pushes to ECR.

**Job 3: ansible-deploy** — Re-reads Terraform state to get current IPs, generates the Ansible inventory dynamically, writes the SSH private key to disk, installs Ansible, and runs `ansible-playbook site.yml`. This configures both instances with all roles.

**Job 4: smoke-test** — Verifies eight health endpoints are responding:

```
Frontend (:3000)          Backend (:3001)
Node Exporter app (:9100) Node Exporter obs (:9100)
Redis Exporter (:9121)    Prometheus (:9090)
Grafana (:3000)           Jaeger (:16686)
```

The pipeline uses DCE (Dynamic Cloud Environment) credentials — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` — stored as GitHub Secrets.

---

## Prometheus — Metrics Collection and Alerting

### Scrape Configuration

Prometheus scrapes six targets every 15 seconds:

| Job Name | Target | Port | Metrics |
|----------|--------|------|---------|
| `prometheus` | localhost | 9090 | Self-monitoring |
| `voting-backend` | app private IP | 3001 | RED metrics, votes, Redis operation duration, active connections, Node.js process metrics |
| `voting-frontend` | app private IP | 3000 | Frontend RED metrics, Node.js process metrics |
| `redis` | app private IP | 9121 | Redis memory, clients, commands, keys, evictions, hit rate |
| `node-exporter-app` | app private IP | 9100 | CPU, memory, disk, network, filesystem |
| `node-exporter-observability` | localhost | 9100 | Same host metrics for the monitoring instance |

### Alert Rules (8 rules)

All alert rules are defined in `alert_rules.yml` and validated by `promtool` at deploy time:

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| **HighErrorRate** | Error ratio > 5% of total requests | 5 minutes | critical |
| **HighLatencyP95** | 95th percentile latency > 300ms | 10 minutes | warning |
| **BackendDown** | Backend target unreachable | 1 minute | critical |
| **FrontendDown** | Frontend target unreachable | 1 minute | critical |
| **RedisDown** | Redis exporter target unreachable | 1 minute | critical |
| **RedisHighMemory** | Redis memory usage > 80% of max | 5 minutes | warning |
| **HighCPUUsage** | CPU utilisation > 80% | 5 minutes | warning |
| **HighMemoryUsage** | Memory utilisation > 85% | 5 minutes | warning |

Every alert annotation includes a `runbook` link that describes how to investigate using Jaeger traces and structured logs — closing the loop between alerting and root-cause analysis.

---

## Grafana — Dashboards and Visualisation

The Grafana dashboard is provisioned automatically and contains **31 panels** organised into five sections:

### Section 1: Backend and Redis — RED Metrics

- **Request Rate** — `sum(rate(http_requests_total[5m])) by (route)` — Shows throughput per route.
- **Error Rate** — `sum(rate(http_errors_total[5m])) / sum(rate(http_requests_total[5m]))` — Ratio of errors to total requests with threshold lines at 1% (yellow) and 5% (red, matching the alert rule).
- **Latency P50 / P95 / P99** — `histogram_quantile` over `http_request_duration_seconds_bucket` — Three percentile lines with a threshold at 300ms (matching the alert rule).
- **Requests by Method and Route** — Breakdown of traffic patterns.
- **Active Connections** — Current gauge of open HTTP connections.

### Section 2: Redis — Performance and Health

- **Memory Usage** — Used vs max memory with colour-coded thresholds.
- **Connected Clients** — Number of active Redis connections.
- **Commands per Second** — Rate of Redis command processing.
- **Operation Duration P95** — Latency of Redis operations as observed from the backend (via `redis_operation_duration_seconds`).
- **Keys and Evictions** — Key count per database plus eviction rate.
- **Cache Hit Rate** — Ratio of keyspace hits to total lookups.

### Section 3: System Metrics — Saturation

- **CPU Usage (%)** — Per-instance CPU utilisation derived from `node_cpu_seconds_total`.
- **Memory Usage (%)** — Derived from `node_memory_MemAvailable_bytes / MemTotal`.
- **Disk Usage (%)** — Root filesystem utilisation.
- **Network I/O** — Receive and transmit bytes per second per interface.
- **Load Average** — 1m, 5m, 15m load averages.
- **Memory Breakdown** — Used, cached, and buffer memory.
- **Disk I/O Throughput** — Read and write bytes per second.

### Section 4: App Metrics — Votes, Frontend and Process

- **Votes per Option (rate)** — Live voting rate by poll option.
- **Votes — Total Cumulative** — Running total of votes cast.
- **Frontend Request Rate** — Throughput through the frontend proxy.
- **Frontend Latency** — P50/P95/P99 for the frontend.
- **Process Heap Memory** — Node.js heap used vs total for the backend.
- **Event Loop Lag** — Average and P99 event loop lag — indicates if the backend is CPU-bound.

### Section 5: Distributed Tracing — Jaeger

- **Traces — Voting Backend** — Live trace search panel querying Jaeger for `voting-backend` service traces.
- **Traces — Voting Frontend** — Same for `voting-frontend`.

These panels use the `traces` visualisation type and query Jaeger directly via the provisioned datasource (`uid: jaeger`).

### Datasource Configuration

Both datasources are provisioned with explicit UIDs to ensure dashboard panel references resolve correctly:

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus        # Referenced by all metric panels
    url: http://localhost:9090
    isDefault: true

  - name: Jaeger
    type: jaeger
    uid: jaeger            # Referenced by trace panels
    url: http://localhost:16686
    jsonData:
      tracesToLogsV2:      # Links traces to log queries in Prometheus/Loki
        datasourceUid: prometheus
        filterByTraceID: true
        filterBySpanID: true
      nodeGraph:
        enabled: true      # Enables the service dependency graph view
```

---

## Jaeger — Distributed Tracing

### Deployment

Jaeger runs as the `all-in-one` image (version 1.57) in Docker Compose on the observability instance. This single container includes the collector, query service, and UI.

### Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| `COLLECTOR_OTLP_ENABLED` | `true` | Accept traces via OTLP protocol |
| `SPAN_STORAGE_TYPE` | `memory` | In-memory storage (no external database needed) |
| `MEMORY_MAX_TRACES` | `50000` | Maximum traces retained before eviction |
| Ports | 16686 (UI), 4317 (gRPC), 4318 (HTTP) | UI access and trace ingestion |

### How Traces Flow

1. The OpenTelemetry SDK in each service creates spans automatically for every HTTP request (Express middleware), outgoing HTTP call (axios in frontend), and Redis command (ioredis in backend).
2. The `BatchSpanProcessor` batches completed spans and exports them to `http://<obs-private-ip>:4318/v1/traces` (the SDK appends `/v1/traces` to the base endpoint automatically).
3. Jaeger stores the spans in memory and makes them queryable via its UI on port 16686 and via its API (which Grafana's Jaeger datasource uses).

### What You See in Jaeger

When you open the Jaeger UI and select a service (e.g., `voting-backend`), you see a list of recent traces. Each trace shows:

- The full request lifecycle from frontend → backend → Redis.
- Individual spans for each operation (HTTP request handling, Redis GET/SET/EVAL commands).
- Timing information showing where latency occurs.
- Span tags with HTTP method, status code, route, and Redis command details.

---

## Structured Logging with Trace Correlation

Both the backend and frontend use **Winston** for structured JSON logging. The key feature is automatic injection of OpenTelemetry trace context into every log line:

```javascript
// From logger.js
const activeSpan = trace.getActiveSpan();
const spanContext = activeSpan ? activeSpan.spanContext() : {};
return {
    trace_id: spanContext.traceId || '',
    span_id: spanContext.spanId || '',
    service: 'voting-backend',
    ...info
};
```

This produces log output like:

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "message": "Vote recorded",
  "trace_id": "abc123def456789...",
  "span_id": "789xyz...",
  "service": "voting-backend",
  "pollId": "poll_abc",
  "optionIndex": 2
}
```

### Why This Matters

When an alert fires (e.g., `HighErrorRate`), the investigation path is:

1. **Grafana dashboard** shows the error rate spike and the time window.
2. **Jaeger trace panel** in the same dashboard shows traces from that time period.
3. Click a trace to see the full request lifecycle and identify which span errored.
4. The `trace_id` from the trace can be used to grep application logs: `docker logs backend | jq 'select(.trace_id == "abc123...")'`
5. The log entry contains the full error context (stack trace, request parameters, etc.).

This closes the **metric → trace → log** correlation loop.

---

## Load Testing and Chaos Simulation

The `scripts/load-test.sh` script generates realistic traffic patterns to validate the observability stack:

```bash
./scripts/load-test.sh <APP_HOST> [DURATION_SECONDS]
```

It runs four phases:

| Phase | Duration | What It Does |
|-------|----------|--------------|
| **Warm-up** | 30% of total | Normal traffic — creates polls and votes at moderate rate |
| **Error Burst** | 20% of total | Hits `/api/simulate/error` to trigger 500s and fire `HighErrorRate` alert |
| **Latency Burst** | 20% of total | Hits `/api/simulate/latency` to inject 2–5s delays and fire `HighLatencyP95` alert |
| **Sustained Mixed** | 30% of total | Combines normal traffic, errors, and latency simultaneously |

Each phase uses parallel `curl` requests to generate meaningful load. After running the load test, within 5–10 minutes you should see:

- Error rate spikes in the Grafana dashboard.
- The `HighErrorRate` and `HighLatencyP95` alerts firing in Prometheus.
- Slow and failed traces visible in Jaeger.
- Correlated log entries with `trace_id` values.

### Validation Script

The `scripts/validate.sh` script performs end-to-end observability validation:

```bash
./scripts/validate.sh <APP_HOST> <OBS_HOST>
```

It checks:
1. Application health (frontend + backend responding).
2. Metrics endpoints (verifies specific metric names are present).
3. Monitoring stack (Prometheus, Grafana, Jaeger all reachable).
4. Prometheus targets (all six targets in UP state).
5. Jaeger traces (casts a vote on the app, then queries Jaeger for traces from `voting-backend`).
6. Alert rules (verifies all eight rules are loaded in Prometheus).

---

## Incident Investigation Walkthrough

This section demonstrates the full alert-to-root-cause investigation flow using the observability stack.

### Scenario: High Error Rate Alert Fires

**Step 1: Alert Fires**

After running the load test's error burst phase, Prometheus detects that the error ratio exceeds 5% for 5 minutes and fires the `HighErrorRate` alert.

**Step 2: Grafana Dashboard — Identify the Symptom**

Open the Grafana dashboard ("Voting App — Observability Dashboard"). In the **Backend and Redis — RED Metrics** section:

- The **Error Rate** panel shows a sharp spike above the 5% threshold line.
- The **Request Rate** panel shows overall throughput, confirming traffic is flowing.
- The **Latency** panel may show increased P95/P99 if errors are preceded by timeouts.

The time range on these panels pinpoints exactly when the issue started and its duration.

**Step 3: Jaeger Traces — Pinpoint the Failing Request**

Scroll down to the **Distributed Tracing — Jaeger** section. The **Traces — Voting Backend** panel shows recent traces. Look for traces with error icons (red exclamation marks). Click on an error trace to open it in Jaeger.

The trace waterfall shows:
- The HTTP span for `POST /api/simulate/error` with `http.status_code: 500`.
- The span's events/logs contain the error message: `"Simulated error for testing"`.
- The span duration, start time, and service name.

**Step 4: Log Correlation — Get Full Context**

Copy the `trace_id` from the Jaeger trace view. SSH into the app instance and search the backend container logs:

```bash
docker logs voting-app-backend-1 2>&1 | jq 'select(.trace_id == "<trace_id>")'
```

The matching log entries show the full error context — the log level (`error`), the error message, the request path, and any additional metadata the application logged.

**Step 5: Root Cause Resolution**

The trace and logs together confirm the root cause: the `/api/simulate/error` endpoint was called during load testing, which intentionally throws a 500 error. In a real incident, the same investigation path would reveal actual bugs — database timeouts, malformed requests, or downstream service failures — instead of simulated errors.

### Scenario: High Latency Alert Fires

The same investigation flow applies:

1. `HighLatencyP95` alert fires (P95 > 300ms for 10 minutes).
2. Grafana's **Latency P50/P95/P99** panel shows the P95 line crossing the threshold.
3. Jaeger traces from that time window show spans with unusually long durations.
4. The trace waterfall reveals which span is slow — it could be a Redis command taking too long, a backend handler processing slowly, or network latency between services.
5. Logs correlated via `trace_id` provide additional context (e.g., "Simulated latency: 3500ms").

---

## Repository Structure

```
advance-monitoring/
├── .github/
│   └── workflows/
│       ├── ci.yml                      # CI: lint, build, terraform validate, promtool, ansible-lint
│       └── deploy.yml                  # CD: terraform apply → build & push → ansible deploy → smoke test
│
├── app/
│   ├── docker-compose.app.yml          # Local dev compose (reference)
│   ├── backend/
│   │   ├── Dockerfile                  # Multi-stage Node 18-alpine build
│   │   ├── package.json                # Express, ioredis, prom-client, OpenTelemetry, Winston
│   │   └── src/
│   │       ├── server.js               # REST API (11 endpoints) with Redis Lua scripting
│   │       ├── metrics.js              # RED metrics + custom counters/histograms
│   │       ├── tracing.js              # OpenTelemetry SDK with OTLP/HTTP exporter
│   │       └── logger.js               # Winston JSON logger with trace_id/span_id injection
│   └── frontend/
│       ├── Dockerfile
│       ├── package.json
│       └── src/
│           ├── server.js               # Express proxy + static file serving
│           ├── tracing.js              # OpenTelemetry SDK
│           ├── logger.js               # Winston JSON logger with trace context
│           └── public/
│               └── index.html          # Single-page voting UI
│
├── ansible/
│   ├── ansible.cfg                     # SSH pipelining, fact caching, sudo
│   ├── site.yml                        # Master playbook
│   ├── app.yml                         # App instance playbook
│   ├── observability.yml               # Monitoring instance playbook
│   ├── inventory/
│   │   └── hosts.ini                   # Dynamically generated inventory
│   ├── group_vars/
│   │   ├── all.yml                     # Common settings
│   │   ├── app.yml                     # App-specific variables
│   │   └── observability.yml           # Monitoring-specific variables
│   └── roles/
│       ├── common/                     # Base system setup
│       ├── app_docker/                 # Docker Compose deployment with ECR
│       ├── node_exporter/              # Prometheus Node Exporter
│       ├── redis_exporter/             # Redis Exporter
│       ├── prometheus/                 # Prometheus server + alert rules
│       ├── grafana/                    # Grafana + provisioned datasources/dashboards
│       └── jaeger/                     # Jaeger all-in-one via Docker Compose
│
├── monitoring/
│   ├── docker-compose.monitoring.yml   # Reference Jaeger compose
│   ├── prometheus/
│   │   ├── prometheus.yml              # Reference Prometheus config
│   │   └── alert_rules.yml             # Reference alert rules
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasources.yml     # Reference datasource config
│           └── dashboards/
│               ├── dashboards.yml      # Dashboard provisioning
│               └── voting-app-dashboard.json  # Reference dashboard
│
├── terraform/
│   ├── main.tf                         # Root module: VPC, app, observability, ECR
│   ├── variables.tf                    # Input variables
│   ├── outputs.tf                      # 14 outputs (IPs, URLs, SSH key)
│   ├── provider.tf                     # AWS provider + S3 backend
│   ├── terraform.tfvars.example        # Example variable values
│   └── modules/
│       ├── vpc/                        # Network resources
│       ├── app/                        # App instance + SG
│       ├── observability/              # Monitoring instance + SG + cross-SG rules
│       ├── ec2-instance/               # Reusable EC2 resource
│       └── ecr/                        # Container registries
│
└── scripts/
    ├── deploy.sh                       # Full deployment orchestrator
    ├── load-test.sh                    # 4-phase load/chaos testing
    ├── validate.sh                     # End-to-end observability validation
    └── cleanup.sh                      # Terraform destroy + cleanup
```

---

## Deployment Guide

### Prerequisites

- AWS account with credentials (access key, secret key, session token).
- Terraform >= 1.5.0.
- Ansible >= 2.14.
- Docker (for local builds).
- An S3 bucket named `advance-monitoring-tfstate` in `eu-west-1` for Terraform state.

### Option 1: CI/CD Pipeline (Recommended)

1. Fork/clone the repository.
2. Set GitHub Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`.
3. Push to `main` — the deploy workflow runs automatically.
4. The smoke-test job verifies all services are healthy.

### Option 2: Manual Deployment

```bash
# 1. Provision infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars  # Edit values
terraform init
terraform apply

# 2. Deploy application and monitoring
cd ..
./scripts/deploy.sh

# 3. Run load test to generate data
./scripts/load-test.sh <APP_PUBLIC_IP> 120

# 4. Validate everything works
./scripts/validate.sh <APP_PUBLIC_IP> <OBS_PUBLIC_IP>

# 5. Access the services
# Frontend:  http://<APP_PUBLIC_IP>:3000
# Grafana:   http://<OBS_PUBLIC_IP>:3000  (admin/admin123)
# Jaeger:    http://<OBS_PUBLIC_IP>:16686
# Prometheus: http://<OBS_PUBLIC_IP>:9090
```

### Cleanup

```bash
./scripts/cleanup.sh
```

---

## Screenshots and Evidence

> **Note:** Place screenshots in a `docs/screenshots/` directory and reference them here.

### Expected Screenshots

1. **Grafana Dashboard** — Full dashboard showing all five sections with live data after a load test.
2. **Prometheus Targets** — All six targets in UP state (`Status → Targets`).
3. **Prometheus Alerts** — `HighErrorRate` and `HighLatencyP95` in firing state during load test.
4. **Jaeger Trace List** — Service dropdown showing three services (`voting-backend`, `voting-frontend`, `redis`) with trace results.
5. **Jaeger Trace Detail** — A single trace showing the full waterfall: frontend → backend → Redis spans.
6. **Application UI** — The Quick Poll interface with active polls and vote results.
7. **GitHub Actions Pipeline** — Successful deployment run showing all four jobs completing.
8. **Structured Logs** — Terminal output showing JSON logs with `trace_id` and `span_id` fields.

---
