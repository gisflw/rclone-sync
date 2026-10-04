#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo/scripts" "$fixture/home/local root/projects/my project" "$fixture/bin"
cp "$repo"/scripts/*.sh "$fixture/repo/scripts/"
cp "$repo/filters.txt" "$fixture/repo/filters.txt"
printf 'LOCAL_ROOT="$HOME/local root"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"

cat > "$fixture/bin/rclone" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$HOME/calls"
[[ ! -e "$MOCK_LOG" ]] || exit 99
printf '%s\0' "$@" > "$HOME/args"
exit "${MOCK_EXIT:-0}"
EOF
chmod +x "$fixture/bin/rclone"
export HOME="$fixture/home" PATH="$fixture/bin:$PATH"
export MOCK_LOG="$fixture/repo/last_sync.log"
ln -s "$fixture/repo" "$fixture/repo-link"
cd "$fixture"

reset_calls() { : > "$HOME/calls"; }
check_call() {
    [[ "$(wc -l < "$HOME/calls")" -eq 1 ]]
    local source_path="$1" destination_path="$2"
    shift 2
    printf '%s\0' sync "$source_path" "$destination_path" --filter-from "$fixture/repo/filters.txt" --progress \
        --verbose --log-file "$fixture/repo/last_sync.log" \
        --fast-list --check-first --checkers 32 --transfers 16 --buffer-size 32M "$@" > "$HOME/expected"
    cmp "$HOME/expected" "$HOME/args"
}
expect_failure() {
    reset_calls
    if "$@" > /dev/null 2>&1; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
    [[ ! -s "$HOME/calls" ]]
}

pull="$fixture/repo-link/scripts/cloud-pull.sh"
push="$fixture/repo/scripts/local-push.sh"
local_root="$HOME/local root"

reset_calls
printf 'old pull log\n' > "$MOCK_LOG"
"$pull"
check_call mock: "$local_root"

reset_calls
printf 'old push log\n' > "$MOCK_LOG"
"$push"
check_call "$local_root" mock:

flags=(--dry-run --checksum --transfers 2 --checkers 8 --fast-list=false --check-first=false --buffer-size 16M --bwlimit 4M --exclude '*.large file' --progress=false --log-file "$HOME/custom log.log")
reset_calls
"$pull" --folder 'projects/my project' "${flags[@]}"
check_call 'mock:projects/my project' "$local_root/projects/my project" "${flags[@]}"

reset_calls
"$push" --folder 'projects/my project' --verbose
check_call "$local_root/projects/my project" 'mock:projects/my project' --verbose

reset_calls
"$pull" --folder new/folder
check_call mock:new/folder "$local_root/new/folder"

expect_failure "$push" --folder new/folder
for folder in '' /absolute .. ../outside projects/../outside projects/.. --dry-run; do
    expect_failure "$pull" --folder "$folder"
done
expect_failure "$pull" --folder

reset_calls
"$pull" --help > /dev/null
"$push" -h > /dev/null
[[ ! -s "$HOME/calls" ]]

for command in "$pull" "$push"; do
    reset_calls
    status=0
    MOCK_EXIT=7 "$command" || status=$?
    [[ "$status" -eq 7 ]]
    [[ "$(wc -l < "$HOME/calls")" -eq 1 ]]
done

printf 'LOCAL_ROOT="$HOME/missing"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
expect_failure "$pull"
expect_failure "$push"
[[ ! -e "$HOME/missing" ]]

printf 'LOCAL_ROOT="relative"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
mkdir relative
expect_failure "$pull"
expect_failure "$push"

printf 'smoke test passed\n'
