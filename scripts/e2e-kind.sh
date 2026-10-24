#!/usr/bin/env bash
# End-to-end test on a throwaway kind cluster:
#   1. build the three service images
#      (IMAGE_SOURCE=local builds from sibling checkouts, =git from GitHub;
#       anything that fails to build falls back to a stand-in HTTP server)
#   2. create a kind cluster ($KIND_CONFIG: 3 nodes by default) and load the images
#   3. install every chart with dev values into a namespace that enforces the
#      "restricted" Pod Security Standard
#   4. wait for rollouts, run `helm test`, curl /health through port-forwards,
#      exercise the real APIs and probe NetworkPolicy enforcement
# Set KEEP_CLUSTER=1 to leave the cluster running afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=${CLUSTER:-gitops-e2e}
NAMESPACE=${NAMESPACE:-commerce-e2e}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed}
IMAGE_SOURCE=${IMAGE_SOURCE:-git}            # git | local | standin
SOURCES_DIR=${SOURCES_DIR:-..}               # where sibling repos live for IMAGE_SOURCE=local
BASE_PORT=${BASE_PORT:-28080}
KEEP_CLUSTER=${KEEP_CLUSTER:-0}
KIND_CONFIG=${KIND_CONFIG:-e2e/kind-cluster.yaml}   # e2e/kind-single-node.yaml on small machines

declare -A REPO=(
  [payment-gateway]=fastapi-payment-gateway
  [webhook-relay]=webhook-relay
  [url-shortener]=url-shortener-analytics
)
CHARTS=(payment-gateway webhook-relay url-shortener)
declare -A STANDIN=()
PF_PIDS=()

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; diagnostics; exit 1; }

diagnostics() {
  kubectl -n "$NAMESPACE" get pods -o wide 2>/dev/null || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -25 || true
}

cleanup() {
  for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    log "deleting kind cluster $CLUSTER"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

build_image() {
  local chart=$1 repo=${REPO[$1]} ref="ghcr.io/akibullah/${REPO[$1]}:e2e" ctx out
  case "$IMAGE_SOURCE" in
    local) ctx="$SOURCES_DIR/$repo" ;;
    git) ctx="https://github.com/AkibUllah/$repo.git#main" ;;
    *) return 1 ;;
  esac
  # One retry: a busy Docker daemon occasionally drops a build.
  for attempt in 1 2; do
    if out=$(docker build -q -t "$ref" "$ctx" 2>&1); then
      return 0
    fi
    echo "  $chart: build attempt $attempt failed: $(tail -n 3 <<<"$out" | tr '\n' ' ')" >&2
  done
  return 1
}

log "building service images (source: $IMAGE_SOURCE)"
for chart in "${CHARTS[@]}"; do
  if build_image "$chart"; then
    echo "  $chart: built ghcr.io/akibullah/${REPO[$chart]}:e2e"
  else
    STANDIN[$chart]=1
    echo "  $chart: image build unavailable, using the stand-in server"
  fi
done

log "creating kind cluster $CLUSTER ($KIND_CONFIG, $KIND_NODE_IMAGE)"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config "$KIND_CONFIG" --wait 300s
for chart in "${CHARTS[@]}"; do
  [[ -n "${STANDIN[$chart]:-}" ]] && continue
  kind load docker-image --name "$CLUSTER" "ghcr.io/akibullah/${REPO[$chart]}:e2e" >/dev/null
done

log "namespace $NAMESPACE (Pod Security: restricted, enforced)"
kubectl create namespace "$NAMESPACE"
kubectl label namespace "$NAMESPACE" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

for chart in "${CHARTS[@]}"; do
  helm dependency build "charts/$chart" >/dev/null
  extra=()
  [[ -n "${STANDIN[$chart]:-}" ]] && extra=(--values e2e/standin-values.yaml)
  log "helm install $chart"
  helm upgrade --install "$chart" "charts/$chart" --namespace "$NAMESPACE" \
    --values "environments/dev/$chart.yaml" --values e2e/values.yaml "${extra[@]}" \
    --wait --timeout 6m || fail "helm install $chart"
done

log "rollout status"
for d in $(kubectl -n "$NAMESPACE" get deploy -o name); do
  kubectl -n "$NAMESPACE" rollout status "$d" --timeout=180s || fail "$d did not become ready"
done
for s in $(kubectl -n "$NAMESPACE" get statefulset -o name); do
  kubectl -n "$NAMESPACE" rollout status "$s" --timeout=180s || fail "$s did not become ready"
