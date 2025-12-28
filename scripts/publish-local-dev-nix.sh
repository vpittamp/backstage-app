#!/usr/bin/env bash
# Convenience wrapper for local dev inner-loop publishing.
# Sets KARGO_WAIT=1 and KARGO_STAGE=backstage-local-dev by default.
set -euo pipefail

export KARGO_WAIT="${KARGO_WAIT:-1}"
export KARGO_STAGE="${KARGO_STAGE:-backstage-local-dev}"

exec "$(dirname "$0")/publish-prod-nix.sh" "$@"
