#!/usr/bin/env bash
set -euo pipefail

# Review this policy before any real resync. It is passed explicitly to rclone
# so --resync never relies on rclone's implicit path1 default.
RESYNC_MODE="${RCLONE_BISYNC_RESYNC_MODE:-newer}"

# Resolve the script itself so this also works when the repository is reached
# through the stable symlink used by the systemd user unit.
SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
    SOURCE_DIR="$(cd -P -- "$(dirname -- "$SOURCE")" && pwd -P)"
    SOURCE="$(readlink -- "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$SOURCE_DIR/$SOURCE"
done
REPO_DIR="$(cd -P -- "$(dirname -- "$SOURCE")" && pwd -P)"
CONFIG_DIR="$REPO_DIR/config"
LOCAL_ENV="$CONFIG_DIR/local.env"
INCLUDES_FILE="$CONFIG_DIR/includes.txt"
FILTERS_FILE="$REPO_DIR/filters.txt"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./resync.sh [FOLDER] [--execute]

Without --execute, run a dry-run resync. FOLDER must match one configured
line in config/includes.txt; without FOLDER, process every configured folder.
EOF
}

execute=0
selected_folder=''
for argument in "$@"; do
    case "$argument" in
        --execute)
            execute=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -* )
            die "Unknown option: $argument (use --execute or --help)"
            ;;
        *)
            [[ -z "$selected_folder" ]] || die "Only one folder may be selected: $selected_folder"
            selected_folder="$argument"
            ;;
    esac
done

[[ -n "${HOME:-}" ]] || die "HOME is not set; rclone and the local configuration need it."
command -v rclone >/dev/null 2>&1 || die "rclone was not found in PATH. Install and configure it separately."
command -v flock >/dev/null 2>&1 || die "flock was not found in PATH. Install the util-linux package separately."

[[ -f "$LOCAL_ENV" && -r "$LOCAL_ENV" ]] || die "Missing or unreadable configuration file: $LOCAL_ENV"
[[ -f "$INCLUDES_FILE" && -r "$INCLUDES_FILE" ]] || die "Missing or unreadable configuration file: $INCLUDES_FILE"
[[ -f "$FILTERS_FILE" && -r "$FILTERS_FILE" ]] || die "Missing or unreadable filter file: $FILTERS_FILE"

# local.env is deliberately shell-compatible so values such as "$HOME/gdrive"
# are expanded by the shell that runs this script.
if ! source "$LOCAL_ENV"; then
    die "Could not source $LOCAL_ENV"
fi

[[ -n "${LOCAL_ROOT:-}" ]] || die "LOCAL_ROOT is missing or empty in $LOCAL_ENV"
[[ -n "${REMOTE_NAME:-}" ]] || die "REMOTE_NAME is missing or empty in $LOCAL_ENV"
[[ "$LOCAL_ROOT" == /* ]] || die "LOCAL_ROOT must be an absolute path after shell expansion: $LOCAL_ROOT"
if [[ "$REMOTE_NAME" == *:* || "$REMOTE_NAME" == */* || "$REMOTE_NAME" == *[[:space:]]* ]]; then
    die "REMOTE_NAME must be a single rclone remote name, without '/', ':' or whitespace: $REMOTE_NAME"
fi

case "$RESYNC_MODE" in
    path1|path2|newer|older|larger|smaller)
        ;;
    *)
        die "Invalid RCLONE_BISYNC_RESYNC_MODE '$RESYNC_MODE'; use path1, path2, newer, older, larger, or smaller"
        ;;
esac

remote_list=''
if ! remote_list="$(rclone listremotes 2>&1)"; then
    printf "ERROR: Could not list rclone remotes. Run 'rclone config' and verify the configuration.\n" >&2
    printf '%s\n' "$remote_list" >&2
    exit 1
fi
remote_found=0
while IFS= read -r remote; do
    if [[ "$remote" == "$REMOTE_NAME:" ]]; then
        remote_found=1
        break
    fi
done <<< "$remote_list"
(( remote_found == 1 )) || die "Configured rclone remote '$REMOTE_NAME' does not exist. Run 'rclone config' and create it first."

