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
const POLL_CACHE_TTL_MS = parseInt(process.env.POLL_CACHE_TTL_MS, 10) || 15000;
const POLL_INDEX_KEY = "poll:index";

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
/*  Small In-Memory Cache                                             */
/* ------------------------------------------------------------------ */

const pollCache = new Map();
let pollListCache = null;
const ATOMIC_VOTE_LUA = `
  local rawPoll = redis.call("GET", KEYS[1])
  if not rawPoll then
    return cjson.encode({ error = "NOT_FOUND" })
  end

  local poll = cjson.decode(rawPoll)
  if poll.closed then
    return cjson.encode({ error = "CLOSED" })
  end

  local found = false
  for index, option in ipairs(poll.options) do
    if option.id == ARGV[1] then
      option.votes = (option.votes or 0) + 1
      poll.options[index] = option
      found = true
      break
    end
  end

  if not found then
    return cjson.encode({ error = "INVALID_OPTION" })
  end

  poll.totalVotes = (poll.totalVotes or 0) + 1
  poll.updatedAt = ARGV[2]

  redis.call("SET", KEYS[1], cjson.encode(poll))
  return cjson.encode({ poll = poll })
`;

function pollKey(pollId) {
  return `poll:${pollId}`;
}

function makePollId() {
  const random = Math.random().toString(36).slice(2, 7);
  return `poll_${Date.now().toString(36)}_${random}`;
}

function nowIso() {
  return new Date().toISOString();
}

function getCachedValue(cacheItem) {
  if (!cacheItem) return null;
  if (cacheItem.expiresAt <= Date.now()) return null;
  return cacheItem.value;
}

function getPollFromCache(pollId) {
  const cacheItem = pollCache.get(pollId);
  const poll = getCachedValue(cacheItem);

  if (!poll && cacheItem) {
    pollCache.delete(pollId);
  }

  return poll;
}

function setPollCache(poll) {
  pollCache.set(poll.id, {
    value: poll,
    expiresAt: Date.now() + POLL_CACHE_TTL_MS,
  });
}

function invalidatePollListCache() {
  pollListCache = null;
}

function getPollListFromCache() {
  const polls = getCachedValue(pollListCache);
  if (!polls) {
    pollListCache = null;
  }
  return polls;
}

function setPollListCache(polls) {
  pollListCache = {
    value: polls,
    expiresAt: Date.now() + POLL_CACHE_TTL_MS,
  };
}

function sanitizePoll(poll) {
  return {
    ...poll,
    options: poll.options.map((option) => ({
      id: option.id,
      text: option.text,
      votes: Number.isFinite(option.votes) ? option.votes : 0,
    })),
    totalVotes: Number.isFinite(poll.totalVotes) ? poll.totalVotes : 0,
  };
}

async function withRedisMetric(operation, fn) {
  const end = redisOperationDuration.startTimer({ operation, status: "success" });
  try {
    const result = await fn();
    end();
    return result;
  } catch (err) {
    end({ status: "error" });
    throw err;
  }
}

async function getPollById(pollId) {
  const cachedPoll = getPollFromCache(pollId);
  if (cachedPoll) {
    return cachedPoll;
  }

  const rawPoll = await withRedisMetric("get", () => redis.get(pollKey(pollId)));
  if (!rawPoll) {
    return null;
  }

  const poll = sanitizePoll(JSON.parse(rawPoll));
  setPollCache(poll);
  return poll;
}

async function savePoll(poll) {
  const updatedPoll = sanitizePoll(poll);
  await withRedisMetric("set", () => redis.set(pollKey(poll.id), JSON.stringify(updatedPoll)));
  setPollCache(updatedPoll);
  invalidatePollListCache();
  return updatedPoll;
}

async function voteForPoll(pollId, optionId) {
  const payload = await withRedisMetric("eval", () =>
    redis.eval(ATOMIC_VOTE_LUA, 1, pollKey(pollId), optionId, nowIso()),
  );
  const parsedPayload = JSON.parse(payload);

  if (parsedPayload.error) {
    return { error: parsedPayload.error };
  }

  const poll = sanitizePoll(parsedPayload.poll);
  setPollCache(poll);
  invalidatePollListCache();
  return { poll };
}

