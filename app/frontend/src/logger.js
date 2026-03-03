"use strict";

const winston = require("winston");
const api = require("@opentelemetry/api");

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: winston.format.combine(
    winston.format.timestamp({ format: "YYYY-MM-DDTHH:mm:ss.SSSZ" }),
    winston.format.printf(({ timestamp, level, message, ...meta }) => {
      const span = api.trace.getActiveSpan();
      const spanContext = span ? span.spanContext() : {};
      return JSON.stringify({
        timestamp,
        level,
        message,
        trace_id: spanContext.traceId || "N/A",
        span_id: spanContext.spanId || "N/A",
        service: process.env.OTEL_SERVICE_NAME || "voting-frontend",
        ...meta,
      });
    })
  ),
  transports: [new winston.transports.Console()],
});

module.exports = logger;
