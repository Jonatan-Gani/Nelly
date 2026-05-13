#!/usr/bin/env bash
# lib/doctor.sh — check a deployment for common problems before deploy.
set -euo pipefail
DEPLOY_DIR="$1"
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
ENV_FILE="$DEPLOY_DIR/def/.env"
name="$(basename "$DEPLOY_DIR")"

PROBLEMS=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn_() { printf '  \033[33m!\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }

echo "Checking deployment '$name'…"
echo

# ---- 1. config validation --------------------------------------------------

if validate_config "$DEPLOY_DIR" 2>/dev/null; then
    ok "config.json is valid"
else
    bad "config.json is invalid — run: nelly validate $name"
fi

# ---- 2. apps actually do something ----------------------------------------

n_apps="$(jq '.apps | length' "$CONFIG")"
if (( n_apps == 0 )); then
    warn_ "no apps configured — try: nelly app add $name"
fi

n_scheduled="$(jq '[.apps[] | select((.schedule // "") != "" and (.entrypoint // "") != "")] | length' "$CONFIG")"
if (( n_apps > 0 && n_scheduled == 0 )); then
    warn_ "no app has both a schedule and an entrypoint — nothing will run on cron"
fi

# ---- 3. sources reachable --------------------------------------------------

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")
for app in "${APPS[@]}"; do
    aname="$(echo "$app" | jq -r '.app_name')"
    stype="$(echo "$app" | jq -r '.source.type // (if .git_url then "git" else "?" end)')"
    case "$stype" in
        git)
            url="$(echo "$app" | jq -r '.source.url // .git_url')"
            ref="$(echo "$app" | jq -r '.source.ref // .ref // .branch // "main"')"
            if command -v git >/dev/null 2>&1; then
                if git ls-remote --exit-code "$url" "$ref" >/dev/null 2>&1; then
                    ok "git source reachable: $aname ($url @ $ref)"
                else
                    bad "git source not reachable: $aname ($url @ $ref) — check URL, ref, and SSH credentials"
                fi
            fi
            ;;
        local)
            path="$(echo "$app" | jq -r '.source.path')"
            if [[ -d "$path" ]]; then
                ok "local source exists: $aname → $path"
            else
                bad "local source missing: $aname → $path"
            fi
            ;;
        *)
            bad "$aname has an unknown source type ($stype)"
            ;;
    esac
done

# ---- 4. entrypoint exists in fetched apps/<name> if already fetched --------

for app in "${APPS[@]}"; do
    aname="$(echo "$app" | jq -r '.app_name')"
    entry="$(echo "$app" | jq -r '.entrypoint // ""')"
    [[ -z "$entry" ]] && continue
    fetched_dir="$DEPLOY_DIR/apps/$aname"
    if [[ -d "$fetched_dir" ]]; then
        if [[ -f "$fetched_dir/$entry" ]]; then
            ok "entrypoint exists: $aname → $entry"
        else
            warn_ "entrypoint not found yet for $aname: apps/$aname/$entry  (re-fetch may fix it: nelly fetch $name)"
        fi
    fi
done

# ---- 5. secrets referenced by config but missing in .env -------------------

if [[ -f "$ENV_FILE" ]]; then
    n_keys="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/' "$ENV_FILE" | wc -l | tr -d ' ')"
    ok ".env present ($n_keys key(s), mode $(stat -c %a "$ENV_FILE"))"
else
    warn_ "no def/.env — if your apps need secrets, run: nelly secrets set $name KEY=value"
fi

# ---- 6. docker available ---------------------------------------------------

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "docker is available"
    else
        bad "docker is installed but not running (or current user lacks permission)"
    fi
else
    bad "docker not found in PATH"
fi

# ---- 7. host requirements --------------------------------------------------

for cmd in jq git rsync; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd present"
    else
        bad "$cmd missing — install before deploying"
    fi
done

echo
if (( PROBLEMS == 0 )); then
    echo "All checks passed. Ready: nelly deploy $name"
else
    echo "$PROBLEMS issue(s) found above."
    exit 1
fi
