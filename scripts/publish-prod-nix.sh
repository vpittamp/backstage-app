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
Build a fully Nix-reproducible Backstage OCI image and push it to the idpbuilder Gitea OCI registry.

This path avoids Docker entirely:
  - Builds Backstage (Yarn Berry + offline cache) as a Nix derivation
  - Builds an OCI (docker-archive) image with nixpkgs dockerTools
  - Pushes the image with skopeo to the Gitea registry
  - Triggers Kargo warehouse refresh (optional) and waits for auto-promotion (optional)

Defaults target the local CNOE cluster:
  - Registry: gitea.cnoe.localtest.me:8443
  - Image:    gitea.cnoe.localtest.me:8443/giteaadmin/backstage-app
  - Tags:     latest, dev-YYYYMMDD-HHMMSS[-<sha7>]

Environment overrides:
  REGISTRY_HOST           (default: gitea.cnoe.localtest.me:8443)
  REGISTRY_NAMESPACE      (default: giteaadmin)
  IMAGE_NAME              (default: backstage-app)
  REGISTRY_TLS_VERIFY     (default: false  # allow self-signed when false)

  KARGO_REFRESH           (default: 1)
  KARGO_NAMESPACE         (default: kargo-pipelines)
  KARGO_WAREHOUSE         (optional; if unset, auto-detect by image repoURL)
  KARGO_WAIT              (default: 0)
  KARGO_STAGE             (required if KARGO_WAIT=1; e.g. backstage-local-dev)
  KARGO_TIMEOUT_SECONDS   (default: 300)

EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

need jq
need nix
need skopeo

REGISTRY_HOST="${REGISTRY_HOST:-gitea.cnoe.localtest.me:8443}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-giteaadmin}"
IMAGE_NAME="${IMAGE_NAME:-backstage-app}"

REGISTRY_TLS_VERIFY="${REGISTRY_TLS_VERIFY:-false}"

KARGO_REFRESH="${KARGO_REFRESH:-1}"
KARGO_NAMESPACE="${KARGO_NAMESPACE:-kargo-pipelines}"
KARGO_WAREHOUSE="${KARGO_WAREHOUSE:-}"
KARGO_WAIT="${KARGO_WAIT:-0}"
KARGO_STAGE="${KARGO_STAGE:-}"
KARGO_TIMEOUT_SECONDS="${KARGO_TIMEOUT_SECONDS:-300}"

if [[ "$REGISTRY_TLS_VERIFY" != "true" && "$REGISTRY_TLS_VERIFY" != "false" ]]; then
  die "REGISTRY_TLS_VERIFY must be 'true' or 'false', got: $REGISTRY_TLS_VERIFY"
fi

IMAGE_REPO="${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}"

echo "Getting Gitea credentials..."
if command -v idpbuilder >/dev/null 2>&1; then
  GITEA_JSON="$(idpbuilder get secrets -p gitea -o json)"
  GITEA_USER="$(jq -r '.[0].username // empty' <<<"$GITEA_JSON")"
  GITEA_PASS="$(jq -r '.[0].token // .[0].password // empty' <<<"$GITEA_JSON")"
elif command -v kubectl >/dev/null 2>&1; then
  GITEA_USER="$(kubectl get secret gitea-credential -n gitea -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
  GITEA_PASS="$(kubectl get secret gitea-credential -n gitea -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
else
  die "Need either idpbuilder or kubectl to obtain Gitea credentials"
fi

[[ -n "$GITEA_USER" ]] || die "Failed to parse Gitea username from idpbuilder output"
[[ -n "$GITEA_PASS" ]] || die "Failed to parse Gitea token/password from idpbuilder output"

GIT_SHA=""
if command -v git >/dev/null 2>&1; then
  GIT_SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
if [[ -n "$GIT_SHA" ]]; then
  TAG_DEV="dev-${TS}-${GIT_SHA}"
else
  TAG_DEV="dev-${TS}"
fi

echo "Target image repo: ${IMAGE_REPO}"
echo "Tags: latest, ${TAG_DEV}"

echo "Building Nix OCI image (docker-archive)..."
IMAGE_TAR="$(nix build ./nix#backstageImage --no-link --print-out-paths)"
[[ -n "$IMAGE_TAR" ]] || die "nix build did not return an output path"
[[ -f "$IMAGE_TAR" ]] || die "Expected image tarball at: $IMAGE_TAR"

SRC_IMAGE="docker-archive:${IMAGE_TAR}:backstage-app:latest"

echo "Pushing image tags to Gitea registry (tls-verify=${REGISTRY_TLS_VERIFY})..."
echo "  -> ${IMAGE_REPO}:${TAG_DEV}"
skopeo copy \
  --dest-creds "${GITEA_USER}:${GITEA_PASS}" \
  --dest-tls-verify="${REGISTRY_TLS_VERIFY}" \
  "${SRC_IMAGE}" \
  "docker://${IMAGE_REPO}:${TAG_DEV}"

echo "  -> ${IMAGE_REPO}:latest (tagging from ${TAG_DEV})"
skopeo copy \
  --src-creds "${GITEA_USER}:${GITEA_PASS}" \
  --src-tls-verify="${REGISTRY_TLS_VERIFY}" \
  --dest-creds "${GITEA_USER}:${GITEA_PASS}" \
  --dest-tls-verify="${REGISTRY_TLS_VERIFY}" \
  "docker://${IMAGE_REPO}:${TAG_DEV}" \
  "docker://${IMAGE_REPO}:latest"

echo ""
echo "Pushed:"
echo "  - ${IMAGE_REPO}:latest"
echo "  - ${IMAGE_REPO}:${TAG_DEV}"

if [[ "$KARGO_REFRESH" == "1" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    echo ""
    echo "Triggering Kargo warehouse refresh..."

    declare -a warehouses=()
    if [[ -n "$KARGO_WAREHOUSE" ]]; then
      warehouses+=("$KARGO_WAREHOUSE")
    else
      # Refresh any Warehouse whose image subscription watches the repo we just pushed.
      mapfile -t warehouses < <(
        kubectl get warehouse -n "${KARGO_NAMESPACE}" -o json |
          jq -r --arg repo "${IMAGE_REPO}" '
            .items[]
            | select([.spec.subscriptions[]?.image?.repoURL] | any(. == $repo))
            | .metadata.name
          '
      )
    fi

    if [[ "${#warehouses[@]}" -eq 0 ]]; then
      echo "No matching Warehouses found in ${KARGO_NAMESPACE} for repoURL: ${IMAGE_REPO}"
      echo "If you haven't set up a Warehouse/Stage for this repo yet, run:"
      echo "  ./scripts/setup-kargo-backstage-pipeline.sh"
    else
      for w in "${warehouses[@]}"; do
        kubectl annotate warehouse "${w}" \
          -n "${KARGO_NAMESPACE}" \
          "kargo.akuity.io/refresh=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --overwrite >/dev/null
        echo "Refresh requested for ${KARGO_NAMESPACE}/${w}"
      done
    fi
  else
    echo "kubectl not found; skipping Kargo refresh"
  fi
fi

if [[ "$KARGO_WAIT" == "1" ]]; then
  need kubectl
  [[ -n "$KARGO_STAGE" ]] || die "KARGO_STAGE is required when KARGO_WAIT=1 (e.g. backstage-local-dev)"

  echo ""
  echo "Waiting for Kargo auto-promotion (${KARGO_NAMESPACE}/${KARGO_STAGE})..."

  if ! kubectl get stage -n "${KARGO_NAMESPACE}" "${KARGO_STAGE}" >/dev/null 2>&1; then
    die "Kargo Stage not found: ${KARGO_NAMESPACE}/${KARGO_STAGE} (apply stacks Kargo pipeline, or run ./scripts/setup-kargo-backstage-pipeline.sh)"
  fi

  deadline=$(( $(date +%s) + KARGO_TIMEOUT_SECONDS ))
  freight=""

  while [[ $(date +%s) -lt $deadline ]]; do
    freight="$(kubectl get freight -n "${KARGO_NAMESPACE}" -o json | jq -r --arg repo "${IMAGE_REPO}" --arg tag "${TAG_DEV}" '
      .items[]
      | select(any(.images[]?; .repoURL == $repo and .tag == $tag))
      | .metadata.name
      ' | head -n1)"

    if [[ -n "$freight" && "$freight" != "null" ]]; then
      break
    fi
    sleep 2
  done

  [[ -n "$freight" && "$freight" != "null" ]] || die "Timed out waiting for Freight for tag ${IMAGE_REPO}:${TAG_DEV} (is the Kargo warehouse configured?)"
  echo "Freight created: ${freight}"

  while [[ $(date +%s) -lt $deadline ]]; do
    stage_json="$(kubectl get stage -n "${KARGO_NAMESPACE}" "${KARGO_STAGE}" -o json)"
    stage_freight="$(jq -r '.status.freightSummary // empty' <<<"$stage_json")"
    stage_ready="$(jq -r '[.status.conditions[]? | select(.type=="Ready")][0].status // empty' <<<"$stage_json")"
    stage_health="$(jq -r '.status.health.status // empty' <<<"$stage_json")"
    stage_verified="$(jq -r '[.status.conditions[]? | select(.type=="Verified")][0].status // empty' <<<"$stage_json")"

    if [[ "$stage_freight" == "$freight" && "$stage_ready" == "True" && "$stage_health" == "Healthy" && "$stage_verified" == "True" ]]; then
      echo "Promoted + verified + healthy: ${KARGO_STAGE} is now on ${TAG_DEV}"
      exit 0
    fi

    sleep 2
  done

  echo "Current Stage status:"
  kubectl get stage -n "${KARGO_NAMESPACE}" "${KARGO_STAGE}" -o yaml | sed -n '1,220p' >&2 || true
  die "Timed out waiting for ${KARGO_NAMESPACE}/${KARGO_STAGE} to promote and become healthy"
fi
