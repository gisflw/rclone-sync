#!/usr/bin/env bash
set -euo pipefail

RESYNC_MODE="${RCLONE_BISYNC_RESYNC_MODE:-newer}"
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<'HELP'
Usage: ./scripts/resync.sh [--execute]

Resyncs LOCAL_ROOT against the remote root using filters.txt. Defaults to dry-run.
HELP
}

execute=0
for argument in "$@"; do
    case "$argument" in
        --execute) execute=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $argument (use --execute or --help)" ;;
    esac
done

load_config
case "$RESYNC_MODE" in
    path1|path2|newer|older|larger|smaller) ;;
    *) die "Invalid RCLONE_BISYNC_RESYNC_MODE '$RESYNC_MODE'; use path1, path2, newer, older, larger, or smaller" ;;
esac
[[ -d "$LOCAL_ROOT" ]] || die "LOCAL_ROOT is missing: $LOCAL_ROOT"
[[ -f "$LOCAL_ROOT/RCLONE_TEST" ]] || die "Local access marker is missing: $LOCAL_ROOT/RCLONE_TEST"
acquire_lock

args=(bisync "$LOCAL_ROOT" "$REMOTE_NAME:" --resync --resync-mode "$RESYNC_MODE"
    --check-access --check-filename RCLONE_TEST --max-delete 10
    --filter-from "$FILTERS_FILE" --resilient --recover
    --log-level INFO --stats 1m --stats-one-line)
if (( execute )); then
    printf 'WARNING: real resync may overwrite files according to RESYNC_MODE=%s.\n' "$RESYNC_MODE" >&2
else
    printf 'DRY RUN: no files will be changed. RESYNC_MODE=%s.\n' "$RESYNC_MODE"
    args+=(--dry-run)
fi
rclone "${args[@]}"
