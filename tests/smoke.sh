#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo/scripts" "$fixture/home/local root/projects/my project" "$fixture/bin" "$fixture/tmp"
cp "$repo"/scripts/*.sh "$fixture/repo/scripts/"
cp "$repo/filters.txt" "$fixture/repo/filters.txt"
printf 'LOCAL_ROOT="$HOME/local root"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"

cat > "$fixture/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >> "$HOME/calls"
call="$(wc -l < "$HOME/calls")"
printf '%s\0' "$@" > "$HOME/args.$call"
if [[ "${@: -3:1}" == --dry-run && "${@: -2:1}" == --combined ]]; then
    [[ ! -e "$MOCK_LOG" ]] || exit 99
    report="${@: -1}"
    printf '%s' "$report" > "$HOME/report-path"
    printf '%s' "$MOCK_REPORT" > "$report"
    printf 'preview\n' >> "$MOCK_LOG"
    if [[ "${MOCK_SIGNAL:-}" == TERM ]]; then kill -TERM "$PPID"; fi
    exit "${MOCK_PREVIEW_EXIT:-0}"
fi
[[ "$(cat "$MOCK_LOG")" == preview ]] || exit 98
printf 'sync\n' >> "$MOCK_LOG"
exit "${MOCK_SYNC_EXIT:-0}"
MOCK
chmod +x "$fixture/bin/rclone"
export HOME="$fixture/home" PATH="$fixture/bin:$PATH" TMPDIR="$fixture/tmp"
export MOCK_LOG="$fixture/repo/last_sync.log"
export MOCK_REPORT=$'+ new file.txt\n* changed file.txt\n- obsolete file.txt\n= unchanged.txt\n+ new file.txt\n'
ln -s "$fixture/repo" "$fixture/repo-link"
mkdir -p "$HOME/.local/bin"
ln -sT "$fixture/repo/scripts/cloud-pull.sh" "$HOME/.local/bin/cpull"
ln -sT "$fixture/repo/scripts/cloud-push.sh" "$HOME/.local/bin/cpush"
export PATH="$HOME/.local/bin:$PATH"
cd "$fixture"

reset_calls() {
    : > "$HOME/calls"
    printf 'old log\n' > "$MOCK_LOG"
}
check_calls() {
    local count="$1" source_path="$2" destination_path="$3" report
    shift 3
    [[ "$(wc -l < "$HOME/calls")" -eq "$count" ]]
    report="$(cat "$HOME/report-path")"
    printf '%s\0' sync "$source_path" "$destination_path" --filter-from "$fixture/repo/filters.txt" --progress \
        --verbose --log-file "$fixture/repo/last_sync.log" \
        --fast-list --check-first --checkers 32 --transfers 16 --buffer-size 32M "$@" > "$HOME/expected"
    cp "$HOME/expected" "$HOME/expected-preview"
    printf '%s\0' --dry-run --combined "$report" >> "$HOME/expected-preview"
    cmp "$HOME/expected-preview" "$HOME/args.1"
    if [[ "$count" == 2 ]]; then
        cmp "$HOME/expected" "$HOME/args.2"
        [[ "$(cat "$MOCK_LOG")" == $'preview\nsync' ]]
    fi
    [[ ! -e "$report" ]]
    local remaining=("$TMPDIR"/*)
    [[ ! -e "${remaining[0]}" ]]
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
local_root="$HOME/local root"

for command in "$pull" cpull; do
    reset_calls
    "$command" <<< y > "$HOME/output"
    check_calls 2 mock: "$local_root"
done
for command in "$push" cpush; do
    reset_calls
    "$command" <<< YES > "$HOME/output"
    check_calls 2 "$local_root" mock:
done
for text in 'Preview: push' "Source: $local_root" 'Destination: mock:' 'Added (1):' 'Modified (1):' 'Deleted (1):' \
    '  new file.txt' '  changed file.txt' '  obsolete file.txt'; do
    grep -Fx -- "$text" "$HOME/output" > /dev/null
done
[[ "$(grep -Fc '  new file.txt' "$HOME/output")" == 1 ]]
if grep -F unchanged.txt "$HOME/output"; then exit 1; fi

flags=(--checksum --transfers 2 --checkers 8 --fast-list=false --check-first=false --buffer-size 16M --bwlimit 4M --exclude '*.large file' --progress=false --log-file "$HOME/custom log.log" --combined "$HOME/custom report")
for command in "$pull" cpull; do
    reset_calls
    "$command" --folder 'projects/my project' "${flags[@]}" <<< yes > "$HOME/output"
    check_calls 2 'mock:projects/my project' "$local_root/projects/my project" "${flags[@]}"
done
for command in "$push" cpush; do
    reset_calls
    "$command" --folder 'projects/my project' "${flags[@]}" --dry-run < /dev/null > "$HOME/output"
    check_calls 1 "$local_root/projects/my project" 'mock:projects/my project' "${flags[@]}" --dry-run
done

for flags in '--dry-run' '-n' '--dry-run=true' '-n=true' '--dry-run=1' '--dry-run=False --dry-run=True' '-n=false -n'; do
    read -r -a arguments <<< "$flags"
    reset_calls
    "$pull" "${arguments[@]}" < /dev/null > "$HOME/output"
    check_calls 1 mock: "$local_root" "${arguments[@]}"
    if grep -F 'Proceed with sync?' "$HOME/output"; then exit 1; fi
done
for flags in '--dry-run=false' '-n=false' '--dry-run --dry-run=false' '-n --dry-run=0'; do
    read -r -a arguments <<< "$flags"
    reset_calls
    "$push" "${arguments[@]}" <<< y > "$HOME/output"
    check_calls 2 "$local_root" mock: "${arguments[@]}"
done

for answer in '' n no YESS ' yes'; do
    reset_calls
    "$pull" <<< "$answer" > "$HOME/output"
    check_calls 1 mock: "$local_root"
    grep -F 'Cancelled.' "$HOME/output" > /dev/null
done
reset_calls
status=0
"$pull" < /dev/null > "$HOME/output" 2>&1 || status=$?
[[ "$status" == 1 ]]
check_calls 1 mock: "$local_root"

for report in '' $'= unchanged.txt\n'; do
    reset_calls
    MOCK_REPORT="$report" "$pull" < /dev/null > "$HOME/output"
    check_calls 1 mock: "$local_root"
    grep -F 'No changes reported.' "$HOME/output" > /dev/null
done
for command in "$pull" "$push" cpull cpush; do
    reset_calls
    status=0
    MOCK_PREVIEW_EXIT=7 "$command" <<< y > "$HOME/output" 2>&1 || status=$?
    [[ "$status" == 7 ]]
    [[ "$(wc -l < "$HOME/calls")" == 1 ]]
    [[ ! -e "$(cat "$HOME/report-path")" ]]
    reset_calls
    status=0
    MOCK_SYNC_EXIT=8 "$command" <<< y > "$HOME/output" 2>&1 || status=$?
    [[ "$status" == 8 ]]
    [[ "$(wc -l < "$HOME/calls")" == 2 ]]
    [[ ! -e "$(cat "$HOME/report-path")" ]]
done
for report in $'! unreadable file.txt\n+ new file.txt\n' $'invalid entry\n'; do
    reset_calls
    status=0
    MOCK_REPORT="$report" "$pull" <<< y > "$HOME/output" 2>&1 || status=$?
    [[ "$status" == 1 ]]
    check_calls 1 mock: "$local_root"
done
reset_calls
status=0
MOCK_SIGNAL=TERM "$pull" <<< y > "$HOME/output" 2>&1 || status=$?
[[ "$status" == 143 ]]
check_calls 1 mock: "$local_root"

reset_calls
"$pull" --folder new/folder <<< y > "$HOME/output"
check_calls 2 mock:new/folder "$local_root/new/folder"
[[ ! -e "$local_root/new/folder" ]]
expect_failure "$push" --folder new/folder
for folder in '' /absolute .. ../outside projects/../outside projects/.. --dry-run; do
    expect_failure "$pull" --folder "$folder"
done
expect_failure "$pull" --folder
reset_calls
"$pull" --help > "$HOME/output"
grep -F 'Previews destination changes' "$HOME/output" > /dev/null
"$push" -h > /dev/null
[[ ! -s "$HOME/calls" ]]

printf 'LOCAL_ROOT="$HOME/missing"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
expect_failure "$pull"
expect_failure "$push"
[[ ! -e "$HOME/missing" ]]
printf 'LOCAL_ROOT="relative"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
mkdir relative
expect_failure "$pull"
expect_failure "$push"
printf 'smoke test passed\n'
