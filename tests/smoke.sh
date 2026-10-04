#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo/scripts" "$fixture/home/local" "$fixture/bin"
cp "$repo"/scripts/*.sh "$fixture/repo/scripts/"
cp "$repo/filters.txt" "$fixture/repo/filters.txt"
printf 'LOCAL_ROOT="$HOME/local"\nREMOTE_NAME=mock\n' > "$fixture/repo/local.env"
touch "$fixture/home/local/RCLONE_TEST"

cat > "$fixture/bin/rclone" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    listremotes) printf 'mock:\n' ;;
    lsf) printf 'RCLONE_TEST\n' ;;
    bisync|sync) printf '%s\n' "$*" >> "$HOME/calls" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/rclone"
export HOME="$fixture/home" PATH="$fixture/bin:$PATH"
ln -s "$fixture/repo" "$fixture/repo-link"

"$fixture/repo-link/scripts/bisync.sh" > /dev/null
"$fixture/repo/scripts/resync.sh" > /dev/null
"$fixture/repo/scripts/cloud-pull.sh" > /dev/null
"$fixture/repo/scripts/local-push.sh" > /dev/null
[[ "$(wc -l < "$HOME/calls")" -eq 4 ]]
[[ "$(sed -n '2p' "$HOME/calls")" == *'--resync-mode newer'*'--dry-run' ]]
[[ "$(sed -n '3p' "$HOME/calls")" == "sync mock: $HOME/local "*'--dry-run' ]]
[[ "$(sed -n '4p' "$HOME/calls")" == "sync $HOME/local mock: "*'--dry-run' ]]
printf 'smoke test passed\n'
