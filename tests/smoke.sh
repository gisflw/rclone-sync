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
mkdir -p "$HOME/.local/bin"
ln -sT "$fixture/repo/scripts/cloud-pull.sh" "$HOME/.local/bin/cpull"
ln -sT "$fixture/repo/scripts/cloud-push.sh" "$HOME/.local/bin/cpush"
ln -sT "$fixture/repo/scripts/cloud-bisync.sh" "$HOME/.local/bin/cbisync"
export PATH="$HOME/.local/bin:$PATH"
cd "$fixture"

reset_calls() { : > "$HOME/calls"; }
check_call() {
    [[ "$(wc -l < "$HOME/calls")" -eq 1 ]]
    local operation="$1" source_path="$2" destination_path="$3"
    shift 3
    printf '%s\0' "$operation" "$source_path" "$destination_path" --filter-from "$fixture/repo/filters.txt" --progress \
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
push="$fixture/repo/scripts/cloud-push.sh"
bisync="$fixture/repo-link/scripts/cloud-bisync.sh"
local_root="$HOME/local root"

reset_calls
printf 'old pull log\n' > "$MOCK_LOG"
"$pull"
check_call sync mock: "$local_root"

reset_calls
printf 'old push log\n' > "$MOCK_LOG"
"$push"
check_call sync "$local_root" mock:

flags=(--dry-run --checksum --transfers 2 --checkers 8 --fast-list=false --check-first=false --buffer-size 16M --bwlimit 4M --exclude '*.large file' --progress=false --log-file "$HOME/custom log.log" --combined "$HOME/custom report.log" --interactive=false)
reset_calls
"$pull" --folder 'projects/my project' "${flags[@]}"
check_call sync 'mock:projects/my project' "$local_root/projects/my project" "${flags[@]}"

reset_calls
"$push" --folder 'projects/my project' --verbose
check_call sync "$local_root/projects/my project" 'mock:projects/my project' --verbose

reset_calls
cpull --folder 'projects/my project' "${flags[@]}"
check_call sync 'mock:projects/my project' "$local_root/projects/my project" "${flags[@]}"

reset_calls
cpush --folder 'projects/my project' "${flags[@]}"
check_call sync "$local_root/projects/my project" 'mock:projects/my project' "${flags[@]}"

reset_calls
"$pull" --folder new/folder
check_call sync mock:new/folder "$local_root/new/folder"

for command in "$bisync" cbisync; do
    reset_calls
    printf 'old bisync log\n' > "$MOCK_LOG"
    "$command"
    check_call bisync "$local_root" mock:

    reset_calls
    "$command" --resync --dry-run
    check_call bisync "$local_root" mock: --resync --dry-run

    reset_calls
    "$command" --folder 'projects/my project' "${flags[@]}"
    check_call bisync "$local_root/projects/my project" 'mock:projects/my project' "${flags[@]}"

    reset_calls
    "$command" --folder 'projects/my project' --resync
    check_call bisync "$local_root/projects/my project" 'mock:projects/my project' --resync
    expect_failure "$command" --folder new/folder
    expect_failure "$command" --folder
    for folder in '' /absolute .. ../outside projects/../outside projects/.. --dry-run; do
        expect_failure "$command" --folder "$folder"
    done
done
[[ ! -e "$local_root/new" ]]

expect_failure "$push" --folder new/folder
for folder in '' /absolute .. ../outside projects/../outside projects/.. --dry-run; do
    expect_failure "$pull" --folder "$folder"
done
expect_failure "$pull" --folder

reset_calls
"$pull" --help > /dev/null
"$push" -h > /dev/null
"$bisync" --help > /dev/null
cbisync -h > /dev/null
[[ ! -s "$HOME/calls" ]]

for command in "$pull" "$push" "$bisync" cpull cpush cbisync; do
    reset_calls
    status=0
    MOCK_EXIT=7 "$command" || status=$?
    [[ "$status" -eq 7 ]]
    [[ "$(wc -l < "$HOME/calls")" -eq 1 ]]
done

printf 'LOCAL_ROOT="$HOME/missing"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
expect_failure "$pull"
expect_failure "$push"
expect_failure "$bisync"
expect_failure cbisync
[[ ! -e "$HOME/missing" ]]

printf 'LOCAL_ROOT="relative"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
mkdir relative
expect_failure "$pull"
expect_failure "$push"
expect_failure "$bisync"
expect_failure cbisync

printf 'smoke test passed\n'