async function deletePoll(pollId) {
  await withRedisMetric("del", async () => {
    await redis.del(pollKey(pollId));
    await redis.zrem(POLL_INDEX_KEY, pollId);
  });

  pollCache.delete(pollId);
  invalidatePollListCache();
}

async function listPolls() {
  const cachedPolls = getPollListFromCache();
  if (cachedPolls) {
    return cachedPolls;
  }

  const pollIds = await withRedisMetric("zrevrange", () => redis.zrevrange(POLL_INDEX_KEY, 0, 49));
  if (!pollIds.length) {
    setPollListCache([]);
    return [];
  }

  const rawPolls = await withRedisMetric("mget", () => redis.mget(...pollIds.map((id) => pollKey(id))));
  const polls = [];

  rawPolls.forEach((rawPoll) => {
    if (!rawPoll) return;
    try {
      const poll = sanitizePoll(JSON.parse(rawPoll));
      polls.push(poll);
      setPollCache(poll);
    } catch (err) {
      logger.warn("Failed to parse poll payload", { error: err.message });
    }
  });

  setPollListCache(polls);
  return polls;
}

function validateCreatePayload(body) {
  const question = typeof body.question === "string" ? body.question.trim() : "";
  const options = Array.isArray(body.options)
    ? body.options
      .map((option) => (typeof option === "string" ? option.trim() : ""))
      .filter(Boolean)
    : [];

  const uniqueOptions = [...new Set(options)];

  if (!question) {
    return { error: "Question is required" };
  }

  if (question.length > 180) {
    return { error: "Question must be 180 characters or less" };
  }

  if (uniqueOptions.length < 2) {
    return { error: "At least 2 unique options are required" };
  }

  if (uniqueOptions.length > 6) {
    return { error: "No more than 6 options are allowed" };
  }

  if (uniqueOptions.some((option) => option.length > 80)) {
    return { error: "Option labels must be 80 characters or less" };
  }

  return { question, options: uniqueOptions };
}

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
    res.json({
      status: "healthy",
      redis: "connected",
      uptime: process.uptime(),
      cache_ttl_ms: POLL_CACHE_TTL_MS,
    });
  } catch (err) {
    logger.error("Health check failed", { error: err.message });
    res.status(503).json({ status: "unhealthy", redis: "disconnected" });
  }
});

/* ----------  GET /api/polls  ---------- */

app.get("/api/polls", async (_req, res) => {
  const span = api.trace.getActiveSpan();

  try {
    const polls = await listPolls();
    if (span) span.setAttribute("poll.count", polls.length);

    res.json({ polls });
  } catch (err) {
    logger.error("Failed to list polls", { error: err.message });
    res.status(500).json({ error: "Failed to list polls" });
  }
});

/* ----------  POST /api/polls  ---------- */

app.post("/api/polls", async (req, res) => {
  const validation = validateCreatePayload(req.body);
  if (validation.error) {
    return res.status(400).json({ error: validation.error });
  }

  const { question, options } = validation;
  const createdAt = nowIso();
  const poll = {
    id: makePollId(),
    question,
    options: options.map((text, index) => ({
      id: `opt_${index + 1}`,
      text,
      votes: 0,
    })),
    totalVotes: 0,
    createdAt,
    updatedAt: createdAt,
    closed: false,
  };

  try {
    await withRedisMetric("multi", async () => {
      const transaction = redis.multi();
      transaction.set(pollKey(poll.id), JSON.stringify(poll));
      transaction.zadd(POLL_INDEX_KEY, Date.now(), poll.id);
      await transaction.exec();
    });

    setPollCache(poll);
    invalidatePollListCache();

    logger.info("Poll created", { pollId: poll.id });
    res.status(201).json({ poll });
  } catch (err) {
    logger.error("Failed to create poll", { error: err.message });
    res.status(500).json({ error: "Failed to create poll" });
  }
});

/* ----------  GET /api/polls/:pollId  ---------- */

app.get("/api/polls/:pollId", async (req, res) => {
  const { pollId } = req.params;

  try {
    const poll = await getPollById(pollId);
    if (!poll) {
      return res.status(404).json({ error: "Poll not found" });
    }

    res.json({ poll });
  } catch (err) {
    logger.error("Failed to get poll", { error: err.message, pollId });
    res.status(500).json({ error: "Failed to get poll" });
  }
});

