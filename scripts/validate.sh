#!/usr/bin/env bash
# Full offline-capable validation (schemas are fetched once and cached):
#   1. helm lint --strict for every chart x environment
#   2. render everything (scripts/render.sh)
#   3. kubeconform: Kubernetes + CRD schemas, strict, for each target version
#   4. conftest: policy unit tests, per-document rules, cross-document rules
#   5. negative checks: things that must be rejected are rejected
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSIONS=${K8S_VERSIONS:-"1.34.11 1.36.4"}
CHARTS=(payment-gateway webhook-relay url-shortener)
ENVS=(dev staging prod)
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
CACHE=${KUBECONFORM_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform}
mkdir -p "$CACHE"

step() { printf '\n==> %s\n' "$*"; }

step "helm lint"
for chart in "${CHARTS[@]}"; do
  helm dependency build "charts/$chart" >/dev/null
  for env in "${ENVS[@]}"; do
    helm lint --strict --quiet "charts/$chart" --namespace "commerce-$env" \
      --values "environments/$env/$chart.yaml" >/dev/null
    echo "ok  $chart ($env)"
  done
done

step "render"
./scripts/render.sh | sed 's/^/  /'

for v in $K8S_VERSIONS; do
  step "kubeconform (Kubernetes $v)"
  kubeconform -strict -summary -kubernetes-version "$v" -cache "$CACHE" \
    -schema-location default -schema-location "$CRD_SCHEMAS" \
    build/rendered argocd docs/examples
done

step "conftest verify (policy unit tests)"
conftest verify --policy policies

step "conftest: per-document rules"
conftest test --policy policies --namespace main build/rendered

step "conftest: cross-document rules (one release at a time)"
for f in build/rendered/*/*.yaml; do
  conftest test --combine --policy policies --namespace combined --no-color "$f" >/dev/null \
    || { conftest test --combine --policy policies --namespace combined "$f"; exit 1; }
  echo "ok  $f"
done

step "negative checks"
if helm template x charts/payment-gateway --set image.tag=latest >/dev/null 2>&1; then
  echo "FAIL: image.tag=latest rendered" && exit 1
fi
echo "ok  image.tag=latest is rejected at render time"
if conftest test --policy policies policies/fixtures/noncompliant.yaml >/dev/null 2>&1; then
  echo "FAIL: noncompliant fixture passed the policies" && exit 1
fi
echo "ok  policies/fixtures/noncompliant.yaml is rejected"
if helm template x charts/url-shortener --set replicaCount=-1 >/dev/null 2>&1; then
  echo "FAIL: values schema accepted replicaCount=-1" && exit 1
fi
echo "ok  values.schema.json rejects invalid values"

printf '\nAll validation passed.\n'
