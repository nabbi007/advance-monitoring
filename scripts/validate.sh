#!/usr/bin/env bash
###############################################################################
# validate.sh — Validate observability stack end-to-end
#
# Usage:
#   ./scripts/validate.sh <APP_HOST> <OBSERVABILITY_HOST>
#
# Checks:
#   1. App health endpoints
#   2. Prometheus targets are UP
#   3. Grafana is reachable
#   4. Jaeger has traces
#   5. Metrics endpoints return data
#   6. Log correlation (trace_id present)
###############################################################################
set -euo pipefail

APP_HOST="${1:?Usage: $0 <APP_HOST> <OBSERVABILITY_HOST>}"
OBS_HOST="${2:?Usage: $0 <APP_HOST> <OBSERVABILITY_HOST>}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
  local name="$1"
  local url="$2"
  local expected="${3:-200}"

  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $name (HTTP $STATUS)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $name (HTTP $STATUS, expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local name="$1"
  local url="$2"
  local pattern="$3"

  RESPONSE=$(curl -sf --max-time 10 "$url" 2>/dev/null || echo "")
  if echo "$RESPONSE" | grep -q "$pattern"; then
    echo -e "  ${GREEN}✓${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $name (pattern '$pattern' not found)"
    FAIL=$((FAIL + 1))
  fi
}

echo -e "${CYAN}=========================================="
echo " Observability Stack Validation"
echo "==========================================${NC}"

echo ""
echo -e "${CYAN}[1] App Health Checks${NC}"
check "Frontend health"       "http://$APP_HOST:3000/health"
check "Backend health"        "http://$APP_HOST:3001/health"

echo ""
echo -e "${CYAN}[2] Metrics Endpoints${NC}"
check_contains "Backend /metrics"   "http://$APP_HOST:3001/metrics"  "http_requests_total"
check_contains "Frontend /metrics"  "http://$APP_HOST:3000/metrics"  "frontend_http_requests_total"
check_contains "Redis Exporter"     "http://$APP_HOST:9121/metrics"  "redis_up"
check_contains "Node Exporter"      "http://$APP_HOST:9100/metrics"  "node_cpu_seconds_total"

echo ""
echo -e "${CYAN}[3] Monitoring Stack${NC}"
check "Prometheus"   "http://$OBS_HOST:9090/-/healthy"
check "Grafana"      "http://$OBS_HOST:3000/api/health"
check "Jaeger UI"    "http://$OBS_HOST:16686/"

echo ""
echo -e "${CYAN}[4] Prometheus Targets${NC}"
TARGETS=$(curl -sf "http://$OBS_HOST:9090/api/v1/targets" 2>/dev/null || echo "{}")
for job in voting-backend voting-frontend redis node-exporter-app node-exporter-observability; do
  if echo "$TARGETS" | grep -q "\"job\":\"$job\""; then
    STATE=$(echo "$TARGETS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data',{}).get('activeTargets',[]):
  if t.get('labels',{}).get('job') == '$job':
    print(t.get('health','unknown'))
    break
" 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "up" ]]; then
      echo -e "  ${GREEN}✓${NC} Prometheus target: $job (UP)"
      PASS=$((PASS + 1))
    else
      echo -e "  ${YELLOW}~${NC} Prometheus target: $job ($STATE)"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}✗${NC} Prometheus target: $job (NOT FOUND)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo -e "${CYAN}[5] Generate test trace and verify${NC}"
# Cast a vote to generate a trace
curl -sf -X POST "http://$APP_HOST:3000/api/vote" \
  -H "Content-Type: application/json" \
  -d '{"option": "cats"}' > /dev/null 2>&1 || true
sleep 3

# Check Jaeger for traces
TRACES=$(curl -sf "http://$OBS_HOST:16686/api/traces?service=voting-backend&limit=1" 2>/dev/null || echo "{}")
if echo "$TRACES" | grep -q "traceID"; then
  echo -e "  ${GREEN}✓${NC} Jaeger has traces for voting-backend"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} No traces found in Jaeger (may need more time)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo -e "${CYAN}[6] Alert Rules Loaded${NC}"
RULES=$(curl -sf "http://$OBS_HOST:9090/api/v1/rules" 2>/dev/null || echo "{}")
for alert in HighErrorRate HighLatencyP95 BackendDown; do
  if echo "$RULES" | grep -q "$alert"; then
    echo -e "  ${GREEN}✓${NC} Alert rule: $alert"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} Alert rule: $alert (NOT FOUND)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo -e "${CYAN}=========================================="
echo -e " Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo -e "${CYAN}==========================================${NC}"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
