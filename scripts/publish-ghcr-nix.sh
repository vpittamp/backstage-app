#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

usage() {
  cat <<'EOF'
Build a fully Nix-reproducible Backstage OCI image and push it to GitHub Container Registry (GHCR).

This script:
  - Builds Backstage (Yarn Berry + offline cache) as a Nix derivation
  - Builds an OCI (docker-archive) image with nixpkgs dockerTools
  - Pushes the image with skopeo to GHCR
  - Triggers Kargo warehouse refresh for auto-promotion

Requirements:
  - GITHUB_TOKEN or GITHUB_PAT environment variable with packages:write scope
  - Or kubectl access to read the secret from the cluster

Defaults:
  - Registry: ghcr.io
  - Image:    ghcr.io/vpittamp/backstage-app
  - Tags:     <version>, latest

Environment overrides:
  GITHUB_OWNER            (default: vpittamp)
  IMAGE_NAME              (default: backstage-app)
  VERSION                 (required: semver like 1.2.3 or v1.2.3)
  GITHUB_TOKEN            GitHub token with packages:write scope
  GITHUB_PAT              Alternative to GITHUB_TOKEN

  KARGO_REFRESH           (default: 1)
  KARGO_NAMESPACE         (default: kargo-pipelines)
  KARGO_WAREHOUSE         (default: backstage-ghcr)

Examples:
  VERSION=1.2.0 ./scripts/publish-ghcr-nix.sh
  VERSION=v1.2.0 GITHUB_TOKEN=ghp_xxx ./scripts/publish-ghcr-nix.sh

EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

need jq
need nix
need skopeo

GITHUB_OWNER="${GITHUB_OWNER:-vpittamp}"
IMAGE_NAME="${IMAGE_NAME:-backstage-app}"
VERSION="${VERSION:-}"

KARGO_REFRESH="${KARGO_REFRESH:-1}"
KARGO_NAMESPACE="${KARGO_NAMESPACE:-kargo-pipelines}"
KARGO_WAREHOUSE="${KARGO_WAREHOUSE:-backstage-ghcr}"

# Validate VERSION
if [[ -z "$VERSION" ]]; then
  die "VERSION is required. Set VERSION=1.2.3 or VERSION=v1.2.3"
fi

# Normalize version (strip leading 'v' for consistency, add it back for tag)
VERSION_NUM="${VERSION#v}"
VERSION_TAG="v${VERSION_NUM}"

# Validate semver format
if ! [[ "$VERSION_NUM" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "VERSION must be semver format (e.g., 1.2.3 or v1.2.3), got: $VERSION"
fi

# Get GitHub credentials (in order of preference)
echo "Getting GitHub credentials..."
GITHUB_USER="${GITHUB_OWNER}"
GITHUB_PASS=""

# 1. Environment variables (highest priority)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "  Using GITHUB_TOKEN environment variable"
  GITHUB_PASS="$GITHUB_TOKEN"
elif [[ -n "${GITHUB_PAT:-}" ]]; then
  echo "  Using GITHUB_PAT environment variable"
  GITHUB_PASS="$GITHUB_PAT"
fi

# 2. 1Password CLI (preferred for PATs with proper scopes)
if [[ -z "$GITHUB_PASS" ]] && command -v op >/dev/null 2>&1; then
  echo "  Trying 1Password CLI..."
  # Try common item names for GitHub tokens (in order of preference)
  for item_spec in "Github Personal Access Token:token" "GitHub PAT:token" "GitHub Token:token" "github.com:password"; do
    item="${item_spec%%:*}"
    field="${item_spec##*:}"
    GITHUB_PASS="$(op item get "$item" --fields "$field" --reveal 2>/dev/null || true)"
    if [[ -n "$GITHUB_PASS" ]]; then
      echo "  Using token from 1Password item: $item (field: $field)"
      break
    fi
  done
fi

# 3. Kubernetes secret
if [[ -z "$GITHUB_PASS" ]] && command -v kubectl >/dev/null 2>&1; then
  echo "  Trying kubectl secret kargo-ghcr-backstage-credentials..."
  GITHUB_PASS="$(kubectl get secret kargo-ghcr-backstage-credentials -n kargo-pipelines -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$GITHUB_PASS" ]] && echo "  Using credentials from kargo-pipelines secret"
fi

# 4. gh CLI (last resort - may not have write:packages scope)
if [[ -z "$GITHUB_PASS" ]] && command -v gh >/dev/null 2>&1; then
  echo "  Trying gh auth token..."
  GITHUB_PASS="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$GITHUB_PASS" ]]; then
    echo "  Using gh CLI token (ensure 'write:packages' scope is enabled)"
    GH_USER="$(gh api user --jq '.login' 2>/dev/null || true)"
    [[ -n "$GH_USER" ]] && GITHUB_USER="$GH_USER"
  fi