/* ----------  POST /api/polls/:pollId/vote  ---------- */

app.post("/api/polls/:pollId/vote", async (req, res) => {
  const { pollId } = req.params;
  const optionId = typeof req.body.optionId === "string" ? req.body.optionId : "";
  const span = api.trace.getActiveSpan();

  if (!optionId) {
    return res.status(400).json({ error: "optionId is required" });
  }

  try {
    const voteResult = await voteForPoll(pollId, optionId);

    if (voteResult.error === "NOT_FOUND") {
      return res.status(404).json({ error: "Poll not found" });
    }

    if (voteResult.error === "CLOSED") {
      return res.status(409).json({ error: "Poll is closed" });
    }

    if (voteResult.error === "INVALID_OPTION") {
      return res.status(400).json({ error: "Invalid optionId" });
    }

    const updatedPoll = voteResult.poll;
    votesTotal.inc({ option: `${pollId}:${optionId}` });

    if (span) {
      span.setAttribute("poll.id", pollId);
      span.setAttribute("poll.option_id", optionId);
      span.setAttribute("poll.total_votes", updatedPoll.totalVotes);
    }

    logger.info("Vote recorded", { pollId, optionId, totalVotes: updatedPoll.totalVotes });
    res.json({ poll: updatedPoll });
  } catch (err) {
    logger.error("Failed to record vote", { error: err.message, pollId, optionId });
    res.status(500).json({ error: "Failed to record vote" });
  }
});

/* ----------  PATCH /api/polls/:pollId/close  ---------- */

app.patch("/api/polls/:pollId/close", async (req, res) => {
  const { pollId } = req.params;
  const closed = typeof req.body.closed === "boolean" ? req.body.closed : true;

  try {
    const poll = await getPollById(pollId);
    if (!poll) {
      return res.status(404).json({ error: "Poll not found" });
    }

    poll.closed = closed;
    poll.updatedAt = nowIso();

    const updatedPoll = await savePoll(poll);
    logger.info("Poll closure state updated", { pollId, closed });
    res.json({ poll: updatedPoll });
  } catch (err) {
    logger.error("Failed to update poll closure", { error: err.message, pollId });
    res.status(500).json({ error: "Failed to update poll closure" });
  }
});

/* ----------  POST /api/polls/:pollId/reset  ---------- */

app.post("/api/polls/:pollId/reset", async (req, res) => {
  const { pollId } = req.params;

  try {
    const poll = await getPollById(pollId);
    if (!poll) {
      return res.status(404).json({ error: "Poll not found" });
    }

    poll.options = poll.options.map((option) => ({ ...option, votes: 0 }));
    poll.totalVotes = 0;
    poll.updatedAt = nowIso();

    const updatedPoll = await savePoll(poll);
    logger.info("Poll reset", { pollId });
    res.json({ poll: updatedPoll });
  } catch (err) {
    logger.error("Failed to reset poll", { error: err.message, pollId });
    res.status(500).json({ error: "Failed to reset poll" });
  }
});

/* ----------  DELETE /api/polls/:pollId  ---------- */

app.delete("/api/polls/:pollId", async (req, res) => {
  const { pollId } = req.params;

  try {
    const poll = await getPollById(pollId);
    if (!poll) {
      return res.status(404).json({ error: "Poll not found" });
    }

    await deletePoll(pollId);
    logger.info("Poll deleted", { pollId });
    res.json({ message: "Poll deleted" });
  } catch (err) {
    logger.error("Failed to delete poll", { error: err.message, pollId });
    res.status(500).json({ error: "Failed to delete poll" });
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
  const delay = Math.random() * 2000 + 500;
  logger.warn("Simulated latency", { delay_ms: delay });
  await new Promise((resolve) => setTimeout(resolve, delay));
  res.json({ message: "Slow response", delay_ms: Math.round(delay) });
});

/* ------------------------------------------------------------------ */
/*  Start Server                                                      */
/* ------------------------------------------------------------------ */

app.listen(PORT, "0.0.0.0", () => {
  logger.info(`Quick Poll backend listening on port ${PORT}`, {
    port: PORT,
    redis_url: REDIS_URL,
    poll_cache_ttl_ms: POLL_CACHE_TTL_MS,
  });
});

module.exports = app;
