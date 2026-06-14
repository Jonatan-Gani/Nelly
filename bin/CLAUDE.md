# bin

## Macro
The single entry point users touch. `nelly` parses global flags, renders help,
resolves a deployment name to its directory, and dispatches every subcommand to
the matching `lib/*.sh` script. It also owns the one piece of orchestration that
isn't in a lib module: the full `deploy` pipeline, run inside a per-deployment
`flock` as a fixed single-quoted subshell so no config value or CLI argument can
alter what executes.

## Files
### nelly
CLI dispatcher and deploy orchestrator (bash, no extension).
Inputs: argv (subcommand + args + global flags `--json`, `-i/--interactive`,
`-y/--yes`, `--version`, `-h/--help`, `help <cmd>`); env it sets/exports
(`NELLY_ROOT`, `NELLY_OUTPUT` default `human`, `INTERACTIVE`, `NELLY_YES`);
sources `lib/common.sh` and `lib/hooks.sh`. Resolves `<name>` to
`$NELLY_ROOT/containers/<name>` via `_deploy_dir` (dies if missing).
Outputs: delegates to `lib/*.sh` (their stdout/files are the real output); the
`deploy` path calls `release.sh create` → `hooks.sh pre_deploy` → `fetch.sh` →
`build.sh` → `run.sh` (optional `--wait-healthy N` / `--auto-rollback`) →
`release.sh finalize` → `post_deploy`/`on_failure` hook → `prune.sh` →
`image-prune.sh`, all under `with_lock`. Errors: `die`/`err` from common.sh
(stderr `[ERROR]`, exit 1); unknown command prints `Try: nelly help` and exits 2.
`base-image-pin` is implemented inline here (pulls an image, resolves its
`@sha256:` digest, writes `.base_image` via `config.sh set`).
