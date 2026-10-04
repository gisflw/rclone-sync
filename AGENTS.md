# Repository instructions

## Purpose and layout

This is a small Bash setup for manual one-way `rclone sync` between `LOCAL_ROOT`
and the root of `REMOTE_NAME`. Keep code minimal, reuse existing scripts, and
add no dependencies or configuration layers.

- `local.env`: tracked shell-compatible configuration containing non-secret
  paths and the remote name. `LOCAL_ROOT` must be absolute and already exist.
- `filters.txt`: shared rclone filters. Preserve generated-file exclusions and
  synchronization of nested `.git/` directories.
- `scripts/cloud-pull.sh` and `scripts/local-push.sh`: convenience wrappers around
  `scripts/directional-sync.sh`.
- `scripts/directional-sync.sh`: maps roots or an optional relative `--folder`,
  then executes exactly one `rclone sync` with shared filters and progress output.
- `tests/smoke.sh`: isolated smoke test with a mocked rclone and temporary HOME.

## Behavior and scope

- Commands apply changes immediately. Pass `--dry-run` to preview; do not add
  `--execute`, marker checks, locks, remote discovery, bisync state, or timers.
- Sync overwrites destination files and can delete files absent from the source.
  Keep that behavior clear in documentation.
- A missing local root remains an error; scripts must not create it.
- `--folder relative/path` precedes rclone flags and maps to the same subfolder
  on both sides. Reject absolute paths and `..` components. Pull may create a
  destination subfolder; push requires its local source directory to exist.
- Forward custom rclone arguments unchanged and preserve rclone's exit status.
- Keep authentication and rclone installation outside this repository.
  Never commit credentials, OAuth tokens, `rclone.conf`, logs, or runtime state.
- Do not run real synchronization or change installed user units to test edits.
  Use the isolated smoke test.

## Documentation

- Use one explanation followed by one command per shell snippet. Keep unrelated
  operations in separate snippets.
- Label configuration examples as configuration, not commands to execute.
- State the working directory and any shell variables required by later steps.
- Explain immediate execution, destination deletions, and optional dry-run
  behavior before showing transfer commands.
- Explain default flags and documented optional flags; keep examples consistent
  with the scripts.

## Validation

Check Bash syntax after script changes (check each script individually):

```bash
for script in scripts/*.sh tests/smoke.sh; do bash -n "$script" || exit; done
```

Run the isolated smoke test after script changes:

```bash
bash tests/smoke.sh
```

Check the diff for whitespace errors before finishing any change:

```bash
git diff --check
```

For documentation-only changes, review commands against the source and check
snippet formatting; no real sync is needed.
