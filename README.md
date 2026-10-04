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

The scripts supply shared filters, logging, and progress output, plus the defaults listed
in the transfer-speed section:

| Flag | Reason |
| --- | --- |
| `--filter-from filters.txt` | Apply the shared exclusions using the file's absolute repository path. |
| `--progress` | Show live transfer statistics. Disable with `--progress=false`. |
| `--verbose` | Record per-file messages at INFO level. |
| `--log-file rclone.log` | Append rclone messages to this file in the repository, keeping terminal output focused on progress. |

Additional arguments are passed directly to rclone after the defaults, with quoted
arguments preserved. Custom values override the corresponding default settings.
Useful optional flags include:

| Flag | Effect |
| --- | --- |
| `--dry-run` / `-n` | Preview changes without applying them. |
| `--verbose` / `-v` | Add DEBUG detail to the log, since verbose logging is already enabled by default. |
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

## Logs

Both commands append verbose messages, including rclone errors, to `rclone.log`
in the repository directory. The existing `*.log` rule in `.gitignore` excludes
it from Git. Progress stays in the terminal; shell configuration errors still
appear there. A failed sync returns a nonzero exit status; read the log for details.
The log is appended across runs without automatic rotation.

Read the latest log messages from the repository directory:

```bash
tail -n 50 rclone.log
```

Choose a different log file for a particular run:

```bash
./scripts/local-push.sh --log-file "$HOME/local-push.log"
```

See [rclone's logging documentation](https://rclone.org/docs/#log-file-file) for details.

## Transfer speed

The Default column shows the settings used by these scripts. They enable
`--fast-list` and `--check-first`, set `--checkers 32`, `--transfers 16`, and `--buffer-size 32M`,
and leave the remaining settings at rclone's defaults. Pass flags to override them.
Tune one at a time; more concurrency can help until bandwidth, disk speed, or
remote API throttling becomes the bottleneck.

| Flag | Default | Description |
| --- | --- | --- |
| `--transfers` | `16` | Files transferred in parallel. Reduce if timeouts increase or bandwidth is already saturated. |
| `--bwlimit` | Unlimited | Cap transfer bandwidth, for example `4M` for 4 MiB/s. Leave unset for maximum available speed. |
| `--checkers` | `32` | Parallel file comparisons. Reduce if the remote throttles requests. |
| `--fast-list` | `true` | Use recursive listings where supported, reducing API requests at the cost of more RAM. Disable with `--fast-list=false`. |
| `--check-first` | `true` | Finish all file comparisons before transferring, avoiding competition for disk I/O but delaying transfers and using more RAM. Disable with `--check-first=false`. |
| `--buffer-size` | `32M` | Read buffer per transfer (32 MiB). Memory use grows with simultaneous transfers; pass a smaller value to reduce it. |
| `--multi-thread-streams` | `4` | Streams per large file on supported destinations. Try `8` for large cloud pulls; Google Drive uploads do not support this mode. |
| `--multi-thread-cutoff` | `256Mi` | File size above which multithread transfers are used. Lowering it enables parallel streams for smaller files, with extra overhead. |

The inherited rclone defaults were checked against v1.69.3. See
[rclone's tuning documentation](https://rclone.org/docs/#transfers-int) for details.

Push with reduced concurrency if the remote is throttling requests:

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
