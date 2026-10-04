#!/usr/bin/env bash
set -euo pipefail

direction="$1"
shift
case "$direction" in
    pull) command_name=cloud-pull ;;
    push) command_name=cloud-push ;;
    *) printf 'Unknown direction: %s\n' "$direction" >&2; exit 1 ;;
esac

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf 'Usage: %s.sh [--folder relative/path] [rclone flags...]\nPreviews destination changes, then asks before syncing. Use --dry-run for preview only.\n' "$command_name"
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
if [[ "$direction" == push && ! -d "$local_path" ]]; then
    printf 'Local source folder is missing: %s\n' "$local_path" >&2
    exit 1
fi
rm -f -- "$repo_dir/last_sync.log"
flags=(--filter-from "$repo_dir/filters.txt" --progress
    --verbose --log-file "$repo_dir/last_sync.log"
    --fast-list --check-first --checkers 32 --transfers 16 --buffer-size 32M)
if [[ "$direction" == pull ]]; then
    source_path="$remote_path"
    destination_path="$local_path"
else
    source_path="$local_path"
    destination_path="$remote_path"
fi

preview_only=false
for argument in "$@"; do
    case "$argument" in
        --) break ;;
        --dry-run|-n) preview_only=true ;;
        --dry-run=*|-n=*)
            case "${argument#*=}" in
                1|t|T|true|TRUE|True) preview_only=true ;;
                0|f|F|false|FALSE|False) preview_only=false ;;
            esac
            ;;
    esac
done

report="$(mktemp)"
trap 'rm -f -- "$report"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
rclone sync "$source_path" "$destination_path" "${flags[@]}" "$@" --dry-run --combined "$report"
LC_ALL=C sort -u -o "$report" -- "$report"

added=() modified=() deleted=() errors=()
while IFS= read -r entry || [[ -n "$entry" ]]; do
    case "$entry" in
        '+ '*) added+=("${entry:2}") ;;
        '* '*) modified+=("${entry:2}") ;;
        '- '*) deleted+=("${entry:2}") ;;
        '! '*) errors+=("${entry:2}") ;;
        '= '*) ;;
        *) printf 'Unrecognized preview report entry: %s\n' "$entry" >&2; exit 1 ;;
    esac
done < "$report"

printf '\nPreview: %s\nSource: %s\nDestination: %s\n' "$direction" "$source_path" "$destination_path"
printf '\nAdded (%s):\n' "${#added[@]}"
if ((${#added[@]})); then printf '  %s\n' "${added[@]}"; fi
printf '\nModified (%s):\n' "${#modified[@]}"
if ((${#modified[@]})); then printf '  %s\n' "${modified[@]}"; fi
printf '\nDeleted (%s):\n' "${#deleted[@]}"
if ((${#deleted[@]})); then printf '  %s\n' "${deleted[@]}"; fi
if ((${#errors[@]})); then
    printf '\nPreview errors (%s):\n' "${#errors[@]}" >&2
    printf '  %s\n' "${errors[@]}" >&2
    exit 1
fi
if ((${#added[@]} + ${#modified[@]} + ${#deleted[@]} == 0)); then
    printf '\nNo changes reported.\n'
    exit 0
fi
printf '\nThis is a prediction; syncing scans again and may overwrite or delete destination files.\n'
if [[ "$preview_only" == true ]]; then exit 0; fi
printf 'Proceed with sync? [y/N] '
if ! IFS= read -r answer; then
    printf '\nCancelled: confirmation input unavailable.\n' >&2
    exit 1
fi
case "${answer,,}" in
    y|yes) rclone sync "$source_path" "$destination_path" "${flags[@]}" "$@" ;;
    *) printf 'Cancelled.\n' ;;
esac
