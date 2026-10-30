# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-30

### Added

- Live proof page on GitHub Pages. Each green CI run on `main` publishes its evidence: validation numbers, every end-to-end check against the three services on a kind cluster, the images used and the raw `kubectl` / `helm` output.
- `REPORT_DIR` option for `scripts/e2e-kind.sh` that saves that evidence, and `scripts/build-report.py` (with unit tests, run by `make validate`) that turns it into the page.
- Weekly scheduled CI run (Mondays), so drift in tools, images or schemas is caught without a push.

- CodeQL analysis for GitHub Actions workflows on pushes and pull requests to `main` and on a weekly schedule.
- Dependabot version updates for GitHub Actions, with minor and patch updates grouped per ecosystem.
- README screenshots: `make validate` output and a `helm template` render.
- Roadmap items tracked as GitHub issues under the v0.2.0 milestone.

### Changed

- CI keeps the validation log and the end-to-end evidence as artifacts for 30 days.

## [0.1.0] - 2026-10-25

First public release of k8s-gitops-platform.

### Added

- **Helm library chart** (`platform-lib`) with every workload object a service needs: Deployment, Service, Ingress, HPA (autoscaling/v2 with scale-down damping), PDB, ServiceMonitor, NetworkPolicy, ServiceAccount, ConfigMap/Secret wiring, probes and a `helm test` hook
- **Secure by default**: non-root UID, read-only root filesystem with a size-limited `/tmp`, `allowPrivilegeEscalation: false`, all capabilities dropped, RuntimeDefault seccomp, no service-account token; passes the `restricted` Pod Security Standard (enforced in the e2e namespace)
- **Three app charts** that are 3-line templates plus values: `payment-gateway`, `webhook-relay` (API and a separate delivery-worker Deployment from one chart) and `url-shortener` (with Redis)
- **Demo datastores**: PostgreSQL StatefulSet and Redis Deployment that obey the same security rules and are reachable only from their own release; staging and prod use managed services via `existingSecret`
- **Environments**: `dev`, `staging`, `prod` values with image pins, HPA/PDB, zone spreading, TLS, egress allow-lists; `values.schema.json` per chart rejects bad values before rendering
- **Argo CD**: app-of-apps bootstrap, an `AppProject` with namespace/resource guard rails, RBAC roles and a Friday-evening prod sync window (Asia/Dhaka), and a matrix `ApplicationSet` (charts × environments) with auto-sync for dev/staging and manual prod
- **Policies as code**: 20 Rego rules for single manifests and 5 cross-document rules for whole releases (PDB coverage, HPA targets, dangling Ingress backends, orphan Services), with 39 unit tests and an explicit, reasoned exemption mechanism
- **Kustomize overlay** for an on-prem Dhaka site that consumes the Helm output and patches placement, registry mirror and Redis endpoint
- **Secrets guide** for External Secrets Operator and Sealed Secrets, with validated example manifests, and a policy that blocks plain Secrets in staging/prod renders
- **CI**: `helm lint --strict`, render of every chart × environment, kubeconform against Kubernetes 1.34 and 1.36 plus CRD schemas, conftest, negative checks, and a kind e2e job; a `workflow_dispatch` promotion workflow opens tag-bump PRs

[Unreleased]: https://github.com/AkibUllah/k8s-gitops-platform/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/AkibUllah/k8s-gitops-platform/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/AkibUllah/k8s-gitops-platform/releases/tag/v0.1.0
