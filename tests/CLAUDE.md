# tests

## Macro
Two suites that exercise Nelly end to end. `smoke.sh` is the fast offline gate run
on every push; `e2e.sh` is the real-Docker pipeline run where a daemon is
available. Both scaffold throwaway deployments under `containers/`, drive the
`bin/nelly` CLI, and clean up after themselves. They are the executable contract
for the behaviors described in the README's Development section.

## Files

### smoke.sh
Offline assertion suite — no Docker. Inputs: the repo (`cd`s to project root via
its own path); requires `bash`, `jq`, `rsync`; optionally `shellcheck`. Moves any
real `bot/` aside before running and restores it on exit. Exercises bash syntax,
help/version, `init -y → validate`, the `app`/`secrets`/`config`/`tag` surfaces,
atomic invalid-config rejection, `explain`/`doctor`/`cron`/`plan`, export/import,
clone, backup/restore, the snapshot bundle, `all list`, and `--json` output.
Outputs: `ok`/`FAIL` lines per assertion to stdout; non-zero exit if any fail; a
cleanup trap removes `containers/smoketest-*` and temp files.

### e2e.sh
Full pipeline against a real Docker daemon. Inputs: the repo + a working `docker`
(exits 0 as "skipped" if `docker info` fails); creates a temp local source and a
`containers/nelly-e2e-<pid>` deployment. Covers `init`+`app add` (local source),
global + per-app secrets, `deploy --wait-healthy --auto-rollback`, cron firing +
`metrics.jsonl` appearing, `run-now`, metrics aggregation, release create/finalize/
restore, a second deploy + image-prune, snapshot quiesce→volume-tar→restart-guard
+ verify, stop/start, and `bot notify` callability. Outputs: `ok`/`FAIL`/`--`
lines to stdout; non-zero exit on failure; a cleanup trap removes the container
and temp dirs.

## Subdirectories
None.