fi

[[ -n "$GITHUB_PASS" ]] || die "No GitHub credentials found. Options:
  1. Set GITHUB_TOKEN or GITHUB_PAT environment variable
  2. Run 'gh auth login' with write:packages scope
  3. Create kubectl secret: kubectl create secret generic kargo-ghcr-backstage-credentials -n kargo-pipelines --from-literal=password=ghp_xxx
  4. Store token in 1Password as 'GitHub' or 'GitHub Token'"

IMAGE_REPO="ghcr.io/${GITHUB_OWNER}/${IMAGE_NAME}"

echo "Target image repo: ${IMAGE_REPO}"
echo "Version: ${VERSION_TAG}"

echo "Building Nix OCI image (docker-archive)..."
IMAGE_TAR="$(nix build ./nix#backstageImage --no-link --print-out-paths)"
[[ -n "$IMAGE_TAR" ]] || die "nix build did not return an output path"
[[ -f "$IMAGE_TAR" ]] || die "Expected image tarball at: $IMAGE_TAR"

SRC_IMAGE="docker-archive:${IMAGE_TAR}:backstage-app:latest"

echo "Pushing image tags to GHCR..."
echo "  -> ${IMAGE_REPO}:${VERSION_TAG}"
skopeo copy \
  --dest-creds "${GITHUB_USER}:${GITHUB_PASS}" \
  "${SRC_IMAGE}" \
  "docker://${IMAGE_REPO}:${VERSION_TAG}"

echo "  -> ${IMAGE_REPO}:latest (tagging from ${VERSION_TAG})"
skopeo copy \
  --src-creds "${GITHUB_USER}:${GITHUB_PASS}" \
  --dest-creds "${GITHUB_USER}:${GITHUB_PASS}" \
  "docker://${IMAGE_REPO}:${VERSION_TAG}" \
  "docker://${IMAGE_REPO}:latest"

echo ""
echo "Pushed:"
echo "  - ${IMAGE_REPO}:${VERSION_TAG}"
echo "  - ${IMAGE_REPO}:latest"

if [[ "$KARGO_REFRESH" == "1" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    echo ""
    echo "Triggering Kargo warehouse refresh..."

    if kubectl get warehouse "${KARGO_WAREHOUSE}" -n "${KARGO_NAMESPACE}" >/dev/null 2>&1; then
      kubectl annotate warehouse "${KARGO_WAREHOUSE}" \
        -n "${KARGO_NAMESPACE}" \
        "kargo.akuity.io/refresh=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --overwrite >/dev/null
      echo "Refresh requested for ${KARGO_NAMESPACE}/${KARGO_WAREHOUSE}"
      echo ""
      echo "Watch promotion with:"
      echo "  kubectl get freight,stages,promotions -n ${KARGO_NAMESPACE} -w"
    else
      echo "Warehouse ${KARGO_WAREHOUSE} not found in ${KARGO_NAMESPACE}"
    fi
  else
    echo "kubectl not found; skipping Kargo refresh"
  fi
fi

echo ""
echo "Done! Image published to GHCR."
echo "Kargo will auto-promote to backstage-dev stage."
