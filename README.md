# Reproducible `rclone bisync` setup

This repository runs one independent `rclone bisync` pair for every active line in `config/includes.txt`. Each pair has its own rclone bisync state, so a failure in one Drive folder does not combine its state with another folder.

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
${EDITOR:-vi} config/local.env
${EDITOR:-vi} config/includes.txt
```

`config/local.env` is shell-compatible and should contain only non-secret paths and names:

```bash
LOCAL_ROOT="$HOME/gdrive"
REMOTE_NAME="gdrive"
```

`config/includes.txt` has one path per independent pair. Blank lines and lines beginning with `#` are ignored. Spaces in folder names are supported. For example, `Projs` means:

```text
$LOCAL_ROOT/Projs  <->  gdrive:Projs
```

Make sure the intended local filesystem is mounted, then create the local root. The scripts refuse to create a missing root because an unavailable mount can otherwise look like an empty directory:

```bash
source config/local.env
mkdir -p "$LOCAL_ROOT"
```

Before the first resync, create and verify an `RCLONE_TEST` marker in every configured pair. Do not overwrite an existing marker. Repeat this for each non-comment folder in `config/includes.txt`:

```bash
source config/local.env
folder="Projs"  # replace with one configured folder

mkdir -p "$LOCAL_ROOT/$folder"
if [[ ! -e "$LOCAL_ROOT/$folder/RCLONE_TEST" ]]; then
    : > "$LOCAL_ROOT/$folder/RCLONE_TEST"
fi

rclone mkdir "$REMOTE_NAME:$folder"
if ! rclone lsf --files-only "$REMOTE_NAME:$folder/RCLONE_TEST" >/dev/null 2>&1; then
    rclone touch "$REMOTE_NAME:$folder/RCLONE_TEST"
fi

test -f "$LOCAL_ROOT/$folder/RCLONE_TEST"
rclone lsf --files-only "$REMOTE_NAME:$folder/RCLONE_TEST"
```

The local and remote marker paths must both exist. `--check-access` makes every bisync operation abort if the expected marker is missing; this helps catch an unavailable local mount or the wrong remote path.

## First synchronization

`resync.sh` is dry-run by default. Review the proposed changes for all pairs:

```bash
./resync.sh
```

You can inspect one pair at a time:

```bash
./resync.sh Projs
```

The real resync requires the explicit `--execute` argument:

```bash
./resync.sh --execute
./resync.sh Projs --execute
```

The script explicitly passes `--resync-mode newer` by default. Review or change `RESYNC_MODE` near the top of `resync.sh` (or set `RCLONE_BISYNC_RESYNC_MODE`) before executing. Resync can overwrite files or delete one side according to that policy, so do not run it blindly.

After initialization, run normal bidirectional synchronization with:

```bash
./bisync.sh
```

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

The service is `Type=oneshot`, and both scripts use the same non-blocking `flock` lock at `~/.cache/rclone-bisync.lock`, outside the repository. A timer invocation, a manual run, and a resync cannot overlap.

## Adding folders and changing filters

Add or remove paths in the tracked `config/includes.txt`. Each newly added folder needs its local and remote `RCLONE_TEST` markers, followed by initialization with a dry-run and then an explicit real resync:

```bash
./resync.sh NewFolder
./resync.sh NewFolder --execute
```

Removing a line stops future runs for that pair; it does not delete the folder or manually clean its machine-local bisync state.

> Important: changing `filters.txt` changes the files visible to bisync and may require a resync. Review a dry-run before using `./resync.sh --execute`.

Generated environments and temporary files are excluded by `filters.txt`. `.git/` is intentionally not excluded: Git repositories stored inside the synchronized folders are synchronized completely.

## Safety and recovery

- `--max-delete 10` makes rclone abort when a run predicts more than ten deletions for a pair. The scripts do not use `--force`; this is a guardrail, not a backup.
- `--check-access` requires `RCLONE_TEST` on both sides before a pair runs, helping detect missing mounts and wrong or inaccessible remote paths.
- `--resilient` lets later runs retry after certain less-serious errors instead of immediately requiring a resync. Rclone documents this as a use-at-your-own-risk option.
- `--recover` lets rclone recover automatically from some interruptions without requiring `--resync`.

Normal bisync propagates changes and deletions in both directions. It does not silently set a permanent local-or-remote winner; review rclone's conflict output. Resync is different: the explicit `RESYNC_MODE` policy determines how disagreements are resolved and can be destructive. Keep the default dry-run and use `--execute` only after reviewing it.

If bisync reports that `--resync` is required:

1. Stop or pause the timer while investigating: `systemctl --user stop rclone-bisync.timer`.
2. Check the affected local and remote folders, mounts, markers, and the service journal.
3. Run `./resync.sh Folder` and review the dry-run.
4. If the proposed result is correct, run `./resync.sh Folder --execute`.
5. Start the timer again: `systemctl --user start rclone-bisync.timer`.

Bisync state under `~/.cache/rclone/bisync` is machine-local runtime state. It is not repository configuration and must not be committed or copied between machines. A new clone or machine should initialize each selected pair with `resync.sh` instead.

Do not run Insync or another bidirectional synchronization client against these same local folders at the same time. Multiple sync engines can race and produce conflicts or data loss.
