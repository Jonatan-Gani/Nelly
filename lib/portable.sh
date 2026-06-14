#!/usr/bin/env bash
# lib/portable.sh — make deployments portable.
#
#   export  <name> [--include-secrets] [--include-lockfile]
#       Print a self-contained JSON description of the deployment to stdout.
#       Secrets are OMITTED by default. If --include-secrets is passed, the
#       .env contents are base64-encoded into the export. The export carries
#       a `secrets_included: true` flag and a loud warning.
#
#   import  <path|-> [--as <name>] [--force]
#       Create a new deployment from an export file (or stdin). The new name
#       defaults to the export's `deployment` field; --as overrides it.
#
#   clone   <src> <dest>
#       Equivalent to: export <src> | import - --as <dest>. Secrets are not copied.
#
#   init-from <path> <name>
#       Like `nelly init <name> -y`, but loads config from an export file.
#
# Export format (version 1):
#   {
#     "nelly_export_version": 1,
#     "deployment": "...",
#     "exported_at": "ISO-8601",
#     "config":        { ...contents of def/config.json... },
#     "lockfile":      { ... },                   // only if --include-lockfile
#     "secrets_b64":   "...",                     // only if --include-secrets
#     "secrets_included": false | true
#   }

set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

EXPORT_VERSION=1

usage() {
    cat <<'EOF'
portable.sh export    <deploy_dir> [--include-secrets] [--include-lockfile]
portable.sh import    <path|->     [--as <name>] [--force]
portable.sh clone     <src_dir>    <new_name>
portable.sh init-from <path>       <new_name>
EOF
}

sub="${1:-}"; shift || true

case "$sub" in

    export)
        DEPLOY_DIR="${1:-}"; shift || true
        [[ -d "$DEPLOY_DIR" ]] || die "not a deployment: $DEPLOY_DIR"

        INCLUDE_SECRETS=0
        INCLUDE_LOCKFILE=0
        while (( $# > 0 )); do
            case "$1" in
                --include-secrets)  INCLUDE_SECRETS=1;  shift ;;
                --include-lockfile) INCLUDE_LOCKFILE=1; shift ;;
                *) die "unknown flag: $1" ;;
            esac
        done

        validate_config "$DEPLOY_DIR" >/dev/null
        name="$(basename "$DEPLOY_DIR")"
        config="$(jq . "$DEPLOY_DIR/def/config.json")"

        args=(-n --argjson v "$EXPORT_VERSION" --arg name "$name"
              --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              --argjson cfg "$config")
        filter='{
            nelly_export_version: $v,
            deployment: $name,
            exported_at: $ts,
            config: $cfg,
            secrets_included: false
        }'

        if (( INCLUDE_LOCKFILE )) && [[ -f "$DEPLOY_DIR/def/commits.lock.json" ]]; then
            args+=(--argjson lock "$(jq . "$DEPLOY_DIR/def/commits.lock.json")")
            filter+=' + {lockfile: $lock}'
        fi

        if (( INCLUDE_SECRETS )) && [[ -s "$DEPLOY_DIR/def/.env" ]]; then
            warn "exporting secrets — handle this file like a password"
            b64="$(base64 -w0 < "$DEPLOY_DIR/def/.env")"
            args+=(--arg secrets "$b64")
            filter+=' + {secrets_b64: $secrets, secrets_included: true}'
        fi

        jq "${args[@]}" "$filter"
        ;;

    import)
        path="${1:-}"; shift || true
        [[ -n "$path" ]] || die "usage: import <path|->"
        as=""
        force=0
        while (( $# > 0 )); do
            case "$1" in
                --as)    as="$2"; shift 2 ;;
                --force) force=1; shift ;;
                *) die "unknown flag: $1" ;;
            esac
        done

        if [[ "$path" == "-" ]]; then
            payload="$(cat)"
        else
            [[ -f "$path" ]] || die "no such file: $path"
            payload="$(cat "$path")"
        fi
        echo "$payload" | jq -e . >/dev/null 2>&1 || die "import payload is not valid JSON"

        version="$(echo "$payload" | jq -r '.nelly_export_version // empty')"
        [[ "$version" == "$EXPORT_VERSION" ]] \
            || die "unsupported export version: $version (this build understands $EXPORT_VERSION)"

        src_name="$(echo "$payload" | jq -r '.deployment // empty')"
        new_name="${as:-$src_name}"
        [[ -n "$new_name" ]] || die "no deployment name in export and --as not given"
        [[ "$new_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]] \
            || die "invalid deployment name: $new_name"

        dest="$NELLY_ROOT/containers/$new_name"
        if [[ -e "$dest" ]]; then
            if (( force )); then
                rm -rf "$dest"
            else
                die "$dest already exists (pass --force to overwrite)"
            fi
        fi

        # Scaffold from the template, then overlay config.
        cp -r "$NELLY_ROOT/containers/template" "$dest"
        echo "$payload" | jq '.config' > "$dest/def/config.json"

        # If --as was used we want the new name to be reflected in the config.
        if [[ -n "$as" ]]; then
            "$LIB/config.sh" set "$dest" '.container_name' "$new_name" >/dev/null
            "$LIB/config.sh" set "$dest" '.image_name'     "${new_name,,}" >/dev/null
        fi

        validate_config "$dest" >/dev/null

        if [[ "$(echo "$payload" | jq -r '.lockfile // empty')" != "" ]]; then
            echo "$payload" | jq '.lockfile' > "$dest/def/commits.lock.json"
            info "imported lockfile"
        fi

        if [[ "$(echo "$payload" | jq -r '.secrets_included // false')" == "true" ]]; then
            warn "import includes secrets — writing def/.env (mode 0600)"
            echo "$payload" | jq -r '.secrets_b64' | base64 -d > "$dest/def/.env"
            chmod 600 "$dest/def/.env"
        fi

        info "imported deployment '$new_name' from $path"
        info "next: nelly explain $new_name && nelly doctor $new_name"
        ;;

    clone)
        src_dir="${1:-}"; new_name="${2:-}"
        [[ -d "$src_dir" && -n "$new_name" ]] || die "usage: clone <src_dir> <new_name>"
        # Pipe export → import to keep both code paths exercised.
        "$0" export "$src_dir" --include-lockfile | "$0" import - --as "$new_name"
        ;;

    init-from)
        path="${1:-}"; new_name="${2:-}"
        [[ -n "$path" && -n "$new_name" ]] || die "usage: init-from <path> <name>"
        if [[ "$path" == "-" ]]; then
            cat | "$0" import - --as "$new_name"
        else
            "$0" import "$path" --as "$new_name"
        fi
        ;;

    *) usage; exit 2 ;;
esac
