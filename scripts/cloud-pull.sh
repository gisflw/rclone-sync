#!/usr/bin/env bash
set -euo pipefail

exec "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/directional-sync.sh" pull "$@"
