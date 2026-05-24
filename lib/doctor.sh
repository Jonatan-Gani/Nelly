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
                if git ls-remote --exit-code -- "$url" "$ref" >/dev/null 2>&1; then
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

# ---- 5. secrets file modes + presence --------------------------------------

if [[ -f "$ENV_FILE" ]]; then
    n_keys="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/' "$ENV_FILE" | wc -l | tr -d ' ')"
    mode="$(stat -c %a "$ENV_FILE")"
    if [[ "$mode" == "600" ]]; then
        ok "global secrets file present ($n_keys key(s), mode 0600)"
    else
        bad "global secrets file mode is $mode, not 0600 ($ENV_FILE)"
    fi
else
    warn_ "no def/.env — if your apps need shared secrets, run: nelly secrets set $name KEY=value"
fi

# Per-app secrets
if [[ -d "$DEPLOY_DIR/def/secrets" ]]; then
    for f in "$DEPLOY_DIR/def/secrets"/*.env; do
        [[ -f "$f" ]] || continue
        app="$(basename "$f" .env)"
        m="$(stat -c %a "$f")"
        if [[ "$m" == "600" ]]; then
            ok "per-app secrets for '$app' present (mode 0600)"
        else
            bad "secrets file for '$app' mode is $m, not 0600 ($f)"
        fi
    done
fi

# ---- 5b. base image pinning ------------------------------------------------

base_img="$(jqget "$CONFIG" '.base_image' '')"
if [[ -n "$base_img" ]]; then
    if [[ "$base_img" == *@sha256:* ]]; then
        ok "base image pinned to a digest ($base_img)"
    else
        warn_ "base image is set but not pinned to a sha256 digest — run: nelly base-image-pin $name"
    fi
else
    warn_ "no base_image pinned in config — builds may not be reproducible across time"
fi

# ---- 5c. requirements pinning for each app --------------------------------

for app in "${APPS[@]}"; do
    aname="$(echo "$app" | jq -r '.app_name')"
    req="$DEPLOY_DIR/apps/$aname/requirements.txt"
    [[ -f "$req" ]] || continue
    # An unpinned requirement looks like `requests` or `requests>=2`; pinned
    # looks like `requests==2.31.0`. Warn if any non-comment line lacks `==`.
    if grep -Ev '^\s*(#|$)' "$req" | grep -v '==' >/dev/null 2>&1; then
        warn_ "$aname/requirements.txt has unpinned packages (no '==')"
    else
        ok "$aname/requirements.txt: all pinned (==)"
    fi
done

# ---- 5d. docker disk usage -------------------------------------------------

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    total_mb="$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || true)"
    img_count="$(docker images "$(jqget "$CONFIG" '.image_name')" -q 2>/dev/null | wc -l | tr -d ' ')"
    ok "this deployment has $img_count Docker image(s) on disk"
fi

# ---- 5e. bot config (if any) ------------------------------------------------

if [[ -f "$NELLY_ROOT/bot/config.json" ]]; then
    bot_cfg_mode="$(stat -c %a "$NELLY_ROOT/bot/config.json")"
    [[ "$bot_cfg_mode" == "600" ]] && ok "bot/config.json mode 0600" || bad "bot/config.json mode $bot_cfg_mode"
    if [[ -f "$NELLY_ROOT/bot/.token" ]]; then
        token_mode="$(stat -c %a "$NELLY_ROOT/bot/.token")"
        [[ "$token_mode" == "600" ]] && ok "bot/.token mode 0600" || bad "bot/.token mode $token_mode"
    fi
    n_users="$(jq -r '.allowed_users | length' "$NELLY_ROOT/bot/config.json")"
    (( n_users > 0 )) && ok "bot has $n_users allowed user(s)" || warn_ "bot has no allowed users"
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
