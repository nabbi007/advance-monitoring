"use strict";

const { NodeSDK } = require("@opentelemetry/sdk-node");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { Resource } = require("@opentelemetry/resources");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");
const { BatchSpanProcessor } = require("@opentelemetry/sdk-trace-base");

const JAEGER_ENDPOINT = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || "http://jaeger:4318/v1/traces";
const SERVICE_NAME = process.env.OTEL_SERVICE_NAME || "voting-frontend";

const traceExporter = new OTLPTraceExporter({
  url: JAEGER_ENDPOINT,
});

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: SERVICE_NAME,
    [SemanticResourceAttributes.SERVICE_VERSION]: "1.0.0",
    "deployment.environment": process.env.NODE_ENV || "production",
  }),
  spanProcessor: new BatchSpanProcessor(traceExporter),
  instrumentations: [
    getNodeAutoInstrumentations({
      "@opentelemetry/instrumentation-fs": { enabled: false },
      "@opentelemetry/instrumentation-express": { enabled: true },
      "@opentelemetry/instrumentation-http": { enabled: true },
    }),
  ],
});

sdk.start();
console.log(`[tracing] OpenTelemetry initialized for ${SERVICE_NAME} → ${JAEGER_ENDPOINT}`);

process.on("SIGTERM", () => {
  sdk.shutdown()
    .then(() => console.log("[tracing] SDK shut down successfully"))
    .catch((err) => console.error("[tracing] Error shutting down SDK", err))
    .finally(() => process.exit(0));
});