folders=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
    # Accept files edited on systems that use CRLF line endings.
    raw="${raw%$'\r'}"

    [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue

    [[ "$raw" != /* ]] || die "Invalid folder path in $INCLUDES_FILE: absolute paths are not allowed: $raw"
    [[ "$raw" != */ ]] || die "Invalid folder path in $INCLUDES_FILE: trailing '/' is not allowed: $raw"
    [[ "$raw" != *//* ]] || die "Invalid folder path in $INCLUDES_FILE: empty path components are not allowed: $raw"

    IFS='/' read -r -a components <<< "$raw"
    for component in "${components[@]}"; do
        [[ "$component" != "." && "$component" != ".." ]] || die "Invalid folder path in $INCLUDES_FILE: '.' and '..' are not allowed: $raw"
    done

    folders+=("$raw")
done < "$INCLUDES_FILE"

((${#folders[@]} > 0)) || die "No sync folders are configured in $INCLUDES_FILE"

if [[ -n "$selected_folder" ]]; then
    selected_found=0
    selected_folders=()
    for folder in "${folders[@]}"; do
        if [[ "$folder" == "$selected_folder" ]]; then
            selected_folders+=("$folder")
            selected_found=1
            break
        fi
    done
    (( selected_found == 1 )) || die "Folder is not configured in $INCLUDES_FILE: $selected_folder"
    folders=("${selected_folders[@]}")
fi

[[ -d "$LOCAL_ROOT" ]] || die "LOCAL_ROOT does not exist: $LOCAL_ROOT. Refusing to create it because an unavailable mount could look empty."
[[ -r "$LOCAL_ROOT" && -w "$LOCAL_ROOT" && -x "$LOCAL_ROOT" ]] || die "LOCAL_ROOT is not a readable and writable directory: $LOCAL_ROOT"

# Keep the lock outside the repository and share it with bisync.sh.
lock_dir="$HOME/.cache"
if [[ ! -d "$lock_dir" ]]; then
    mkdir -p -- "$lock_dir" || die "Could not create lock directory: $lock_dir"
fi
lock_file="$lock_dir/rclone-bisync.lock"
if ! exec 9>"$lock_file"; then
    die "Could not open lock file: $lock_file"
fi
if ! flock -n 9; then
    die "Another bisync or resync run is already in progress (lock: $lock_file)"
fi

ensure_local_pair() {
    local folder="$1"
    local local_pair="$2"
    local remote_pair="$3"

    if [[ -e "$local_pair" && ! -d "$local_pair" ]]; then
        printf 'ERROR: local sync path is not a directory for "%s": %s\n' "$folder" "$local_pair" >&2
        return 1
    fi

    if [[ ! -d "$local_pair" ]]; then
        if (( ! execute )); then
            printf 'ERROR: local sync directory is missing for "%s": %s\n' "$folder" "$local_pair" >&2
            printf '       Dry-run will not create it; create the directory and RCLONE_TEST marker first.\n' >&2
            return 1
        fi
        printf 'Local sync directory is missing for "%s"; checking the remote before creating it.\n' "$folder"
        if ! rclone lsf --max-depth 1 "$remote_pair" >/dev/null 2>&1; then
            printf 'ERROR: refusing to create %s because the remote pair could not be verified: %s\n' "$local_pair" "$remote_pair" >&2
            return 1
        fi
        if ! mkdir -p -- "$local_pair"; then
            printf 'ERROR: could not create local sync directory: %s\n' "$local_pair" >&2
            return 1
        fi
        printf 'Created local sync directory: %s\n' "$local_pair"
    fi

    if [[ ! -f "$local_pair/RCLONE_TEST" ]]; then
        printf 'ERROR: local access marker is missing for "%s": %s\n' "$folder" "$local_pair/RCLONE_TEST" >&2
        printf '       Create it without overwriting an existing marker, then retry.\n' >&2
        return 1
    fi

    return 0
}

if (( execute )); then
    printf 'WARNING: --execute will perform a real resync for %d folder(s).\n' "${#folders[@]}" >&2
    printf 'WARNING: resync may overwrite files or delete one side according to RESYNC_MODE=%s.\n' "$RESYNC_MODE" >&2
    printf 'WARNING: inspect the dry-run first and confirm both access markers are present.\n' >&2
else
    printf 'DRY RUN: no files will be changed.\n'
    printf 'Resync conflict policy: RESYNC_MODE=%s (review this explicit policy before --execute).\n' "$RESYNC_MODE"
fi

failed_folders=()
for folder in "${folders[@]}"; do
    local_pair="$LOCAL_ROOT/$folder"
    remote_pair="$REMOTE_NAME:$folder"

    printf '\n==> Resyncing folder: %s\n' "$folder"
    printf '    local : %s\n' "$local_pair"
    printf '    remote: %s\n' "$remote_pair"

    if ! ensure_local_pair "$folder" "$local_pair" "$remote_pair"; then
        failed_folders+=("$folder")
        continue
    fi

    rclone_args=(
        bisync
        "$local_pair"
        "$remote_pair"
        --resync
        --resync-mode "$RESYNC_MODE"
        --check-access
        --check-filename RCLONE_TEST
        --max-delete 10
        --filter-from "$FILTERS_FILE"
        --resilient
        --recover
        --log-level INFO
        --stats 1m
        --stats-one-line
    )
    (( execute )) || rclone_args+=(--dry-run)

    if rclone "${rclone_args[@]}"; then
        printf 'OK: completed resync for folder: %s\n' "$folder"
    else
        status=$?
        failed_folders+=("$folder")
        printf 'FAILED: folder "%s" (rclone exit status %d)\n' "$folder" "$status" >&2
    fi
done

if ((${#failed_folders[@]} > 0)); then
    printf '\nFAILED PAIRS:\n' >&2
    for folder in "${failed_folders[@]}"; do
        printf '  %s\n' "$folder" >&2
    done
    exit 1
fi

printf '\nAll selected resync pairs completed successfully.\n'
