#!/usr/bin/env bash
# Render every chart for every environment (plus each chart's ci/ values and
# the kustomize overlay) into build/rendered/, one file per release.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${OUT:-build/rendered}
CHARTS=(payment-gateway webhook-relay url-shortener)
ENVS=(dev staging prod)

rm -rf "$OUT"
mkdir -p "$OUT"

for chart in "${CHARTS[@]}"; do
  helm dependency build "charts/$chart" >/dev/null
done

for env in "${ENVS[@]}"; do
  mkdir -p "$OUT/$env"
  for chart in "${CHARTS[@]}"; do
    helm template "$chart" "charts/$chart" \
      --namespace "commerce-$env" \
      --values "environments/$env/$chart.yaml" \
      > "$OUT/$env/$chart.yaml"
  done
done

mkdir -p "$OUT/ci"
for chart in "${CHARTS[@]}"; do
  for values in charts/"$chart"/ci/*.yaml; do
    name=$(basename "$values" .yaml)
    helm template "$chart" "charts/$chart" --namespace commerce-ci --values "$values" \
      > "$OUT/ci/$chart-$name.yaml"
  done
done

mkdir -p "$OUT/kustomize"
for overlay in kustomize/overlays/*/; do
  kubectl kustomize --enable-helm --load-restrictor LoadRestrictionsNone "$overlay" \
    > "$OUT/kustomize/$(basename "$overlay").yaml"
done
# kustomize inflates charts into a local cache next to the base.
rm -rf kustomize/base/charts

find "$OUT" -name '*.yaml' | sort | sed 's/^/rendered /'
