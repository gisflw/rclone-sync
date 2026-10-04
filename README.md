# Cloud pull and local push

Two manual commands synchronize `LOCAL_ROOT` with the root of `REMOTE_NAME`:
cloud pull before a session, local push during work and before switching machines.

Both commands **apply changes immediately** using `rclone sync`. The source wins:
differing destination files are overwritten, and destination files absent from the
source are deleted. Files excluded by filters are normally left alone. Add
`--dry-run` to preview without changing files. There is no bidirectional merge,
marker setup, lock, timer, or initialization step.

## Configuration

Install Bash and rclone separately, and configure your remote with `rclone config`.
Authentication is outside this repository; never commit credentials or `rclone.conf`.

Enter your clone. The examples below run from this directory; the scripts also
work when invoked by their absolute paths from another directory:

```bash
cd ~/rclone-bisync
```

Edit `local.env`. This is shell-compatible **configuration**, not a command to run:

```dotenv
LOCAL_ROOT="$HOME/gdrive"
REMOTE_NAME="gdrive"
```

`LOCAL_ROOT` must be an absolute, existing directory on each machine. The scripts
do not create the root. `REMOTE_NAME` is the configured rclone remote name, without
a colon or path; `gdrive` maps to `gdrive:`. No shell variables need to be loaded
for the following commands: the scripts read `local.env` themselves.

## Session workflow

Preview a cloud pull when you want to inspect the changes first:

```bash
./scripts/cloud-pull.sh --dry-run
```

Pull at the beginning of your session to make local files match the cloud:

```bash
./scripts/cloud-pull.sh
```

Push during work and at the end to make the cloud match your local files:

```bash
./scripts/local-push.sh
```

Finish pushing successfully before pulling on another machine. Pulling overwrites
unpushed local changes; pushing from an outdated machine overwrites cloud changes.
Let one command finish before starting another.

## Sync one folder

Put `--folder relative/path` before any rclone flags. The same relative path is
appended on both sides: `projects/example` maps to
`$LOCAL_ROOT/projects/example` and `gdrive:projects/example`. Only that subtree is
synchronized; sibling folders are untouched. Absolute paths and `..` components
are rejected. Quote folder names containing spaces.

Pull only the chosen folder. A missing local destination subfolder can be created
by rclone, but the local root must already exist:

```bash
./scripts/cloud-pull.sh --folder projects/example
```

Push that folder. Its local source directory must exist:

```bash
./scripts/local-push.sh --folder projects/example
```

Preview a folder pull with a name containing spaces:

```bash
./scripts/cloud-pull.sh --folder "projects/example" --dry-run
```

## Flags and filters

The scripts supply just two default flags:

| Flag | Reason |
| --- | --- |
| `--filter-from filters.txt` | Apply the shared exclusions using the file's absolute repository path. |
| `--progress` | Show live transfer statistics. Disable with `--progress=false`. |

All other arguments are passed directly to rclone, with quoted arguments preserved.
Useful optional flags include:

| Flag | Effect |
| --- | --- |
| `--dry-run` / `-n` | Preview changes without applying them. |
| `--verbose` / `-v` | Show more detail, including transferred files. |
| `--checksum` / `-c` | Compare size and checksums instead of modification times; uses size only if no common checksum is available and can require more work. |
| `--exclude '*.zip'` | Add an exclusion for this invocation; quote patterns so the shell does not expand them. |

Preview a folder pull using checksum comparison and detailed output:

```bash
./scripts/cloud-pull.sh --folder projects/example --dry-run --checksum --verbose
```

Edit `filters.txt` for persistent exclusions. Its current generated-file and
junk exclusions apply to every command; nested `.git/` directories are included.
Filter paths are relative to the selected sync root: with `--folder projects/example`,
`/retired/` excludes `projects/example/retired/`, rather than the top-level
`retired/` folder. Selecting a folder directly bypasses exclusions on its parents.
Extra filter flags add to rclone's filtering rules; they do not automatically
replace the shared file.

## Transfer speed

These optional settings use rclone's defaults unless you pass a different value.
Tune one at a time; more concurrency can help until bandwidth, disk speed, or
remote API throttling becomes the bottleneck.

| Flag | Default | Description |
| --- | --- | --- |
| `--transfers` | `4` | Files transferred in parallel. Try `8` for many files on a fast connection; reduce if timeouts increase. |
| `--bwlimit` | Unlimited | Cap transfer bandwidth, for example `4M` for 4 MiB/s. Leave unset for maximum available speed. |
| `--checkers` | `8` | Parallel file comparisons. Try `16` if checking is slow and the remote handles extra requests. |
| `--fast-list` | `false` | Use recursive listings where supported, reducing API requests at the cost of more RAM. Compare timings on your remote. |
| `--buffer-size` | `16Mi` | Read buffer per transfer. Try `32Mi` if buffering helps; memory use grows with simultaneous transfers. |
| `--multi-thread-streams` | `4` | Streams per large file on supported destinations. Try `8` for large cloud pulls; Google Drive uploads do not support this mode. |
| `--multi-thread-cutoff` | `256Mi` | File size above which multithread transfers are used. Lowering it enables parallel streams for smaller files, with extra overhead. |

Defaults were checked against rclone v1.69.3. See
[rclone's tuning documentation](https://rclone.org/docs/#transfers-int) for details.

Try pushing with more concurrent file transfers and comparisons:

```bash
./scripts/local-push.sh --transfers 8 --checkers 16
```

Try pulling large files with more streams per file:

```bash
./scripts/cloud-pull.sh --folder projects/example --multi-thread-streams 8
```

Push with a bandwidth limit and two simultaneous transfers:

```bash
./scripts/local-push.sh --transfers 2 --bwlimit 4M
```

For full flag semantics, see [rclone's flag reference](https://rclone.org/flags/),
[sync documentation](https://rclone.org/commands/rclone_sync/), and
[filtering documentation](https://rclone.org/filtering/).
