# Reproducible `rclone bisync` setup

This repository runs one `rclone bisync` pair between `LOCAL_ROOT` and the configured remote root. `filters.txt` controls which files are included.

The repository contains no authentication or installation logic. Do not commit `rclone.conf`, OAuth tokens, credentials, bisync state, or logs.

## Prerequisites

- Ubuntu/Linux with Bash and the `flock` command available (normally from `util-linux`).
- Install `rclone` separately. These files do not install it.
- Configure the Google Drive remote manually with `rclone config`, using the remote name `gdrive`. These files do not configure authentication.

Verify the remote before using this repository:

```bash
rclone lsd gdrive:
```

## Initial setup

Clone the repository, then edit the tracked configuration files:

```bash
git clone <repository-url> ~/rclone-bisync
cd ~/rclone-bisync
${EDITOR:-vi} local.env
```

`local.env` is shell-compatible and should contain only non-secret paths and names:

```bash
LOCAL_ROOT="$HOME/gdrive"
REMOTE_NAME="gdrive"
```

Make sure the intended local filesystem is mounted, then create the local root. The scripts refuse to create a missing root because an unavailable mount can otherwise look like an empty directory:

```bash
source local.env
mkdir -p "$LOCAL_ROOT"
```

Before the first resync, create and verify an `RCLONE_TEST` marker at the local and remote roots. Do not overwrite an existing marker:

```bash
source local.env
if [[ ! -e "$LOCAL_ROOT/RCLONE_TEST" ]]; then
    : > "$LOCAL_ROOT/RCLONE_TEST"
fi

rclone mkdir "$REMOTE_NAME:"
if ! rclone lsf --files-only "$REMOTE_NAME:/RCLONE_TEST" >/dev/null 2>&1; then
    rclone touch "$REMOTE_NAME:/RCLONE_TEST"
fi

test -f "$LOCAL_ROOT/RCLONE_TEST"
rclone lsf --files-only "$REMOTE_NAME:/RCLONE_TEST"
```

The local and remote marker paths must both exist. `--check-access` makes every bisync operation abort if the expected marker is missing; this helps catch an unavailable local mount or the wrong remote path.

## First synchronization

`scripts/resync.sh` is dry-run by default. Review the proposed changes:

```bash
./scripts/resync.sh
```

The real resync requires the explicit `--execute` argument:

```bash
./scripts/resync.sh --execute
```

The script explicitly passes `--resync-mode newer` by default. Review or change `RESYNC_MODE` near the top of `scripts/resync.sh` (or set `RCLONE_BISYNC_RESYNC_MODE`) before executing. Resync can overwrite conflicting files according to that policy, so do not run it blindly.

After initialization, run normal bidirectional synchronization with:

```bash
./scripts/bisync.sh
```

## Force one direction

Use `cloud-pull.sh` to make the remote root authoritative, or `local-push.sh` to make the local root authoritative. Review the dry-run, then explicitly execute:

```bash
./scripts/cloud-pull.sh
./scripts/cloud-pull.sh --execute

./scripts/local-push.sh
./scripts/local-push.sh --execute
```

These commands use one-way `rclone sync`: files missing from the source can be deleted from the destination, and source versions replace differing destination versions. They require the root `RCLONE_TEST` marker on both sides and share the lock with the timer. After a successful real sync, they refresh bisync state.

## systemd user timer

The service uses `%h/.local/libexec/rclone-bisync` as a stable link to the clone, so it does not hardcode `/home/<user>` or a particular clone directory. From the repository directory, install the user units by linking them and create that stable repository link:

```bash
repo_dir="$(pwd -P)"
mkdir -p "$HOME/.local/libexec" "$HOME/.config/systemd/user"
ln -sfn "$repo_dir" "$HOME/.local/libexec/rclone-bisync"
ln -sfn "$repo_dir/systemd/rclone-bisync.service" "$HOME/.config/systemd/user/rclone-bisync.service"
ln -sfn "$repo_dir/systemd/rclone-bisync.timer" "$HOME/.config/systemd/user/rclone-bisync.timer"
systemctl --user daemon-reload
```

Copying the two unit files into `~/.config/systemd/user/` also works, but keep the stable repository link in place. The units do not require root. The timer is not enabled by any repository script; enable and start it explicitly when ready:

```bash
systemctl --user enable --now rclone-bisync.timer
```

Inspect the timer, service, and journal output with:

```bash
systemctl --user status rclone-bisync.timer
systemctl --user list-timers rclone-bisync.timer
systemctl --user status rclone-bisync.service
journalctl --user -u rclone-bisync.service
journalctl --user -u rclone-bisync.service -f
```

The service is `Type=oneshot`, and all scripts use the same non-blocking `flock` lock at `~/.cache/rclone-bisync.lock`, outside the repository. A timer invocation, a manual run, a resync, and a force pull or push cannot overlap.

## Adding folders and changing filters

Edit `filters.txt` to change which paths sync. Filter changes may require a resync; review its dry-run before executing.

> Important: changing `filters.txt` changes the files visible to bisync and may require a resync. Review a dry-run before using `./scripts/resync.sh --execute`.

Generated environments and temporary files are excluded by `filters.txt`. `.git/` is intentionally not excluded: Git repositories stored inside the synchronized folders are synchronized completely.

## Safety and recovery

- `--max-delete 10` makes bisync abort when a run predicts more than ten percent deletions. The one-way pull/push helpers use `rclone sync`, which does not have this bisync guardrail; review their dry-run carefully. The scripts do not use `--force`.
- `--check-access` requires `RCLONE_TEST` on both sides, helping detect missing mounts and wrong or inaccessible remote paths.
- `--resilient` lets later runs retry after certain less-serious errors instead of immediately requiring a resync. Rclone documents this as a use-at-your-own-risk option.
- `--recover` lets rclone recover automatically from some interruptions without requiring `--resync`.

Normal bisync propagates changes and deletions in both directions. It does not silently set a permanent local-or-remote winner; review rclone's conflict output. Resync is different: the explicit `RESYNC_MODE` policy determines how conflicting versions are resolved and can overwrite files. Keep the default dry-run and use `--execute` only after reviewing it.

If bisync reports that `--resync` is required:

1. Stop or pause the timer while investigating: `systemctl --user stop rclone-bisync.timer`.
2. Check the affected local and remote paths, mounts, markers, and the service journal.
3. Run `./scripts/resync.sh` and review the dry-run.
4. If the proposed result is correct, run `./scripts/resync.sh --execute`.
5. Start the timer again: `systemctl --user start rclone-bisync.timer`.

Bisync state under `~/.cache/rclone/bisync` is machine-local runtime state. It is not repository configuration and must not be committed or copied between machines. A new clone or machine should initialize the root pair with `scripts/resync.sh`.

Do not run Insync or another bidirectional synchronization client against these same local folders at the same time. Multiple sync engines can race and produce conflicts or data loss.
