"use strict";

const client = require("prom-client");

/* ------------------------------------------------------------------ */
/*  RED Metrics — Rate, Errors, Duration                              */
/* ------------------------------------------------------------------ */

const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5],
});

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
});

const httpErrorsTotal = new client.Counter({
  name: "http_errors_total",
  help: "Total number of HTTP error responses (4xx + 5xx)",
  labelNames: ["method", "route", "status_code"],
});

const votesTotal = new client.Counter({
  name: "votes_total",
  help: "Total votes cast",
  labelNames: ["option"],
});

const activeConnections = new client.Gauge({
  name: "active_connections",
  help: "Number of currently active connections",
});

const redisOperationDuration = new client.Histogram({
  name: "redis_operation_duration_seconds",
  help: "Duration of Redis operations in seconds",
  labelNames: ["operation", "status"],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1],
});

/* ------------------------------------------------------------------ */
/*  Default process / Node.js metrics                                 */
/* ------------------------------------------------------------------ */

client.collectDefaultMetrics({
  prefix: "voting_backend_",
  labels: { service: "voting-backend" },
});

/* ------------------------------------------------------------------ */
/*  Initialise counters so metrics exist from startup                  */
/*  Without this, http_errors_total only appears after the first       */
/*  error, making the Grafana error rate panel show "No data".         */
/* ------------------------------------------------------------------ */

httpErrorsTotal.labels({ method: "GET", route: "/health", status_code: "500" });
httpRequestsTotal.labels({ method: "GET", route: "/health", status_code: "200" });

/* ------------------------------------------------------------------ */
/*  Express middleware to record RED metrics per request               */
/* ------------------------------------------------------------------ */

function metricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();
  activeConnections.inc();

  res.on("finish", () => {
    const durationSec = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route ? req.route.path : req.path;
    const labels = {
      method: req.method,
      route,
      status_code: res.statusCode,
    };

    httpRequestDuration.observe(labels, durationSec);
    httpRequestsTotal.inc(labels);

    if (res.statusCode >= 400) {
      httpErrorsTotal.inc(labels);
    }

    activeConnections.dec();
  });

  next();
}

module.exports = {
  metricsMiddleware,
  httpRequestDuration,
  httpRequestsTotal,
  httpErrorsTotal,
  votesTotal,
  activeConnections,
  redisOperationDuration,
  register: client.register,
};
