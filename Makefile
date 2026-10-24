SHELL := /usr/bin/env bash
CHARTS := payment-gateway webhook-relay url-shortener
export PATH := $(HOME)/.local/bin:$(PATH)

.PHONY: help tools deps lint render kubeconform policy-test policy validate e2e e2e-local demo-up demo-down clean

help: ## list targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## install pinned helm, kubeconform, conftest, kind, kubectl into ~/.local/bin
	./scripts/install-tools.sh

deps: ## vendor the library chart into each app chart
	@for c in $(CHARTS); do helm dependency build charts/$$c >/dev/null; done

lint: deps ## helm lint --strict for every chart and environment
	@for c in $(CHARTS); do for e in dev staging prod; do \
	  helm lint --strict --quiet charts/$$c -n commerce-$$e -f environments/$$e/$$c.yaml >/dev/null && echo "ok  $$c ($$e)"; \
	done; done

render: ## render all releases into build/rendered
	./scripts/render.sh

kubeconform: render ## validate rendered manifests against Kubernetes and CRD schemas
	kubeconform -strict -summary -kubernetes-version 1.36.4 \
	  -schema-location default \
	  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	  build/rendered argocd docs/examples

policy-test: ## run the Rego unit tests
	conftest verify --policy policies

policy: render ## run the policies against every rendered release
	conftest test --policy policies build/rendered
	@for f in build/rendered/*/*.yaml; do conftest test --combine --namespace combined --policy policies --no-color $$f >/dev/null || exit 1; done
	@echo "cross-document policies passed"

validate: ## everything CI runs except e2e
	./scripts/validate.sh

e2e: ## kind cluster, images built from the GitHub repos, install, test, delete
	./scripts/e2e-kind.sh

e2e-local: ## same, building images from sibling checkouts (../<repo>)
	IMAGE_SOURCE=local SOURCES_DIR=.. ./scripts/e2e-kind.sh

demo-up: ## e2e but keep the cluster running for exploration
	KEEP_CLUSTER=1 ./scripts/e2e-kind.sh

demo-down: ## delete the demo cluster
	kind delete cluster --name gitops-e2e

clean:
	rm -rf build charts/*/charts kustomize/base/charts
