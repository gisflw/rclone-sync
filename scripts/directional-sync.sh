#!/usr/bin/env bash
set -euo pipefail

direction="$1"
shift
case "$direction" in
    pull) command_name=cloud-pull ;;
    push) command_name=local-push ;;
    *) printf 'Unknown direction: %s\n' "$direction" >&2; exit 1 ;;
esac

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf 'Usage: %s.sh [--folder relative/path] [rclone flags...]\nApplies changes immediately. Use --dry-run to preview.\n' "$command_name"
    exit 0
fi

folder=""
if [[ "${1:-}" == --folder ]]; then
    folder="${2:-}"
    if [[ -z "$folder" || "$folder" == /* || "$folder" == -* || "/$folder/" == */../* ]]; then
        printf 'Folder must be a relative path without .. components.\n' >&2
        exit 1
    fi
    shift 2
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_dir/local.env"
if [[ "${LOCAL_ROOT:-}" != /* || ! -d "$LOCAL_ROOT" ]]; then
    printf 'LOCAL_ROOT must be an absolute, existing directory.\n' >&2
    exit 1
fi

local_path="$LOCAL_ROOT"
remote_path="$REMOTE_NAME:"
if [[ -n "$folder" ]]; then
    local_path="${LOCAL_ROOT%/}/$folder"
    remote_path+="$folder"
fi
if [[ "$direction" == pull ]]; then
    exec rclone sync "$remote_path" "$local_path" --filter-from "$repo_dir/filters.txt" --progress "$@"
fi
[[ -d "$local_path" ]] || { printf 'Local source folder is missing: %s\n' "$local_path" >&2; exit 1; }
exec rclone sync "$local_path" "$remote_path" --filter-from "$repo_dir/filters.txt" --progress "$@"
