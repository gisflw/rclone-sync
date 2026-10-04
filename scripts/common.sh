#!/usr/bin/env bash

REPO_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_ENV="$REPO_DIR/local.env"
FILTERS_FILE="$REPO_DIR/filters.txt"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

load_config() {
    [[ -n "${HOME:-}" ]] || die "HOME is not set"
    command -v rclone >/dev/null 2>&1 || die "rclone was not found in PATH"
    command -v flock >/dev/null 2>&1 || die "flock was not found in PATH"
    [[ -r "$LOCAL_ENV" ]] || die "Missing or unreadable configuration file: $LOCAL_ENV"
    [[ -r "$FILTERS_FILE" ]] || die "Missing or unreadable filter file: $FILTERS_FILE"
    source "$LOCAL_ENV" || die "Could not source $LOCAL_ENV"
    [[ -n "${LOCAL_ROOT:-}" && "$LOCAL_ROOT" == /* ]] || die "LOCAL_ROOT must be an absolute path"
    [[ -n "${REMOTE_NAME:-}" ]] || die "REMOTE_NAME is missing or empty"
    if [[ "$REMOTE_NAME" == *:* || "$REMOTE_NAME" == */* || "$REMOTE_NAME" == *[[:space:]]* ]]; then
        die "REMOTE_NAME must be a single rclone remote name"
    fi

    local remote_list remote
    remote_list="$(rclone listremotes)" || die "Could not list rclone remotes"
    local remote_found=0
    while IFS= read -r remote; do
        [[ "$remote" == "$REMOTE_NAME:" ]] && remote_found=1
    done <<< "$remote_list"
    (( remote_found )) || die "Configured rclone remote '$REMOTE_NAME' does not exist"

    [[ -d "$LOCAL_ROOT" && -r "$LOCAL_ROOT" && -w "$LOCAL_ROOT" && -x "$LOCAL_ROOT" ]] || die "LOCAL_ROOT is missing or inaccessible: $LOCAL_ROOT"
}

acquire_lock() {
    mkdir -p -- "$HOME/.cache" || die "Could not create lock directory"
    local lock_file="$HOME/.cache/rclone-bisync.lock"
    exec 9>"$lock_file" || die "Could not open lock file: $lock_file"
    flock -n 9 || die "Another sync is in progress (lock: $lock_file)"
}
