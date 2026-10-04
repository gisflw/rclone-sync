#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
direction="${1:-}"
[[ "$direction" == pull || "$direction" == push ]] || die "Internal direction must be pull or push"
shift
execute=0
for argument in "$@"; do
    case "$argument" in
        --execute) execute=1 ;;
        -h|--help) printf 'Usage: ./scripts/%s.sh [--execute]\n' "$direction"; exit 0 ;;
        *) die "Unknown argument: $argument" ;;
    esac
done
load_config
[[ -d "$LOCAL_ROOT" ]] || die "LOCAL_ROOT is missing: $LOCAL_ROOT"
[[ -f "$LOCAL_ROOT/RCLONE_TEST" ]] || die "Local access marker is missing: $LOCAL_ROOT/RCLONE_TEST"
remote_files="$(rclone lsf --files-only --max-depth 1 "$REMOTE_NAME:")" || die "Could not list remote root: $REMOTE_NAME:"
[[ "$remote_files" == *RCLONE_TEST* ]] || die "Remote access marker is missing: $REMOTE_NAME:/RCLONE_TEST"
acquire_lock

if [[ "$direction" == pull ]]; then
    source_path="$REMOTE_NAME:"
    destination_path="$LOCAL_ROOT"
    winner=path2
else
    source_path="$LOCAL_ROOT"
    destination_path="$REMOTE_NAME:"
    winner=path1
fi
args=(sync "$source_path" "$destination_path" --filter-from "$FILTERS_FILE" --log-level INFO --stats 1m --stats-one-line)
if (( ! execute )); then
    printf 'DRY RUN: no files will be changed. Add --execute to apply.\n'
    rclone "${args[@]}" --dry-run
    exit
fi
printf 'WARNING: files absent from the source may be deleted from the destination.\n' >&2
rclone "${args[@]}"
rclone bisync "$LOCAL_ROOT" "$REMOTE_NAME:" --resync --resync-mode "$winner" \
    --check-access --check-filename RCLONE_TEST --max-delete 10 \
    --filter-from "$FILTERS_FILE" --resilient --recover \
    --log-level INFO --stats 1m --stats-one-line || die "Sync completed, but bisync state refresh failed. Repair bisync state before resuming normal sync."