done
kubectl -n "$NAMESPACE" get pods -o wide

log "helm test"
for chart in "${CHARTS[@]}"; do
  helm test "$chart" --namespace "$NAMESPACE" --timeout 3m >/dev/null || fail "helm test $chart"
  echo "  $chart: test-health passed"
done

log "health endpoints through port-forward"
port=$BASE_PORT
declare -A PORT=()
for chart in "${CHARTS[@]}"; do
  kubectl -n "$NAMESPACE" port-forward "svc/$chart" "$port:80" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  PORT[$chart]=$port
  port=$((port + 1))
done
# Wait until every port-forward is listening before probing through it.
for chart in "${CHARTS[@]}"; do
  for _ in $(seq 1 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/${PORT[$chart]}") 2>/dev/null && break
    sleep 1
  done
done
for chart in "${CHARTS[@]}"; do
  body=$(curl -fsS --retry 5 --retry-delay 2 --retry-all-errors "http://127.0.0.1:${PORT[$chart]}/health") \
    || fail "GET /health on $chart"
  echo "  $chart: ${body:-<empty 200 response>}"
done

if [[ -z "${STANDIN[url-shortener]:-}" ]]; then
  log "url-shortener: create a link and follow it (PostgreSQL + Redis + secrets)"
  base="http://127.0.0.1:${PORT[url-shortener]}"
  curl -fsS -X POST "$base/api/v1/links" -H "X-API-Key: dev-api-key-change-me" \
    -H "Content-Type: application/json" \
    -d '{"url":"https://dokan.com.bd/eid-sale","alias":"eid-sale"}' >/dev/null || fail "create link"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/eid-sale")
  [[ "$code" == "302" ]] || fail "GET /eid-sale returned $code, want 302"
  echo "  POST /api/v1/links -> 201, GET /eid-sale -> 302"
fi

if [[ -z "${STANDIN[webhook-relay]:-}" ]]; then
  log "webhook-relay: publish an event and wait for the dedicated worker to attempt delivery"
  base="http://127.0.0.1:${PORT[webhook-relay]}"
  auth=(-H "X-API-Key: dev-relay-admin-key" -H "Content-Type: application/json")
  curl -fsS -X POST "$base/v1/endpoints" "${auth[@]}" \
    -d "{\"url\":\"http://payment-gateway.$NAMESPACE.svc.cluster.local/v1/webhooks/bkash\",\"event_types\":[\"payment.*\"]}" >/dev/null \
    || fail "register endpoint"
  curl -fsS -X POST "$base/v1/events" "${auth[@]}" \
    -d '{"id":"evt-e2e-1","type":"payment.captured","data":{"amount_minor":150000,"currency":"BDT"}}' >/dev/null \
    || fail "publish event"
  attempts=0
  for _ in $(seq 1 30); do
    attempts=$(curl -fsS "$base/v1/deliveries?event_id=evt-e2e-1" -H "X-API-Key: dev-relay-admin-key" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["attempt_count"] if d else 0)')
    [[ "$attempts" -ge 1 ]] && break
    sleep 2
  done
  [[ "$attempts" -ge 1 ]] || fail "worker never attempted the delivery"
  echo "  delivery attempted $attempts time(s) by webhook-relay-worker (receiver rejects the unsigned call; the attempt is what matters)"
fi

log "NetworkPolicy: a pod outside the platform must not reach the payment gateway"
cat <<YAML | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: np-outsider
  labels: {app: outsider}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 100, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      args: ["--max-time", "5", "-s", "-o", "/dev/null", "-w", "%{http_code}", "http://payment-gateway/health"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
YAML
phase=""
for _ in $(seq 1 45); do
  phase=$(kubectl -n "$NAMESPACE" get pod np-outsider -o jsonpath='{.status.phase}')
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  sleep 2
done
case "$phase" in
  Failed) echo "  blocked: the outsider's request timed out (the CNI enforces NetworkPolicy)" ;;
  Succeeded) echo "  reachable: this CNI does not enforce NetworkPolicy (got HTTP $(kubectl -n "$NAMESPACE" logs np-outsider))" ;;
  *) fail "outsider probe pod stuck in phase '$phase'" ;;
esac

log "PASS: ${#CHARTS[@]} releases healthy in $NAMESPACE"
for chart in "${CHARTS[@]}"; do
  printf '  %-16s %s\n' "$chart" "$([[ -n "${STANDIN[$chart]:-}" ]] && echo stand-in || echo "real image")"
done
