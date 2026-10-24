#!/usr/bin/env bash
# Install the pinned toolchain into $BIN_DIR (default ~/.local/bin) without
# sudo, verifying every download against the publisher's checksum.
# Used by CI, the devcontainer and local setup: `make tools`.
set -euo pipefail

HELM_VERSION=${HELM_VERSION:-v3.22.0}
KUBECONFORM_VERSION=${KUBECONFORM_VERSION:-v0.8.0}
CONFTEST_VERSION=${CONFTEST_VERSION:-0.71.0}
KIND_VERSION=${KIND_VERSION:-v0.33.0}
KUBECTL_VERSION=${KUBECTL_VERSION:-v1.36.4}

BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
OS=linux
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

if ! "$BIN_DIR/helm" version --short 2>/dev/null | grep -q "^${HELM_VERSION}+"; then
  f="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  fetch "https://get.helm.sh/$f" "$f"
  fetch "https://get.helm.sh/$f.sha256sum" "$f.sha256sum"
  sha256sum -c "$f.sha256sum"
  tar xzf "$f" && install -m 0755 "${OS}-${ARCH}/helm" "$BIN_DIR/helm"
fi

if ! "$BIN_DIR/kubeconform" -v 2>/dev/null | grep -q "^${KUBECONFORM_VERSION}$"; then
  f="kubeconform-${OS}-${ARCH}.tar.gz"
  base="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}"
  fetch "$base/$f" "$f"
  fetch "$base/CHECKSUMS" CHECKSUMS
  grep " $f\$" CHECKSUMS | sha256sum -c
  tar xzf "$f" kubeconform && install -m 0755 kubeconform "$BIN_DIR/kubeconform"
fi

if ! "$BIN_DIR/conftest" --version 2>/dev/null | grep -q "Conftest: ${CONFTEST_VERSION}$"; then
  carch=$([[ "$ARCH" == amd64 ]] && echo x86_64 || echo arm64)
  f="conftest_${CONFTEST_VERSION}_Linux_${carch}.tar.gz"
  base="https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}"
  fetch "$base/$f" "$f"
  fetch "$base/checksums.txt" checksums.txt
  grep " $f\$" checksums.txt | sha256sum -c
  tar xzf "$f" conftest && install -m 0755 conftest "$BIN_DIR/conftest"
fi

if ! "$BIN_DIR/kind" version 2>/dev/null | grep -q "kind ${KIND_VERSION} "; then
  base="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  fetch "$base/kind-${OS}-${ARCH}" kind
  echo "$(curl -fsSL "$base/kind-${OS}-${ARCH}.sha256sum" | cut -d' ' -f1)  kind" | sha256sum -c
  install -m 0755 kind "$BIN_DIR/kind"
fi

if ! "$BIN_DIR/kubectl" version --client 2>/dev/null | grep -q "Client Version: ${KUBECTL_VERSION}$"; then
  base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  fetch "$base/kubectl" kubectl
  echo "$(curl -fsSL "$base/kubectl.sha256")  kubectl" | sha256sum -c
  install -m 0755 kubectl "$BIN_DIR/kubectl"
fi

echo "tools in $BIN_DIR:"
"$BIN_DIR/helm" version --short
echo "kubeconform $("$BIN_DIR/kubeconform" -v)"
"$BIN_DIR/conftest" --version | head -1
"$BIN_DIR/kind" version
"$BIN_DIR/kubectl" version --client | head -1
