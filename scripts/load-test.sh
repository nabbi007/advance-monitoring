#!/usr/bin/env bash
###############################################################################
# load-test.sh — Generate load and errors to validate observability stack
#
# Usage:
#   ./scripts/load-test.sh <APP_HOST> [duration_seconds]
#
# Example:
#   ./scripts/load-test.sh 54.123.45.67 120
#
# Generates:
#   - Normal voting traffic (cats/dogs alternating)
#   - Bursts of simulated errors (500s)
#   - Bursts of simulated latency (slow requests)
#   - Parallel connections for load
###############################################################################
set -euo pipefail

APP_HOST="${1:?Usage: $0 <APP_HOST> [duration_seconds]}"
DURATION="${2:-120}"
BACKEND_URL="http://$APP_HOST:3001"
FRONTEND_URL="http://$APP_HOST:3000"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[load-test]${NC} $*"; }
warn() { echo -e "${YELLOW}[load-test]${NC} $*"; }

log "=========================================="
log " Load Test — Target: $APP_HOST"
log " Duration: ${DURATION}s"
log "=========================================="

# -------------------------------------------------------------------
#  Phase 1: Warm-up — normal traffic (30% of duration)
# -------------------------------------------------------------------
WARMUP=$((DURATION * 30 / 100))
log "Phase 1: Warm-up traffic (${WARMUP}s)..."

END_TIME=$((SECONDS + WARMUP))
REQUEST_COUNT=0

while [[ $SECONDS -lt $END_TIME ]]; do
  # Alternate between cats and dogs
  for option in cats dogs; do
    curl -sf -X POST "$BACKEND_URL/api/vote" \
      -H "Content-Type: application/json" \
      -d "{\"option\": \"$option\"}" > /dev/null 2>&1 &
    REQUEST_COUNT=$((REQUEST_COUNT + 1))
  done

  # Read results
  curl -sf "$BACKEND_URL/api/results" > /dev/null 2>&1 &
  curl -sf "$FRONTEND_URL/api/votes" > /dev/null 2>&1 &
  REQUEST_COUNT=$((REQUEST_COUNT + 2))

  sleep 0.5
done
wait 2>/dev/null || true
log "Phase 1 complete: ~$REQUEST_COUNT requests sent."

# -------------------------------------------------------------------
#  Phase 2: Error burst — generate 500 errors (20% of duration)
# -------------------------------------------------------------------
ERROR_DURATION=$((DURATION * 20 / 100))
log "Phase 2: Error burst (${ERROR_DURATION}s) — simulating 500 errors..."

END_TIME=$((SECONDS + ERROR_DURATION))
ERROR_COUNT=0

while [[ $SECONDS -lt $END_TIME ]]; do
  # Mix of normal and error requests
  curl -sf "$BACKEND_URL/api/simulate/error" > /dev/null 2>&1 &
  curl -sf "$BACKEND_URL/api/simulate/error" > /dev/null 2>&1 &
  curl -sf "$BACKEND_URL/api/simulate/error" > /dev/null 2>&1 &

  # Some normal traffic too
  curl -sf -X POST "$BACKEND_URL/api/vote" \
    -H "Content-Type: application/json" \
    -d '{"option": "cats"}' > /dev/null 2>&1 &

  # Invalid vote (400 error)
  curl -sf -X POST "$BACKEND_URL/api/vote" \
    -H "Content-Type: application/json" \
    -d '{"option": "invalid_option"}' > /dev/null 2>&1 &

  ERROR_COUNT=$((ERROR_COUNT + 5))
  sleep 0.3
done
wait 2>/dev/null || true
log "Phase 2 complete: ~$ERROR_COUNT requests (mix of errors + normal)."

# -------------------------------------------------------------------
#  Phase 3: Latency burst — generate slow requests (20% of duration)
# -------------------------------------------------------------------
LATENCY_DURATION=$((DURATION * 20 / 100))
log "Phase 3: Latency burst (${LATENCY_DURATION}s) — simulating slow responses..."

END_TIME=$((SECONDS + LATENCY_DURATION))
SLOW_COUNT=0

while [[ $SECONDS -lt $END_TIME ]]; do
  curl -sf "$BACKEND_URL/api/simulate/latency" > /dev/null 2>&1 &
  curl -sf "$BACKEND_URL/api/simulate/latency" > /dev/null 2>&1 &

  # Normal traffic alongside
  curl -sf -X POST "$BACKEND_URL/api/vote" \
    -H "Content-Type: application/json" \
    -d '{"option": "dogs"}' > /dev/null 2>&1 &

  SLOW_COUNT=$((SLOW_COUNT + 3))
  sleep 0.5
done
wait 2>/dev/null || true
log "Phase 3 complete: ~$SLOW_COUNT requests (mix of slow + normal)."

# -------------------------------------------------------------------
#  Phase 4: Sustained mixed traffic (remaining duration)
# -------------------------------------------------------------------
MIXED_DURATION=$((DURATION * 30 / 100))
log "Phase 4: Sustained mixed traffic (${MIXED_DURATION}s)..."

END_TIME=$((SECONDS + MIXED_DURATION))
MIXED_COUNT=0

while [[ $SECONDS -lt $END_TIME ]]; do
  # Parallel burst of 10 requests
  for i in $(seq 1 10); do
    option=$([[ $((i % 2)) -eq 0 ]] && echo "cats" || echo "dogs")
    curl -sf -X POST "$BACKEND_URL/api/vote" \
      -H "Content-Type: application/json" \
      -d "{\"option\": \"$option\"}" > /dev/null 2>&1 &
  done
  curl -sf "$FRONTEND_URL/api/results" > /dev/null 2>&1 &
  MIXED_COUNT=$((MIXED_COUNT + 11))

  sleep 0.2
done
wait 2>/dev/null || true
log "Phase 4 complete: ~$MIXED_COUNT requests."

# -------------------------------------------------------------------
#  Summary
# -------------------------------------------------------------------
TOTAL=$((REQUEST_COUNT + ERROR_COUNT + SLOW_COUNT + MIXED_COUNT))
log ""
log "=========================================="
log " Load Test Complete!"
log "=========================================="
log " Total requests: ~$TOTAL"
log " Duration:       ${DURATION}s"
log ""
log " Now check:"
log "   Grafana  → error rate & latency spikes"
log "   Jaeger   → trace spans for slow/failed requests"
log "   Logs     → trace_id correlation"
log "=========================================="
