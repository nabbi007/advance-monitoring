"use strict";

const express = require("express");
const cors = require("cors");
const Redis = require("ioredis");
const api = require("@opentelemetry/api");

const logger = require("./logger");
const {
  metricsMiddleware,
  votesTotal,
  redisOperationDuration,
  register,
} = require("./metrics");

/* ------------------------------------------------------------------ */
/*  Configuration                                                     */
/* ------------------------------------------------------------------ */

const PORT = parseInt(process.env.PORT, 10) || 3001;
const REDIS_URL = process.env.REDIS_URL || "redis://redis:6379";
const VOTE_OPTIONS = (process.env.VOTE_OPTIONS || "cats,dogs").split(",");

/* ------------------------------------------------------------------ */
/*  Redis Client                                                      */
/* ------------------------------------------------------------------ */

const redis = new Redis(REDIS_URL, {
  retryStrategy: (times) => Math.min(times * 200, 5000),
  maxRetriesPerRequest: 3,
  lazyConnect: false,
});

redis.on("connect", () => logger.info("Redis connected", { redis_url: REDIS_URL }));
redis.on("error", (err) => logger.error("Redis connection error", { error: err.message }));

/* ------------------------------------------------------------------ */
/*  Express App                                                       */
/* ------------------------------------------------------------------ */

const app = express();
app.use(cors());
app.use(express.json());
app.use(metricsMiddleware);

/* ----------  Health / readiness  ---------- */

app.get("/health", async (_req, res) => {
  try {
    await redis.ping();
    res.json({ status: "healthy", redis: "connected", uptime: process.uptime() });
  } catch (err) {
    logger.error("Health check failed", { error: err.message });
    res.status(503).json({ status: "unhealthy", redis: "disconnected" });
  }
});

/* ----------  GET /api/votes  ---------- */

app.get("/api/votes", async (_req, res) => {
  const span = api.trace.getActiveSpan();
  const timerEnd = redisOperationDuration.startTimer({ operation: "mget", status: "success" });

  try {
    const keys = VOTE_OPTIONS.map((o) => `vote:${o}`);
    const values = await redis.mget(...keys);

    const results = {};
    VOTE_OPTIONS.forEach((opt, i) => {
      results[opt] = parseInt(values[i], 10) || 0;
    });

    timerEnd();
    if (span) span.setAttribute("vote.options_count", VOTE_OPTIONS.length);

    logger.info("Votes retrieved", { results });
    res.json({ votes: results, options: VOTE_OPTIONS });
  } catch (err) {
    timerEnd({ status: "error" });
    logger.error("Failed to retrieve votes", { error: err.message });
    res.status(500).json({ error: "Failed to retrieve votes" });
  }
});

/* ----------  POST /api/vote  ---------- */

app.post("/api/vote", async (req, res) => {
  const { option } = req.body;
  const span = api.trace.getActiveSpan();

  if (!option || !VOTE_OPTIONS.includes(option)) {
    logger.warn("Invalid vote option", { option, valid: VOTE_OPTIONS });
    return res.status(400).json({ error: `Invalid option. Choose from: ${VOTE_OPTIONS.join(", ")}` });
  }

  const timerEnd = redisOperationDuration.startTimer({ operation: "incr", status: "success" });

  try {
    const newCount = await redis.incr(`vote:${option}`);
    timerEnd();

    votesTotal.inc({ option });

    if (span) {
      span.setAttribute("vote.option", option);
      span.setAttribute("vote.new_count", newCount);
    }

    logger.info("Vote recorded", { option, newCount });
    res.json({ option, count: newCount });
  } catch (err) {
    timerEnd({ status: "error" });
    logger.error("Failed to record vote", { error: err.message, option });
    res.status(500).json({ error: "Failed to record vote" });
  }
});

/* ----------  GET /api/results  ---------- */

app.get("/api/results", async (_req, res) => {
  const timerEnd = redisOperationDuration.startTimer({ operation: "mget", status: "success" });

  try {
    const keys = VOTE_OPTIONS.map((o) => `vote:${o}`);
    const values = await redis.mget(...keys);

    const results = {};
    let total = 0;
    VOTE_OPTIONS.forEach((opt, i) => {
      const count = parseInt(values[i], 10) || 0;
      results[opt] = count;
      total += count;
    });

    timerEnd();
    logger.info("Results retrieved", { total });
    res.json({ votes: results, total, options: VOTE_OPTIONS });
  } catch (err) {
    timerEnd({ status: "error" });
    logger.error("Failed to retrieve results", { error: err.message });
    res.status(500).json({ error: "Failed to retrieve results" });
  }
});

/* ----------  POST /api/reset  ---------- */

app.post("/api/reset", async (_req, res) => {
  const timerEnd = redisOperationDuration.startTimer({ operation: "del", status: "success" });

  try {
    const keys = VOTE_OPTIONS.map((o) => `vote:${o}`);
    await redis.del(...keys);
    timerEnd();
    logger.info("Votes reset");
    res.json({ message: "Votes reset successfully" });
  } catch (err) {
    timerEnd({ status: "error" });
    logger.error("Failed to reset votes", { error: err.message });
    res.status(500).json({ error: "Failed to reset votes" });
  }
});

/* ----------  Prometheus /metrics  ---------- */

app.get("/metrics", async (_req, res) => {
  try {
    res.set("Content-Type", register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    logger.error("Metrics scrape failed", { error: err.message });
    res.status(500).end(err.message);
  }
});

/* ----------  Simulate errors (load testing helper)  ---------- */

app.get("/api/simulate/error", (_req, res) => {
  logger.error("Simulated 500 error for testing");
  res.status(500).json({ error: "Simulated internal server error" });
});

app.get("/api/simulate/latency", async (_req, res) => {
  const delay = Math.random() * 2000 + 500; // 500ms–2500ms
  logger.warn("Simulated latency", { delay_ms: delay });
  await new Promise((resolve) => setTimeout(resolve, delay));
  res.json({ message: "Slow response", delay_ms: Math.round(delay) });
});

/* ------------------------------------------------------------------ */
/*  Start Server                                                      */
/* ------------------------------------------------------------------ */

app.listen(PORT, "0.0.0.0", () => {
  logger.info(`Voting backend listening on port ${PORT}`, {
    port: PORT,
    redis_url: REDIS_URL,
    vote_options: VOTE_OPTIONS,
  });
});

module.exports = app;
