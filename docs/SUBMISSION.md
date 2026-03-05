# Project Submission — Advanced Monitoring & Observability

## Deliverables

| Item | Description |
|------|-------------|
| **App code with instrumentation** | Node.js backend and frontend with OpenTelemetry SDK auto-instrumentation, prom-client RED metrics, and structured JSON logging. See `app/backend/src/` and `app/frontend/src/`. |
| **Prometheus config** | `monitoring/prometheus/prometheus.yml` and `monitoring/prometheus/alert_rules.yml` (8 alert rules covering error rate, latency, CPU, memory, and service availability). Deployed via `ansible/roles/prometheus/`. |
| **Grafana dashboard JSON** | `monitoring/grafana/provisioning/dashboards/voting-app-dashboard.json` — 37 panels across 6 sections: Request Rate, Error Rate, Latency (P50/P95/P99), CPU/Memory, Redis, and Trace Explorer with deep links to Jaeger. |
| **Jaeger setup** | `ansible/roles/jaeger/` — Jaeger all-in-one deployed as Docker container, configured as OTLP/HTTP trace collector. UI accessible on port 16686. |
| **Screenshots** | See `docs/screenshots/` — Grafana panels showing live RED metrics, Jaeger trace waterfall, and structured log output. |
| **2-page report** | See [`docs/REPORT.md`](REPORT.md) — maps symptom → trace → root cause for a representative high-error-rate incident. |

## Submission Requirements

| Requirement | Detail |
|-------------|--------|
| **Format** | GitHub Repository |
| **Contents** | App code, OTel config, `prometheus.yml`, Grafana JSON, Jaeger config, screenshots, 2-page report |
| **Tools** | OpenTelemetry SDK (Node.js), Prometheus 2.51.2, Grafana 10.4.2, Jaeger 1.57 (all-in-one) |
| **Evidence** | Alert → trace → log correlation showing root cause identification |

---

## Repository Structure

```
advance-monitoring/
├── app/
│   ├── backend/src/
│   │   ├── server.js        # Express API with 10 REST endpoints
│   │   ├── metrics.js       # prom-client RED metrics + custom counters
│   │   ├── tracing.js       # OpenTelemetry SDK + OTLP/HTTP exporter
│   │   └── logger.js        # Winston structured JSON logger (trace_id injection)
│   └── frontend/src/
│       ├── server.js        # Static server + proxied API calls
│       ├── tracing.js       # Frontend OTel instrumentation
│       └── logger.js        # Structured logging
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml   # Scrape configs for backend, frontend, node, redis
│   │   └── alert_rules.yml  # 8 alert rules (HighErrorRate, HighLatencyP95, etc.)
│   └── grafana/
│       └── provisioning/
│           ├── dashboards/voting-app-dashboard.json   # 37-panel dashboard
│           └── datasources/datasources.yml
├── ansible/                 # 7 roles: common, app_docker, node_exporter,
│                            #   redis_exporter, prometheus, grafana, jaeger
├── terraform/               # 5 modules: vpc, app, observability, ecr, ec2-instance
├── scripts/
│   ├── load-test.sh         # Generates traffic + error bursts for validation
│   └── validate.sh          # Health check smoke tests
└── docs/
    ├── EXPLANATION.md       # Architecture deep-dive
    ├── REPORT.md            # 2-page incident report (symptom → trace → root cause)
    └── aws-architecture.drawio
```

---

## Evidence of Alert → Trace → Log Correlation

### How to Reproduce

1. **SSH into the app instance** and trigger the error simulation endpoint:
   ```bash
   # Generate 50 errors in quick succession
   for i in $(seq 1 50); do
     curl -s http://localhost:3001/api/simulate/error > /dev/null
   done
   ```

2. **Observe the alert** in Grafana (Alerting → Alert Rules → `HighErrorRate`):
   - Condition: `error_rate > 0.05` sustained for 5 minutes
   - Prometheus fires → Grafana alert state changes to **Firing**

3. **Find the trace** in Jaeger (`http://<monitoring-ip>:16686`):
   - Service: `voting-backend`
   - Operation: `GET /api/simulate/error`
   - Each request generates a trace with `http.status_code=500` tag

4. **Correlate to logs**:
   ```bash
   docker logs voting-backend 2>&1 | grep '"level":"error"' | head -5
   ```
   Each log line includes `"trace_id":"<id>"` matching the Jaeger trace.

### Correlation Chain

```
[Grafana Alert]              [Jaeger Trace]               [Application Log]
HighErrorRate fires    →     trace_id: abc123ef     →     {"level":"error",
error_rate = 0.62            span: GET /api/               "message":"Simulated...",
threshold: 0.05                simulate/error               "trace_id":"abc123ef",
for: 5m                      duration: 2ms                 "status":500}
                             status: 500
```

The `trace_id` field is automatically injected into every log line by [logger.js](../app/backend/src/logger.js) using the OpenTelemetry active span context, creating a direct link between the Grafana alert, the specific failing request in Jaeger, and the log entry showing the error detail.
