#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
load_config
acquire_lock

if [[ ! -d "$LOCAL_ROOT" ]]; then
    printf 'ERROR: local sync root is missing: %s\n' "$LOCAL_ROOT" >&2
    exit 1
fi
if [[ ! -f "$LOCAL_ROOT/RCLONE_TEST" ]]; then
    printf 'ERROR: local access marker is missing: %s/RCLONE_TEST\n' "$LOCAL_ROOT" >&2
    exit 1
fi

rclone bisync "$LOCAL_ROOT" "$REMOTE_NAME:" \
    --check-access --check-filename RCLONE_TEST --max-delete 10 \
    --filter-from "$FILTERS_FILE" --resilient --recover \
    --log-level INFO --stats 1m --stats-one-line
