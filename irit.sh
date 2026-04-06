#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IRIT_ENTRYPOINT="irit.sh" exec bash "${SCRIPT_DIR}/fastserver.sh" "$@"
