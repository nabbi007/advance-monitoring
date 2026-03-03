"use strict";

const express = require("express");
const axios = require("axios");
const path = require("path");
const client = require("prom-client");
const api = require("@opentelemetry/api");
const logger = require("./logger");

/* ------------------------------------------------------------------ */
/*  Configuration                                                     */
/* ------------------------------------------------------------------ */

const PORT = parseInt(process.env.PORT, 10) || 3000;
const BACKEND_URL = process.env.BACKEND_URL || "http://backend:3001";

/* ------------------------------------------------------------------ */
/*  Prometheus Metrics                                                */
/* ------------------------------------------------------------------ */

const httpRequestDuration = new client.Histogram({
  name: "frontend_http_request_duration_seconds",
  help: "Duration of frontend HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5],
});

const httpRequestsTotal = new client.Counter({
  name: "frontend_http_requests_total",
  help: "Total number of frontend HTTP requests",
  labelNames: ["method", "route", "status_code"],
});

client.collectDefaultMetrics({
  prefix: "voting_frontend_",
  labels: { service: "voting-frontend" },
});

function metricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const durationSec = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route ? req.route.path : req.path;
    httpRequestDuration.observe({ method: req.method, route, status_code: res.statusCode }, durationSec);
    httpRequestsTotal.inc({ method: req.method, route, status_code: res.statusCode });
  });
  next();
}

/* ------------------------------------------------------------------ */
/*  Express App                                                       */
/* ------------------------------------------------------------------ */

const app = express();
app.use(express.json());
app.use(metricsMiddleware);
app.use(express.static(path.join(__dirname, "public")));

/* ----------  Proxy API calls to backend  ---------- */

app.get("/api/votes", async (req, res) => {
  try {
    const response = await axios.get(`${BACKEND_URL}/api/votes`);
    logger.info("Fetched votes from backend");
    res.json(response.data);
  } catch (err) {
    logger.error("Failed to fetch votes", { error: err.message });
    res.status(502).json({ error: "Backend unavailable" });
  }
});

app.post("/api/vote", async (req, res) => {
  try {
    const response = await axios.post(`${BACKEND_URL}/api/vote`, req.body);
    logger.info("Vote proxied to backend", { option: req.body.option });
    res.json(response.data);
  } catch (err) {
    logger.error("Failed to proxy vote", { error: err.message, option: req.body.option });
    const status = err.response ? err.response.status : 502;
    res.status(status).json(err.response ? err.response.data : { error: "Backend unavailable" });
  }
});

app.get("/api/results", async (req, res) => {
  try {
    const response = await axios.get(`${BACKEND_URL}/api/results`);
    logger.info("Fetched results from backend");
    res.json(response.data);
  } catch (err) {
    logger.error("Failed to fetch results", { error: err.message });
    res.status(502).json({ error: "Backend unavailable" });
  }
});

app.post("/api/reset", async (req, res) => {
  try {
    const response = await axios.post(`${BACKEND_URL}/api/reset`);
    logger.info("Votes reset proxied to backend");
    res.json(response.data);
  } catch (err) {
    logger.error("Failed to reset votes", { error: err.message });
    res.status(502).json({ error: "Backend unavailable" });
  }
});

/* ----------  Health  ---------- */

app.get("/health", async (_req, res) => {
  try {
    const backendHealth = await axios.get(`${BACKEND_URL}/health`, { timeout: 3000 });
    res.json({ status: "healthy", backend: backendHealth.data });
  } catch (err) {
    logger.error("Frontend health check – backend unreachable", { error: err.message });
    res.status(503).json({ status: "degraded", backend: "unreachable" });
  }
});

/* ----------  Prometheus /metrics  ---------- */

app.get("/metrics", async (_req, res) => {
  try {
    res.set("Content-Type", client.register.contentType);
    res.end(await client.register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

/* ----------  SPA fallback  ---------- */

app.get("*", (_req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

/* ------------------------------------------------------------------ */
/*  Start Server                                                      */
/* ------------------------------------------------------------------ */

app.listen(PORT, "0.0.0.0", () => {
  logger.info(`Voting frontend listening on port ${PORT}`, { port: PORT, backend: BACKEND_URL });
});

module.exports = app;
