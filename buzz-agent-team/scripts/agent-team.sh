#!/bin/bash
# agent-team.sh: prepare, authorize and run a set of Buzz agents for one workspace.
# Bash 3.2+ (macOS /bin/bash). Run "agent-team.sh help" for the full usage.
#
# For one workspace folder and one Buzz channel this makes one home folder per agent:
#   ${AGENT_TEAM_ROOT:-~/.buzz-agents}/<workspace name>/<agent id>/
#     identity.key         the agent's secret key (mode 600; nothing else holds it)
#     .env.buzz-acp.local  settings for run-buzz-acp.sh (mode 600; no secret key)
#     prompt.md            the agent's role instructions, then the workspace brief if there is one
#     agent.conf           public facts: id, role, display name, public key, backend
#     runtime/, subscriptions.toml   the channel supervisor's restricted runtime and the rules that
#                          decide which messages start its turn (a reviewer has the runtime only)
#     start.sh             that agent's own start command, a copy of templates/agent-start.sh: it
#                          starts this agent only, through team.sh
# and, beside the agent folders, brief.md: the user's optional note about the workspace, and
# team.sh: that team's own command (check, start, stop, status), a copy of templates/team.sh. It
# finds everything from its own location, so a team folder runs and moves without this skill.
# VERSION there is the version of this skill that created or last upgraded the folder.
# Each agent runs on claude or codex and signs in only through the user's subscription.
# The shared PROJECT.md is initialized in the workspace if absent, and for a workspace agent on Claude
# the workspace first gets its sandbox settings, .claude/settings.json (scripts/workspace-settings.py).
# The root must be outside every Git work tree.
# The root also holds settings.conf (mode 600): public defaults only, written by "settings".
# This script lives in scripts/ of the buzz-agent-team skill folder; templates/ is beside scripts/.
# The skill's version is the one line of VERSION in that folder ("agent-team.sh version").
#
# Typical flow:
#   agent-team.sh preflight                 # what is missing, with one fix line per item
#   agent-team.sh settings --from-env <working env file>   # remember public defaults (optional)
#   agent-team.sh create --workspace ~/code/shop --channel <channel uuid>
#   (Buzz Desktop: Settings > Security > Authorize external identity, once per public key shown)
#   agent-team.sh proof shop assistant      # paste the proof, then Enter
#   agent-team.sh proof shop supervisor
#   agent-team.sh finish shop --dry-run     # shows the community steps; runs nothing
#   agent-team.sh finish shop
#   cd ~/code/shop                          # the agents work in the folder the team command is run from
#   ~/.buzz-agents/shop/team.sh check       # the team's own command, from here on
#   ~/.buzz-agents/shop/team.sh             # start: asks which agents, then provider and model of each
#   ~/.buzz-agents/shop/team.sh status; ~/.buzz-agents/shop/team.sh stop
#   agent-team.sh upgrade shop --dry-run   # a team made by an earlier version: then without --dry-run

set -euo pipefail
umask 077

PROG=agent-team.sh
ENV_NAME=.env.buzz-acp.local
ALL_ROLES='assistant supervisor reviewer'
# The job of each role id. 3.0.0 swapped the jobs of the two agents of a team; their ids, folders,
# option names and default display names stayed.
#   assistant   the workspace agent: the stock adapter with all its tools, worker subagents and
#               bypass-permissions; it answers the owner and its channel supervisor
#   supervisor  the channel supervisor: the restricted runtime; it takes a turn on every ordinary
#               message in its channel and talks with anyone there
#   reviewer    the independent reviewer: the restricted runtime; it takes a turn when mentioned
# Every place where the role decides behaviour asks one of these.
is_workspace_role() { [ "$1" = assistant ]; }
is_channel_role() { [ "$1" = supervisor ]; }
# Roles that run the restricted runtime copied into the agent's own folder: file reads inside the
# project folder and the Buzz tools; no edits, no shell, no web. The workspace agent runs the stock adapter.
uses_partner_runtime() { is_channel_role "$1" || [ "$1" = reviewer ]; }
# The team folder format this skill writes (team.conf and agent.conf format=). A team in an earlier
# format is refused by every command that acts on it, until "upgrade" converts it:
#   1   made before 20 November 2026
#   2   made by 1.0.0 or 2.0.0: the assistant was the discussion partner, the supervisor the workspace
#       supervisor
#   3   made by 3.0.0 or later: the assistant is the workspace agent, the supervisor the channel supervisor
FORMAT=3

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- cleanup and lock
TMP_PATHS=()
LOCK_DIR=''
cleanup() {
    local p
    for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do rm -rf -- "$p"; done
    TMP_PATHS=()
    if [ -n "$LOCK_DIR" ]; then rm -rf -- "$LOCK_DIR"; LOCK_DIR=''; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# One writer per workspace folder. A lock left by a killed run is reclaimed when its PID is gone.
take_lock() { # WS_DIR
    local lock=$1/.lock pid=''
    if ! mkdir -m 700 -- "$lock" 2>/dev/null; then
        IFS= read -r pid < "$lock/pid" 2>/dev/null || true
        case $pid in '' | *[!0-9]*)
            die "$1 is locked by another agent-team.sh run. If none is running, remove $lock and retry." ;;
        esac
        if kill -0 "$pid" 2>/dev/null; then
            die "another agent-team.sh run (PID $pid) is changing $1; try again when it ends"
        fi
        rm -rf -- "$lock"
        mkdir -m 700 -- "$lock" 2>/dev/null || die "cannot lock $1; try again"
    fi
    LOCK_DIR=$lock
    printf '%s\n' "$$" > "$lock/pid"
}

# ---------------------------------------------------------------- small helpers
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
lower() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }
shquote() {
    case $1 in
        '') printf "''" ;;
        *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
        *) printf '%s' "$1" ;;
    esac
}
print_cmd() { # INDENT ARGV...: one shell-quoted command line
    local indent=$1 first=yes a
    shift
    printf '%s' "$indent"
    for a in "$@"; do
        if [ "$first" = yes ]; then first=no; else printf ' '; fi
        shquote "$a"
    done
    printf '\n'
}
check_backend() { case $1 in claude|codex) ;; *) die 'choose --backend claude or --backend codex' ;; esac; }
backend_command() { if [ "$1" = codex ]; then printf 'codex-acp'; else printf 'claude-agent-acp'; fi; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

# ---------------------------------------------------------------- backends and sign-in
# Each agent runs on claude or codex (saved per agent) and signs in only through the user's
# subscription: Claude sign-in or ChatGPT sign-in. run-buzz-acp.sh enforces it at every start.
agent_format() { conf_get "$T_DIR/$1/agent.conf" format 2>/dev/null || printf '1'; }
# The saved backend of agent ID: agent.conf's backend=, else the env file's adapter, else claude.
agent_backend() {
    local b=''
    b=$(conf_get "$T_DIR/$1/agent.conf" backend 2>/dev/null) || b=''
    if [ -z "$b" ]; then
        if [ -f "$T_DIR/$1/$ENV_NAME" ]; then b=$(env_get "$T_DIR/$1/$ENV_NAME" BUZZ_ACP_AGENT_COMMAND) || b=''; fi
        case ${b##*/} in codex-acp) b=codex ;; *) b=claude ;; esac
    fi
    printf '%s' "$b"
}
# A credential, endpoint or provider variable of either runtime. Identical to run-buzz-acp.sh (tested).
credential_name() { # NAME
    case $1 in
        ANTHROPIC_* | OPENAI_* | OPENROUTER_* | GOOSE_* | DATABRICKS_* | AWS_BEARER_TOKEN_BEDROCK) return 0 ;;
        CODEX_API_KEY | CODEX_ACCESS_TOKEN | DEFAULT_AUTH_REQUEST | CODEX_CONFIG) return 0 ;;   # CODEX_CONFIG: the stock adapter's config override (providers, endpoints)
        CLAUDE_CODE_OAUTH_* | CLAUDE_CODE_API_KEY_HELPER_TTL_MS | CLAUDE_CODE_SKIP_*_AUTH) return 0 ;;
        CLAUDE_CODE_USE_BEDROCK | CLAUDE_CODE_USE_VERTEX | CLAUDE_CODE_USE_FOUNDRY | CLAUDE_CODE_USE_MANTLE) return 0 ;;
        CLAUDE_CODE_USE_ANTHROPIC_AWS | CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD) return 0 ;;
        CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY | CLAUDE_CODE_GATEWAY_HINT_HEADERS | CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST) return 0 ;;
    esac
    return 1
}
# The credential and endpoint names Claude Code documents for a settings file's "env", plus
# apiKeyHelper. Identical to run-buzz-acp.sh (tested).
CLAUDE_SETTINGS_PATTERN='"(apiKeyHelper|ANTHROPIC_(API_KEY|AUTH_TOKEN|AWS_API_KEY|AWS_BASE_URL|AWS_WORKSPACE_ID|BASE_URL|BEDROCK_BASE_URL|BEDROCK_MANTLE_BASE_URL|CUSTOM_HEADERS|FEDERATION_RULE_ID|FOUNDRY_API_KEY|FOUNDRY_AUTH_TOKEN|FOUNDRY_BASE_URL|FOUNDRY_RESOURCE|GOOGLE_CLOUD_BASE_URL|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_WORKSPACE_ID|ORGANIZATION_ID|PROFILE|VERTEX_BASE_URL|VERTEX_PROJECT_ID|WORKSPACE_ID)|AWS_BEARER_TOKEN_BEDROCK|CLAUDE_CODE_(API_KEY_HELPER_TTL_MS|OAUTH_TOKEN|OAUTH_REFRESH_TOKEN|OAUTH_SCOPES|USE_(BEDROCK|VERTEX|FOUNDRY|MANTLE|ANTHROPIC_AWS|ANTHROPIC_GOOGLE_CLOUD)|SKIP_(BEDROCK|VERTEX|FOUNDRY|MANTLE|ANTHROPIC_AWS|ANTHROPIC_GOOGLE_CLOUD)_AUTH|ENABLE_GATEWAY_MODEL_DISCOVERY|GATEWAY_HINT_HEADERS|PROVIDER_MANAGED_BY_HOST))"[[:space:]]*:'
# Claude settings files that can set env or apiKeyHelper (user, local, project when WORKDIR is known, managed).
claude_settings_files() { # [WORKDIR]
    local cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude} managed=${BUZZ_CLAUDE_MANAGED_DIR:-/Library/Application Support/ClaudeCode} f
    for f in "$cfg/settings.json" "$cfg/settings.local.json" ${1:+"$1/.claude/settings.json"} ${1:+"$1/.claude/settings.local.json"} \
        "$managed/managed-settings.json" "$managed"/managed-settings.d/*.json; do
        if [ -f "$f" ]; then printf '%s\n' "$f"; fi
    done
    return 0
}
claude_settings_overrides() { # FILE: the overriding names it sets, space-separated (names only)
    grep -Eo "$CLAUDE_SETTINGS_PATTERN" "$1" 2>/dev/null | sed -E 's/^"([A-Za-z_]*)".*/\1/' | LC_ALL=C sort -u | tr '\n' ' ' || true
}
codex_config_overrides() { # the top-level Codex config keys that would replace the ChatGPT sign-in
    local f=${CODEX_HOME:-$HOME/.codex}/config.toml
    [ -f "$f" ] || return 0
    awk '
        /^[[:space:]]*\[/ { exit }
        /^[[:space:]]*(model_provider|openai_base_url|chatgpt_base_url|profile|forced_login_method)[[:space:]]*=/ {
            line = $0; sub(/^[[:space:]]*/, "", line); key = line; sub(/[[:space:]]*=.*/, "", key)
            value = line; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/#.*/, "", value); gsub(/["\047[:space:]]/, "", value)
            if (key == "model_provider" && value == "openai") next
            if (key == "forced_login_method" && value == "chatgpt") next
            printf "%s ", key
        }' "$f"
}
bounded() { # SECONDS OUT CMD...: run CMD with its output in OUT; returns 124 when it outlives SECONDS
    local limit=$(($1 * 10)) out=$2 pid i=0
    shift 2
    "$@" > "$out" 2>&1 < /dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$limit" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; fi
        sleep 0.1
        i=$((i + 1))
    done
    wait "$pid"
}
sha256_text() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64; else sha256sum | cut -c1-64; fi; }

# ---------------------------------------------------------------- models
# Each agent keeps one model per backend (agent.conf model_claude= / model_codex=, env BUZZ_MODEL_*),
# so a backend switch never hands a Claude model to Codex or the reverse. Empty = the runtime default.
# A model is accepted when the last list retrieved with "agent-team.sh models" for that backend and
# role offers it; without a retrieved list, when the backend documents it (Claude Code's aliases and
# full model names, model-config; Codex: the bundled catalog of the Codex CLI that role runs).
agent_model() { conf_get "$T_DIR/$1/agent.conf" "model_$2" 2>/dev/null || true; } # ID BACKEND
# Each agent may also keep one reasoning effort per backend (agent.conf effort_claude= / effort_codex=).
# Empty = none set here: Claude Code then uses the user's own level for the model, Codex its own default.
# Claude takes the level as CLAUDE_CODE_EFFORT_LEVEL; Codex takes it in the model name, model[level],
# which the adapter sends as the model and its reasoning effort. Both starts apply it (team.sh and start).
CLAUDE_EFFORTS='low medium high xhigh max'
CODEX_EFFORTS='low medium high xhigh max ultra'
W_EFFORT_CLAUDE='' W_EFFORT_CODEX=''
agent_effort() { conf_get "$T_DIR/$1/agent.conf" "effort_$2" 2>/dev/null || true; } # ID BACKEND
require_effort() { # BACKEND ROLE MODEL LEVEL: refuse a reasoning effort the backend does not offer for MODEL
    local list base levels
    [ -n "$4" ] || return 0
    if [ "$1" = claude ]; then
        case " $CLAUDE_EFFORTS " in *" $4 "*) return 0 ;; esac
        die "$4 is not a Claude reasoning effort for the $2: choose one of $CLAUDE_EFFORTS (or default for none)"
    fi
    base=${3%\[*\]}
    [ -n "$base" ] || die "on Codex a reasoning effort is part of the model name, so the $2 needs a model too: --$2-model ID"
    list=$(models_cache codex "$2")
    if [ -s "$list" ]; then
        if grep -v '^#' "$list" | cut -f1 | grep -Fxq -- "$base[$4]"; then return 0; fi
        levels=$(grep -v '^#' "$list" | cut -f1 | awk -v b="$base" 'index($0, b "[") == 1 { s = substr($0, length(b) + 2); sub(/\]$/, "", s); printf "%s ", s }')
        die "$4 is not a reasoning effort the retrieved list offers for $base on the $2 (it offers: ${levels:-none})"
    fi
    case " $CODEX_EFFORTS " in *" $4 "*) return 0 ;; esac
    die "$4 is not a Codex reasoning effort for the $2: choose one of $CODEX_EFFORTS (or default for none)"
}
# "default" is left out: the launcher hands a model to Claude Code as a model name, and Claude Code
# refuses every turn of an agent whose model is named default. No model saved = the runtime default.
claude_documented_model() { # ID
    case $1 in best | fable | sonnet | opus | haiku | 'sonnet[1m]' | 'opus[1m]' | opusplan) return 0 ;; esac
    [[ $1 =~ ^claude-(opus|sonnet|haiku|fable)-[0-9]+(-[0-9]+)*(\[1m\])?$ ]]
}
claude_label() { # claude-opus-5-5 -> "Opus 5.5" (how the adapter names that model in its list)
    local f
    [[ $1 =~ ^claude-(opus|sonnet|haiku|fable)-([0-9]+)(-([0-9]+))?$ ]] || return 0
    f=${BASH_REMATCH[1]}
    printf '%s%s %s%s' "$(printf '%s' "${f:0:1}" | LC_ALL=C tr 'a-z' 'A-Z')" "${f:1}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:+.${BASH_REMATCH[4]}}"
}
models_cache() { printf '%s/models/%s-%s.list' "$ROOT" "$1" "$2"; } # BACKEND ROLE
codex_cli_of() { # ROLE: the Codex CLI that role's runtime runs
    local acp py=${AGENT_TEAM_PYTHON:-python3}
    if uses_partner_runtime "$1"; then
        # The restricted runtime runs the private engine (runtime/codex-acp); the CLI on PATH stands in.
        if [ -x "$HOME/.local/share/buzz-agent-team/node_modules/.bin/codex" ]; then
            printf '%s' "$HOME/.local/share/buzz-agent-team/node_modules/.bin/codex"
        else command -v codex 2>/dev/null || true; fi
        return 0
    fi
    # The stock adapter runs CODEX_PATH, or else the Codex CLI it bundles (codex-acp dist/index.js,
    # startCodexConnection), never the one on PATH.
    if [ -n "${CODEX_PATH:-}" ]; then printf '%s' "$CODEX_PATH"; return 0; fi
    acp=$(command -v codex-acp 2>/dev/null) || return 0
    [ "$py" != none ] && command -v -- "$py" >/dev/null 2>&1 || return 0
    acp=$("$py" -I -c 'import os,sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$acp" 2>/dev/null) || return 0
    printf '%s' "$acp/node_modules/.bin/codex"
}
codex_bundled_models() { # ROLE: the slugs that role's Codex CLI lists in its bundled catalog, offline
    local cli py=${AGENT_TEAM_PYTHON:-python3}
    cli=$(codex_cli_of "${1:-assistant}")
    [ -n "$cli" ] && [ -x "$cli" ] && [ "$py" != none ] && command -v -- "$py" >/dev/null 2>&1 || return 0
    "$cli" debug models --bundled 2>/dev/null | "$py" -I -c 'import json,sys
t=sys.stdin.read(); i=t.find("{")
try: d=json.loads(t[i:]) if i >= 0 else {}
except ValueError: d={}
for m in d.get("models", []):
    if m.get("visibility") == "list" and m.get("slug"): print(m["slug"])' 2>/dev/null || true
}
model_offered() { # BACKEND ROLE MODEL: 0 when the backend offers MODEL for that role
    local list label
    list=$(models_cache "$1" "$2")
    if [ -s "$list" ]; then
        if grep -v '^#' "$list" | cut -f1 | grep -Fxq -- "$3"; then return 0; fi
        # A full Claude name that the list offers under its alias, e.g. claude-opus-5-5 as "opus: Opus 5.5".
        if [ "$1" = claude ] && claude_documented_model "$3"; then
            label=$(claude_label "$3")
            if [ -n "$label" ] && grep -v '^#' "$list" | cut -f2 | grep -Fq -- "$label"; then return 0; fi
        fi
        return 1
    fi
    if [ "$1" = claude ]; then claude_documented_model "$3"; return; fi
    codex_bundled_models "$2" | grep -Fxq -- "$3"
}
require_model() { # BACKEND ROLE MODEL: refuse a model the backend does not offer, naming what it offers
    local list offered
    [ -n "$3" ] || return 0
    refuse_secret model "$3"
    if [ "$1" = claude ] && [ "$3" = default ]; then
        die "\"default\" names no model: Claude Code would take it as a model name and refuse every turn of the $2. Leave the model out for the runtime default, or name one such as claude-opus-5-5"
    fi
    model_offered "$1" "$2" "$3" && return 0
    list=$(models_cache "$1" "$2")
    if [ -s "$list" ]; then offered="retrieved list: $(grep -v '^#' "$list" | cut -f1 | tr '\n' ' ')"
    elif [ "$1" = claude ]; then offered='documented: the Claude Code aliases and full claude-* model names'
    else offered="documented: $(codex_bundled_models "$2" | tr '\n' ' ')"; fi
    die "$3 is not a $1 model offered for the $2 (${offered% }). List them with: $PROG models --backend $1 --role $2"
}
is_hex64() { [[ $1 =~ ^[0-9a-fA-F]{64}$ ]]; }
is_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_ws_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ "${#1}" -le 64 ]; }
valid_display_name() {
    [ -n "$1" ] && [ "${#1}" -le 64 ] && [ "$1" = "$(trim "$1")" ] || return 1
    case $1 in *[[:cntrl:]]* | *[\{\}@\\\"]*) return 1 ;; esac
}
display_name_rule='1-64 characters, no leading or trailing spaces, no control characters and none of { } @ \ "'
is_within() { case $1 in "$2" | "$2"/*) return 0 ;; esac; return 1; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
utc_of() { date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '%s' "$1"; }

# Physical absolute path of PATH, which may not exist yet.
phys_path() {
    local p=$1 rest='' top
    while [ ! -d "$p" ]; do rest=/$(basename -- "$p")$rest; p=$(dirname -- "$p"); done
    top=$(cd -P -- "$p" && pwd)
    if [ "$top" = / ]; then printf '%s' "${rest:-/}"; else printf '%s%s' "$top" "$rest"; fi
}

# Print the Git work-tree top when DIR (or its nearest existing parent) is inside one.
git_top() {
    command -v git >/dev/null 2>&1 || return 1
    local d=$1
    while [ ! -d "$d" ]; do d=$(dirname -- "$d"); done
    (cd -- "$d" && unset GIT_DIR GIT_WORK_TREE && git rev-parse --show-toplevel 2>/dev/null)
}

# KEY=value data files written by this script (agent.conf, team.conf): first match wins.
conf_get() {
    local line
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
    done < "$1"
    return 1
}

# Read one setting from an env file the way run-buzz-acp.sh does: as data, never as code.
env_get() { # FILE KEY
    local line key value out='' found=1
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        case $line in '' | '#'*) continue ;; esac
        case $line in 'export '*) line=${line#export }; line=${line#"${line%%[![:space:]]*}"} ;; esac
        case $line in *=*) ;; *) continue ;; esac
        key=${line%%=*}
        key=${key%"${key##*[![:space:]]}"}
        [ "$key" = "$2" ] || continue
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        case $value in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        out=$value found=0
    done < "$1"
    if [ "$found" = 0 ]; then printf '%s' "$out"; fi
    return "$found"
}

# Remove exported settings that run-buzz-acp.sh or buzz would take over the agent's own files.
scrub_env() {
    local v
    for v in $(compgen -e); do
        case $v in BUZZ_* | RUN_BUZZ_ACP_*) unset "$v" ;; esac
    done
}

tool_path() { # VAR_VALUE DEFAULT_NAME -> resolved path or empty
    local want=${1:-$2}
    case $want in
        */*) if [ -f "$want" ] && [ -x "$want" ]; then printf '%s\n' "$want"; fi ;;
        *) command -v -- "$want" 2>/dev/null || true ;;
    esac
}

# ---------------------------------------------------------------- settings (public values only)
# $ROOT/settings.conf, mode 600, KEY=value lines. Only these names exist, and every value is
# validated before it is written, so a key, a proof or an API key cannot be stored there.
SETTING_NAMES='keygen launcher community owner model base_url'
setting() { # NAME -> stored value, or nothing (needs ROOT)
    local f=$ROOT/settings.conf
    [ -f "$f" ] || return 0
    conf_get "$f" "$1" || true
}
# Tool lookup: the environment variable, then settings.conf, then PATH.
keygen_path() { tool_path "${AGENT_TEAM_KEYGEN:-$(setting keygen)}" buzz-admin; }
launcher_path() { tool_path "${AGENT_TEAM_LAUNCHER:-$(setting launcher)}" run-buzz-acp.sh; }

# Plain addresses only: no user name, password, query or fragment, where a token could hide.
valid_ws_url() { [[ $1 =~ ^wss?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; }
valid_http_url() { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; }
# A model ID such as claude-opus-4-5; values starting with sk- look like API keys.
valid_model() {
    [ -n "$1" ] || return 0
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,63}$ ]] || return 1
    case $1 in sk-* | SK-*) return 1 ;; esac
}
# True when VALUE is the secret key of an agent under ROOT (compared in the shell, never printed).
is_agent_secret() {
    local k s='' v r=1
    v=$(lower "$1")
    for k in "$ROOT"/*/*/identity.key; do
        [ -f "$k" ] || continue
        IFS= read -r s < "$k" || true
        if [ "$(lower "$s")" = "$v" ]; then r=0; break; fi
    done
    s=''
    return "$r"
}
# Refuse a value that is or holds a secret, with a reason. NAME VALUE
refuse_secret() {
    case $2 in
        nsec1*) die "$1: that is a secret key (nsec); secret keys are never stored" ;;
        *'["auth"'* | '[auth,'* | *BUZZ_AUTH_TAG*) die "$1: that looks like an ownership proof; proofs are stored per agent with: agent-team.sh proof" ;;
        *PRIVATE_KEY* | *API_KEY* | *SECRET* | *TOKEN*) die "$1: that looks like a secret setting; it is never stored" ;;
    esac
    if is_hex64 "$2" && is_agent_secret "$2"; then
        die "$1: that is the secret key of one of your agents, not a public key; it was not used"
    fi
}

# ---------------------------------------------------------------- root and records
ROOT=''
resolve_root() { # [git]: also refuse a root inside a Git work tree
    local r=${AGENT_TEAM_ROOT:-} top
    if [ -z "$r" ]; then
        [ -n "${HOME:-}" ] || die 'HOME is not set; set AGENT_TEAM_ROOT to an absolute folder'
        r=$HOME/.buzz-agents
    fi
    case $r in /*) ;; *) die "AGENT_TEAM_ROOT must be an absolute path (got: $r)" ;; esac
    while [ "$r" != / ] && [ "${r%/}" != "$r" ]; do r=${r%/}; done
    case $r in *[[:cntrl:]]*) die 'AGENT_TEAM_ROOT contains control characters' ;; esac
    ROOT=$(phys_path "$r")
    if [ "${1:-}" = git ] && top=$(git_top "$ROOT"); then
        die "the agents' root $ROOT is inside the Git work tree $top. Agent keys must stay outside every Git work tree; set AGENT_TEAM_ROOT to another folder (default: ~/.buzz-agents)."
    fi
}

# Load a workspace record: T_NAME T_DIR T_WORKSPACE T_CHANNEL T_COMMUNITY T_OWNER T_EXT_ASSISTANT
# T_EXT_SUPERVISOR. A team that has only one of the two jobs names the agent with the other job, in
# another team of its channel: external_supervisor (a workspace agent made with --roles assistant), or
# external_assistant (a team that had a supervisor only when it was upgraded from format 2).
load_team() {
    T_NAME=$1
    valid_ws_name "$T_NAME" || die "not a workspace name: $T_NAME (see agent-team.sh status)"
    resolve_root
    T_DIR=$ROOT/$T_NAME
    [ -f "$T_DIR/team.conf" ] || die "no agents for workspace \"$T_NAME\" under $ROOT (agent-team.sh status lists them)"
    T_WORKSPACE=$(conf_get "$T_DIR/team.conf" workspace) || die "$T_DIR/team.conf has no workspace"
    T_CHANNEL=$(conf_get "$T_DIR/team.conf" channel) || die "$T_DIR/team.conf has no channel"
    T_COMMUNITY=$(conf_get "$T_DIR/team.conf" community) || die "$T_DIR/team.conf has no community"
    T_OWNER=$(conf_get "$T_DIR/team.conf" owner) || die "$T_DIR/team.conf has no owner"
    T_EXT_ASSISTANT=$(conf_get "$T_DIR/team.conf" external_assistant) || T_EXT_ASSISTANT=''
    T_EXT_SUPERVISOR=$(conf_get "$T_DIR/team.conf" external_supervisor) || T_EXT_SUPERVISOR=''
}
team_format() { conf_get "$T_DIR/team.conf" format 2>/dev/null || printf '1'; }

team_agents() { # agent ids present in T_DIR, in role order
    local id
    for id in $ALL_ROLES; do
        if [ -f "$T_DIR/$id/agent.conf" ]; then printf '%s\n' "$id"; fi
    done
}

select_agents() { # IDS...: validated ids, or all present ones when none given
    local id out=''
    if [ "$#" -eq 0 ]; then
        out=$(team_agents)
        [ -n "$out" ] || die "workspace \"$T_NAME\" has no complete agent folders"
        printf '%s\n' "$out"
        return
    fi
    for id in "$@"; do
        case " $ALL_ROLES " in *" $id "*) ;; *) die "unknown agent: $id (agents are: $ALL_ROLES)" ;; esac
        [ -f "$T_DIR/$id/agent.conf" ] || die "workspace \"$T_NAME\" has no agent \"$id\""
        printf '%s\n' "$id"
    done
}

agent_field() { conf_get "$T_DIR/$1/agent.conf" "$2" || die "$T_DIR/$1/agent.conf has no $2"; }
proof_of() { env_get "$T_DIR/$1/$ENV_NAME" BUZZ_AUTH_TAG || true; }

# Other workspaces under ROOT in the same channel: lines "ws<TAB>id<TAB>role<TAB>name"
channel_peers() { # CHANNEL EXCLUDE_WS
    local d ws ch id name
    for d in "$ROOT"/*/; do
        [ -f "$d/team.conf" ] || continue
        ws=$(basename -- "$d")
        [ "$ws" != "$2" ] || continue
        ch=$(conf_get "$d/team.conf" channel) || continue
        [ "$ch" = "$1" ] || continue
        for id in $ALL_ROLES; do
            name=$(conf_get "$d/$id/agent.conf" name 2>/dev/null) || continue
            printf '%s\t%s\t%s\t%s\n' "$ws" "$id" "$id" "$name"
        done
    done
}

# The public keys the workspace agent answers besides the owner: the channel supervisor it works with.
# That is its own team's supervisor; in a team without one (--roles assistant), the local channel
# supervisor of this channel that team.conf names (external_supervisor), when it is found on this
# machine. Comma-separated, sorted; empty when there is none (the env file then says owner-only, because
# the harness refuses allowlist mode with an empty list). Needs T_DIR C_NAME C_CHANNEL C_EXT_SUPERVISOR.
answer_keys() {
    local k want ws pid prole pname id
    for id in $ALL_ROLES; do
        is_channel_role "$id" && [ -f "$T_DIR/$id/agent.conf" ] || continue
        k=$(conf_get "$T_DIR/$id/agent.conf" pubkey) || k=''
        if is_hex64 "$k"; then lower "$k"; fi
        return 0
    done
    [ -n "$C_EXT_SUPERVISOR" ] || return 0
    want=$(lower "$C_EXT_SUPERVISOR")
    channel_peers "$C_CHANNEL" "$C_NAME" | while IFS="$(printf '\t')" read -r ws pid prole pname; do
        is_channel_role "$prole" && [ "$(lower "$pname")" = "$want" ] || continue
        k=$(conf_get "$ROOT/$ws/$pid/agent.conf" pubkey) || continue
        if is_hex64 "$k"; then lower "$k"; printf '\n'; fi
    done | LC_ALL=C sort -u | paste -s -d , -
}
# The local agent with public key HEX, as "Name (supervisor of workspace shop)"; else the key itself.
key_name() { # HEX
    local d id k
    for d in "$ROOT"/*/; do
        for id in $ALL_ROLES; do
            k=$(conf_get "$d/$id/agent.conf" pubkey 2>/dev/null) || continue
            [ "$(lower "$k")" = "$(lower "$1")" ] || continue
            printf '%s (%s of workspace %s)' "$(conf_get "$d/$id/agent.conf" name || true)" "$id" "$(basename -- "$d")"
            return 0
        done
    done
    printf 'an agent that is not on this machine (public key %s)' "$1"
}
# Whom an agent answers, as its env file says (public keys only; the harness always adds the owner).
answers_text() { # ID
    local env=$T_DIR/$1/$ENV_NAME mode keys k names=''
    mode=$(env_get "$env" BUZZ_ACP_RESPOND_TO 2>/dev/null) || mode=owner-only
    case $mode in
        anyone)
            if [ "$(env_get "$env" BUZZ_ACP_SUBSCRIBE 2>/dev/null || true)" = config ]; then
                printf 'anyone in its channel (subscriptions.toml decides which messages start a turn)'
            else printf 'anyone who mentions it'; fi ;;
        allowlist)
            keys=$(env_get "$env" BUZZ_ACP_RESPOND_TO_ALLOWLIST 2>/dev/null) || keys=''
            for k in ${keys//,/ }; do names="$names${names:+, }$(key_name "$k")"; done
            if [ -n "$names" ]; then printf 'the owner and %s' "$names"
            else printf 'nobody: allowlist mode with no public key, which the harness refuses; run %s upgrade %s' "$PROG" "$T_NAME"; fi ;;
        *) printf 'the owner only' ;;
    esac
}

# The names each job's prompt gives the other job. The channel supervisor's prompt names the workspace
# agents of this channel: its own team's (or the one team.conf names), then those of the other local
# teams of the channel. The workspace agent's prompt names its channel supervisor: its own team's, or
# the one team.conf names. Needs NAME_* C_EXT_*. PEERS: the lines channel_peers printed.
set_role_names() { # PEERS
    local extra
    P_SUPERVISOR=${NAME_supervisor:-$C_EXT_SUPERVISOR}
    [ -n "$P_SUPERVISOR" ] || P_SUPERVISOR='none yet'
    P_WORKSPACE_AGENTS=${NAME_assistant:-$C_EXT_ASSISTANT}
    extra=$(printf '%s\n' "$1" | while IFS="$(printf '\t')" read -r ws pid prole pname; do
        [ -n "$ws" ] && is_workspace_role "$prole" || continue
        [ "$(lower "$pname")" != "$(lower "$P_WORKSPACE_AGENTS")" ] || continue
        printf '%s, ' "$pname"
    done)
    extra=${extra%, }
    P_WORKSPACE_AGENTS="$P_WORKSPACE_AGENTS${P_WORKSPACE_AGENTS:+${extra:+, }}$extra"
    [ -n "$P_WORKSPACE_AGENTS" ] || P_WORKSPACE_AGENTS='none yet'
}

# ---------------------------------------------------------------- templates
script_dir() {
    local src=$0 dir link
    while [ -L "$src" ]; do
        dir=$(cd -P -- "$(dirname -- "$src")" && pwd)
        link=$(readlink -- "$src")
        case $link in /*) src=$link ;; *) src=$dir/$link ;; esac
    done
    cd -P -- "$(dirname -- "$src")" && pwd
}
# The skill folder is the parent of scripts/; templates/ sits there.
skill_dir() { (cd -P -- "$(script_dir)/.." && pwd); }
template_dir() { printf '%s' "${AGENT_TEAM_TEMPLATES:-$(skill_dir)/templates}"; }

# This skill's version: the one line of VERSION in the skill folder, MAJOR.MINOR.PATCH. create
# copies the file into a new team folder and upgrade replaces it there, so a team folder says
# which version of the skill wrote its files.
VERSION_RE='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$'
version_in() { # FILE: print the version it holds; fail when there is none or it is malformed
    local v=''
    [ -f "$1" ] || return 1
    IFS= read -r v < "$1" || [ -n "$v" ] || return 1
    [[ $v =~ $VERSION_RE ]] || return 1
    printf '%s' "$v"
}
SKILL_VERSION=''
need_skill_version() { # sets SKILL_VERSION, or stops: nothing is written by a skill without one
    [ -z "$SKILL_VERSION" ] || return 0
    SKILL_VERSION=$(version_in "$(skill_dir)/VERSION") ||
        die "this skill folder has no valid VERSION file ($(skill_dir)/VERSION); install the skill again"
}
# The version recorded in the loaded team folder; fails for a team made before versions.
team_version() { version_in "$T_DIR/VERSION"; }

# Placeholder values for render_prompt. {{WORKSPACE_AGENTS}} and {{SUPERVISOR_NAME}}: set_role_names.
P_AGENT_NAME='' P_WORKSPACE='' P_CHANNEL='' P_OWNER='' P_WORKSPACE_AGENTS='' P_SUPERVISOR=''
fill_line() {
    local s=$1
    s=${s//"{{AGENT_NAME}}"/"$P_AGENT_NAME"}
    s=${s//"{{WORKSPACE}}"/"$P_WORKSPACE"}
    s=${s//"{{CHANNEL_ID}}"/"$P_CHANNEL"}
    s=${s//"{{OWNER_PUBKEY}}"/"$P_OWNER"}
    s=${s//"{{WORKSPACE_AGENTS}}"/"$P_WORKSPACE_AGENTS"}
    s=${s//"{{SUPERVISOR_NAME}}"/"$P_SUPERVISOR"}
    printf '%s\n' "$s"
}
render_prompt() { # ROLE OUT_FILE
    local tpl line
    tpl=$(template_dir)/$1.md
    [ -f "$tpl" ] && [ -r "$tpl" ] || die "missing template: $tpl"
    while IFS= read -r line || [ -n "$line" ]; do fill_line "$line"; done < "$tpl" > "$2"
    if grep -q '{{' "$2"; then die "template $tpl left a placeholder unfilled: $(grep -o '{{[^}]*}}' "$2" | head -n 1)"; fi
    [ -s "$2" ] || die "template $tpl produced an empty prompt"
    append_brief "$2"
}

# The workspace brief: the user's own note about the workspace. create keeps it in
# <root>/<name>/brief.md and adds it to the end of every prompt it writes. No brief, no section.
BRIEF_MAX=4000
append_brief() { # OUT_FILE
    [ -s "$T_DIR/brief.md" ] || return 0
    {
        printf '\n### About this workspace\n\n'
        printf '%s\n\n' "The user wrote this note about the workspace when you were set up. Use this as project background. The owner authorizes delivery work."
        cat -- "$T_DIR/brief.md"
    } >> "$1"
}
# Refuse a brief that holds a secret: it would be stored and sent to the model with the prompt.
refuse_secret_brief() { # TEXT
    local w
    if printf '%s\n' "$1" | LC_ALL=C grep -Eq '(^|[^a-z0-9])nsec1[a-z0-9]{50,}'; then
        die 'create: the brief holds a secret key (nsec); it was not stored'
    fi
    if printf '%s\n' "$1" | LC_ALL=C grep -Eq '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'; then
        die 'create: the brief holds what looks like an API key; it was not stored'
    fi
    for w in $(printf '%s\n' "$1" | LC_ALL=C grep -Eo '[0-9a-fA-F]{64}' | sort -u); do
        if is_agent_secret "$w"; then w=''; die 'create: the brief holds the secret key of one of your agents; it was not stored'; fi
    done
    w=''
}

# ---------------------------------------------------------------- files written by create and upgrade
# One env file per agent. Sign-in is by subscription only (BUZZ_SIGN_IN=subscription): the launcher
# removes and refuses every API key, token, endpoint and provider variable and checks the sign-in.
write_env() { # OUT HOME NAME ROLE BACKEND MODEL_CLAUDE MODEL_CODEX [AUTH_TAG_LINE]
    local answers=''
    if is_workspace_role "$4"; then answers=$(answer_keys); fi
    {
        printf '# Buzz ACP settings for %s (%s), workspace %s, written by agent-team.sh.\n' "$3" "$4" "$C_NAME"
        printf '# run-buzz-acp.sh reads these as literal KEY=value lines. Keep this file private\n'
        printf '# (mode 600). The secret key is in identity.key, never here.\n'
        printf 'BUZZ_RELAY_URL=%s\n' "$C_COMMUNITY"
        printf 'BUZZ_ACP_AGENT_OWNER=%s\n' "$C_OWNER"
        printf 'RUN_BUZZ_ACP_KEY_FILE=%s/identity.key\n' "$2"
        printf '# Ownership proof from Buzz Desktop; set it with: agent-team.sh proof %s %s\n' "$C_NAME" "$4"
        printf '%s\n' "${8:-BUZZ_AUTH_TAG=}"
        printf '# Backend %s, signed in through your subscription only: no API key, token or gateway.\n' "$5"
        printf 'BUZZ_SIGN_IN=subscription\n'
        printf '# One model per backend; the launcher uses the selected backend'"'"'s. Empty = the runtime default.\n'
        printf 'BUZZ_MODEL_CLAUDE=%s\nBUZZ_MODEL_CODEX=%s\n' "$6" "$7"
        printf 'RUN_BUZZ_ACP_WORKDIR=%s\n' "$C_WS_PATH"
        printf 'BUZZ_ACP_SYSTEM_PROMPT_FILE=%s/prompt.md\n' "$2"
        printf 'BUZZ_ACP_NO_BASE_PROMPT=true\nBUZZ_ACP_MEMORY=true\n'
        if is_channel_role "$4"; then
            printf 'BUZZ_ACP_AGENT_COMMAND=%s/runtime/%s\n' "$2" "$(backend_command "$5")"
            printf '# The channel supervisor talks with anyone in its channel; subscriptions.toml decides which\n'
            printf '# messages start a turn. Its runtime holds its own read-only mode; the harness sets none.\n'
            printf 'BUZZ_ACP_RESPOND_TO=anyone\nBUZZ_ACP_SUBSCRIBE=config\n'
            printf 'BUZZ_ACP_CONFIG=%s/subscriptions.toml\n' "$2"
            printf 'BUZZ_ACP_PERMISSION_MODE=default\n'
        elif uses_partner_runtime "$4"; then
            printf 'BUZZ_ACP_AGENT_COMMAND=%s/runtime/%s\n' "$2" "$(backend_command "$5")"
            printf '# The reviewer answers anyone in its channels who mentions it. Its runtime holds its own\n'
            printf '# read-only mode; the harness sets none.\n'
            printf 'BUZZ_ACP_RESPOND_TO=anyone\n'
            printf 'BUZZ_ACP_PERMISSION_MODE=default\n'
        else
            # The workspace agent: the stock adapter. It answers the owner and the channel supervisor it
            # works with, by public key; the harness always adds the owner, and refuses an empty list.
            printf 'BUZZ_ACP_AGENT_COMMAND=%s\n' "$(backend_command "$5")"
            if [ -n "$answers" ]; then
                printf '# It answers the owner and its channel supervisor; starting work still needs the owner.\n'
                printf 'BUZZ_ACP_RESPOND_TO=allowlist\nBUZZ_ACP_RESPOND_TO_ALLOWLIST=%s\n' "$answers"
            else
                printf '# No channel supervisor of its own is known on this machine: it answers the owner.\n'
                printf 'BUZZ_ACP_RESPOND_TO=owner-only\n'
            fi
            printf 'BUZZ_ACP_PERMISSION_MODE=bypass-permissions\n'
        fi
    } > "$1"
}

RUNTIME_FILES='claude-agent-acp restricted-claude buzz-tools codex-acp'
install_partner_runtime() { # AGENT_DIR: add missing runtime files; existing ones are kept (upgrade refreshes them)
    local dest=$1 file tmp
    mkdir -p -- "$dest/runtime"
    chmod 700 "$dest/runtime"
    for file in $RUNTIME_FILES; do
        [ ! -e "$dest/runtime/$file" ] || continue
        tmp=$(mktemp "$dest/runtime/.new-tool.XXXXXX")
        TMP_PATHS+=("$tmp")
        cp -- "$(skill_dir)/runtime/$file" "$tmp"
        chmod 700 "$tmp"
        publish_file "$tmp" "$dest/runtime/$file"
    done
}

# The channel supervisor's subscription rules (harness: crates/buzz-acp/src/filter.rs match_event).
# Both rules carry an evalexpr author filter, filter.rs:318-330 (author = the event's hex public key),
# so the channel supervisor takes no turn for its own team's agents (both rules: its workspace agent
# answers its mentions, and its own mentions cannot start a turn back) or for any other local agent in
# its channel (the no-mention rule). The harness parses each filter at load (config.rs:1295-1340) and
# caps it at 4096 bytes, so at most RULES_MAX_KEYS keys are written.
RULES_MAX_KEYS=40
author_filter() { # KEY...: an expression that excludes these authors, or true for none
    local k out=''
    [ "$#" -le "$RULES_MAX_KEYS" ] ||
        die "more than $RULES_MAX_KEYS local agents share this channel; the channel supervisor's author filter would pass the harness's 4096-byte limit"
    for k in "$@"; do out="$out${out:+ && }author != \"$k\""; done
    printf '%s' "${out:-true}"
}
channel_agent_keys() { # CHANNEL OWN_KEY: public keys of every local agent in CHANNEL except OWN_KEY, sorted
    local d id k
    for d in "$ROOT"/*/; do
        [ -f "$d/team.conf" ] || continue
        [ "$(conf_get "$d/team.conf" channel || true)" = "$1" ] || continue
        for id in $ALL_ROLES; do
            k=$(conf_get "$d/$id/agent.conf" pubkey 2>/dev/null) || continue
            k=$(lower "$k")
            if [ "$k" != "$2" ]; then printf '%s\n' "$k"; fi
        done
    done | LC_ALL=C sort -u
}
team_agent_keys() { # OWN_KEY: public keys of this team's other agents, sorted
    local id k
    for id in $ALL_ROLES; do
        k=$(conf_get "$T_DIR/$id/agent.conf" pubkey 2>/dev/null) || continue
        k=$(lower "$k")
        if [ "$k" != "$1" ]; then printf '%s\n' "$k"; fi
    done | LC_ALL=C sort -u
}
write_rules() { # OUT CHANNEL_SUPERVISOR_KEY
    local tpl s team own
    tpl=$(template_dir)/subscriptions.toml
    [ -f "$tpl" ] || tpl=$(skill_dir)/templates/subscriptions.toml
    team=$(author_filter $(channel_agent_keys "$C_CHANNEL" "$2"))
    own=$(author_filter $(team_agent_keys "$2"))
    s=$(cat -- "$tpl")
    s=${s//"{{CHANNEL_ID}}"/"$C_CHANNEL"}
    s=${s//"{{TEAM_FILTER}}"/"$team"}
    s=${s//"{{OWN_FILTER}}"/"$own"}
    case $s in *'{{'*) die "template $tpl left a placeholder unfilled" ;; esac
    printf '%s\n' "$s" > "$1"
}

ensure_project_record() {
    local record=$C_WS_PATH/PROJECT.md tmp seed
    if [ -L "$record" ] || { [ -e "$record" ] && [ ! -f "$record" ]; }; then
        die "expected a regular project record at $record; the existing path was preserved"
    fi
    [ ! -f "$record" ] || return 0
    tmp=$(mktemp "$C_WS_PATH/.buzz-project.XXXXXX")
    TMP_PATHS+=("$tmp")
    seed=$(template_dir)/project.md
    [ -f "$seed" ] || seed=$(skill_dir)/templates/project.md
    cat -- "$seed" > "$tmp"
    # Two teams can share one workspace. Only the first publishes the initial record.
    ln -- "$tmp" "$record" 2>/dev/null || { [ -f "$record" ] && [ ! -L "$record" ]; } ||
        die "could not initialize $record"
    rm -f -- "$tmp"
}

write_agent_conf() { # OUT ID NAME PUBKEY ABOUT BACKEND MODEL_CLAUDE MODEL_CODEX [CREATED] [UPGRADED]
    {
        printf '# agent-team.sh agent record: public facts only.\n'
        printf 'format=%s\nid=%s\nrole=%s\nname=%s\npubkey=%s\nabout=%s\nbackend=%s\nmodel_claude=%s\nmodel_codex=%s\ncreated=%s\n' \
            "$FORMAT" "$2" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-$(now_utc)}"
        if [ -n "${10:-}" ]; then printf 'upgraded=%s\n' "${10}"; fi
        # Written only when set, so a record without an effort stays as it was.
        if [ -n "$W_EFFORT_CLAUDE" ]; then printf 'effort_claude=%s\n' "$W_EFFORT_CLAUDE"; fi
        if [ -n "$W_EFFORT_CODEX" ]; then printf 'effort_codex=%s\n' "$W_EFFORT_CODEX"; fi
    } > "$1"
}

write_team_conf() { # OUT
    {
        printf '# agent-team.sh workspace record: public facts only.\n'
        printf 'format=%s\nname=%s\nworkspace=%s\nchannel=%s\ncommunity=%s\nowner=%s\n' \
            "$FORMAT" "$C_NAME" "$C_WS_PATH" "$C_CHANNEL" "$C_COMMUNITY" "$C_OWNER"
        if [ -n "$C_EXT_SUPERVISOR" ]; then printf 'external_supervisor=%s\n' "$C_EXT_SUPERVISOR"; fi
        if [ -n "$C_EXT_ASSISTANT" ]; then printf 'external_assistant=%s\n' "$C_EXT_ASSISTANT"; fi
        printf 'created=%s\n' "$(now_utc)"
    } > "$1"
}

# Publish FILE_TMP as FINAL without ever replacing an existing FINAL.
publish_file() {
    ln -- "$1" "$2" 2>/dev/null || { rm -f -- "$1"; die "$2 appeared while this run was writing it; it was left unchanged"; }
    rm -f -- "$1"
}

# Files every team folder holds beside its agents, copied from this skill:
#   team.sh    the team's own command: check, start, stop and status for that folder's agents. It finds
#              everything from its own location, so a team folder runs, and moves, without this skill.
#   workspace-settings.py   keeps the sandbox settings of an agent on the stock Claude adapter (the
#              workspace agent) in its project folder (scripts/workspace-settings.py says which): team.sh
#              runs it before a start, so a project folder the team is new to gets them first.
#   acp-models.py   asks an adapter for the models it offers (scripts/acp-models.py): team.sh runs it
#              before a model menu, so the menu shows what the provider offers at that moment.
#   VERSION    the version of the skill that created or last upgraded this folder: create writes it
#              into a new team folder only, upgrade replaces it. It is data (mode 600, no backup),
#              and the last file an upgrade writes, so an interrupted upgrade leaves the earlier
#              version there and the next run finishes it.
# and, in each agent folder:
#   start.sh   that agent's own start command (templates/agent-start.sh): it starts this agent only,
#              through team.sh; in a terminal it asks that agent's provider, model and effort.
TEAM_FILES='team.sh acp-models.py workspace-settings.py'
team_files() { # every such file of this team: TEAM_FILES, one start.sh per agent, then VERSION
    local id
    # shellcheck disable=SC2086
    printf '%s\n' $TEAM_FILES
    for id in $(team_agents); do printf '%s/start.sh\n' "$id"; done
    printf 'VERSION\n'
}
team_file_source() { # REL
    local f name=''
    case $1 in
        team.sh) name=team.sh ;;
        */start.sh) name=agent-start.sh ;;
    esac
    if [ -n "$name" ]; then
        f=$(template_dir)/$name
        [ -f "$f" ] || f=$(skill_dir)/templates/$name
    elif [ "$1" = acp-models.py ] || [ "$1" = workspace-settings.py ]; then
        f=$(script_dir)/$1
    else
        f=$(skill_dir)/$1
    fi
    [ -f "$f" ] || die "the skill has no $1; install the skill again"
    printf '%s' "$f"
}
team_file_state() { # REL: current | missing | differs
    if [ ! -e "$T_DIR/$1" ]; then printf 'missing'
    elif cmp -s -- "$(team_file_source "$1")" "$T_DIR/$1" && { [ "$1" = VERSION ] || [ -x "$T_DIR/$1" ]; }; then printf 'current'
    else printf 'differs'; fi
}
install_team_file() { # REL [STAMP]: write or replace it; a replaced one is kept beside it
    local dest=$T_DIR/$1 tmp
    mkdir -p -- "$(dirname -- "$dest")"
    chmod 700 "$(dirname -- "$dest")"
    tmp=$(mktemp "$(dirname -- "$dest")/.new-file.XXXXXX")
    TMP_PATHS+=("$tmp")
    cp -- "$(team_file_source "$1")" "$tmp"
    if [ "$1" = VERSION ]; then chmod 600 "$tmp"; else chmod 700 "$tmp"; fi
    if [ -e "$dest" ] && [ -n "${2:-}" ] && [ "$1" != VERSION ]; then
        cp -p -- "$dest" "$dest.bak-$2"
        chmod 600 "$dest.bak-$2"
    fi
    mv -f -- "$tmp" "$dest"
}
# What holds an agent to its project folder:
#   - on the restricted runtime (the channel supervisor, the reviewer): that runtime;
#   - on the stock Claude adapter (the workspace agent): plain Claude Code settings in the project folder,
#     PROJECT/.claude/settings.json, which Claude Code reads itself. workspace-settings.py writes and
#     checks them; create puts them there first, and team.sh before every start;
#   - on the stock Codex adapter: the adapter runs every turn in Codex's workspace-write sandbox and
#     replaces what a config file says, so no file is written; start pins that mode (INITIAL_AGENT_MODE);
#   - and the rule in the workspace agent's prompt, for what no setting holds.
on_stock_claude() { ! uses_partner_runtime "$1" && [ "$2" = claude ]; }   # ID BACKEND
on_stock_codex() { ! uses_partner_runtime "$1" && [ "$2" = codex ]; }     # ID BACKEND
# workspace_settings apply|check DIR: prints the helper's one line. Status: the helper's (0 written or
# in place; 3 absent; 4 incomplete; 2 the file cannot be used), or 5 when python3 is not available.
workspace_settings() {
    local py=${AGENT_TEAM_PYTHON:-python3}
    if [ "$py" = none ] || ! command -v "$py" >/dev/null 2>&1; then
        printf 'python3 is needed to write the settings file, and it is not on PATH'
        return 5
    fi
    "$py" -I "$(script_dir)/workspace-settings.py" "$1" "$2" 2>&1
}

# Generate a key pair into DIR/identity.key (secret) and DIR/.pubkey. The generator's output goes
# through a pipe straight into the key file: the secret is never printed, logged or put in arguments.
generate_key() { # DIR
    local keygen status=0 k=''
    keygen=$(keygen_path)
    [ -n "$keygen" ] ||
        die "key generator not found. Fix: agent-team.sh settings --keygen /path/to/buzz-admin (or put buzz-admin on PATH)"
    "$keygen" generate-key 2>"$1/.keygen.err" | {
        line='' v=''
        while IFS= read -r line; do
            case $line in
                'Secret key:'*) v=${line#Secret key:}; v=${v//[[:space:]]/}; printf '%s\n' "$v" > "$1/identity.key" ;;
                'Public key:'*) v=${line#Public key:}; v=${v//[[:space:]]/}; printf '%s\n' "$v" > "$1/.pubkey" ;;
            esac
        done
        v='' line=''
    } || status=$?
    if [ "$status" != 0 ]; then
        say "$PROG: the key generator failed (exit $status):" >&2
        head -c 2000 "$1/.keygen.err" >&2 || true
        die 'no agent folder was created for this agent'
    fi
    rm -f -- "$1/.keygen.err"
    [ -s "$1/identity.key" ] && [ -s "$1/.pubkey" ] || die 'the key generator printed no key pair; no agent folder was created'
    IFS= read -r k < "$1/identity.key" || true
    if ! [[ $k =~ ^[0-9a-f]{64}$ ]]; then k=''; die 'the generated secret key is not 64 hex characters; no agent folder was created'; fi
    k=''
    IFS= read -r k < "$1/.pubkey" || true
    is_hex64 "$k" || die 'the generated public key is not 64 hex characters; no agent folder was created'
    NEW_PUBKEY=$(lower "$k")
    rm -f -- "$1/.pubkey"
    chmod 600 "$1/identity.key"
}

# ---------------------------------------------------------------- proof checks (Q1)
# A proof is a NIP-OA auth tag: ["auth","<owner hex>","<conditions>","<signature hex>"].
# Accepted input forms: that JSON (spaces allowed), the unquoted shorthand [auth,<owner>,,<sig>],
# either one prefixed with BUZZ_AUTH_TAG= or export, and either one wrapped in quotes or lines.
# Sets PROOF_OWNER PROOF_COND PROOF_SIG PROOF_JSON, or PROOF_ERR and returns 1.
SIG_FAILED=no
normalize_proof() {
    local s=$1 inner commas f fields=() i
    PROOF_ERR=''
    s=${s//$'\r'/}
    s=${s//$'\n'/}
    s=$(trim "$s")
    case $s in 'export '*) s=$(trim "${s#export }") ;; esac
    case $s in BUZZ_AUTH_TAG=*) s=$(trim "${s#BUZZ_AUTH_TAG=}") ;; esac
    case $s in
        \'*\') s=$(trim "${s:1:${#s}-2}") ;;
        \"\[*\]\") s=$(trim "${s:1:${#s}-2}") ;;
    esac
    case $s in
        \[*\]) ;;
        *) PROOF_ERR='a proof looks like ["auth","<owner public key>","<conditions>","<signature>"]'; return 1 ;;
    esac
    inner=${s:1:${#s}-2}
    commas=${inner//[^,]/}
    [ "${#commas}" -eq 3 ] || { PROOF_ERR="a proof has exactly 4 fields; this one has $((${#commas} + 1))"; return 1; }
    IFS=, read -r -a fields <<< "$inner,"
    for i in 0 1 2 3; do
        f=$(trim "${fields[$i]:-}")
        case $f in
            \"*\") f=${f:1:${#f}-2} ;;
            \"* | *\") PROOF_ERR="field $((i + 1)) has an unmatched quote"; return 1 ;;
        esac
        case $f in *[\"\\[:space:]]*) PROOF_ERR="field $((i + 1)) contains a quote, backslash or space"; return 1 ;; esac
        fields[$i]=$f
    done
    [ "${fields[0]}" = auth ] || { PROOF_ERR="the first field must be \"auth\", not \"${fields[0]}\""; return 1; }
    PROOF_OWNER=$(lower "${fields[1]}")
    [[ $PROOF_OWNER =~ ^[0-9a-f]{64}$ ]] || { PROOF_ERR='the second field must be the owner public key, 64 hex characters'; return 1; }
    PROOF_COND=${fields[2]}
    valid_conditions "$PROOF_COND" || { PROOF_ERR="the conditions field is not valid NIP-OA conditions: \"$PROOF_COND\""; return 1; }
    PROOF_SIG=$(lower "${fields[3]}")
    [[ $PROOF_SIG =~ ^[0-9a-f]{128}$ ]] || { PROOF_ERR='the fourth field must be the signature, 128 hex characters'; return 1; }
    PROOF_JSON="[\"auth\",\"$PROOF_OWNER\",\"$PROOF_COND\",\"$PROOF_SIG\"]"
}

# NIP-OA conditions: empty, or clauses joined by '&': kind=N (0-65535), created_at<N or created_at>N
# (0-4294967295), canonical decimals, no whitespace.
valid_conditions() {
    local c=$1 clause num max clauses=()
    [ -n "$c" ] || return 0
    case $c in *[[:space:]]* | '&'* | *'&' | *'&&'*) return 1 ;; esac
    IFS='&' read -r -a clauses <<< "$c"
    for clause in "${clauses[@]}"; do
        case $clause in
            kind=*) num=${clause#kind=} max=65535 ;;
            'created_at<'*) num=${clause#created_at<} max=4294967295 ;;
            'created_at>'*) num=${clause#created_at>} max=4294967295 ;;
            *) return 1 ;;
        esac
        [[ $num =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
        [ "$num" -le "$max" ] || return 1
    done
}

# Offline BIP-340 check of the owner's signature over the NIP-OA preimage
# "nostr:agent-auth:<agent hex>:<conditions>". Returns 0 valid, 1 invalid, 2 not checked.
verify_signature() { # AGENT_HEX OWNER_HEX CONDITIONS SIG_HEX
    local py=${AGENT_TEAM_PYTHON:-python3} status=0
    [ "$py" != none ] || return 2
    command -v -- "$py" >/dev/null 2>&1 || return 2
    "$py" -I - "$@" <<'PY' || status=$?
import hashlib, sys
p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
def add(a, b):
    if a is None: return b
    if b is None: return a
    if a[0] == b[0] and a[1] != b[1]: return None
    if a == b: lam = 3 * a[0] * a[0] * pow(2 * a[1], p - 2, p) % p
    else: lam = (b[1] - a[1]) * pow(b[0] - a[0], p - 2, p) % p
    x = (lam * lam - a[0] - b[0]) % p
    return (x, (lam * (a[0] - x) - a[1]) % p)
def mul(P, k):
    R = None
    while k:
        if k & 1: R = add(R, P)
        P = add(P, P)
        k >>= 1
    return R
def tagged(tag, data):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + data).digest()
def lift_x(x):
    if x >= p: return None
    c = (pow(x, 3, p) + 7) % p
    y = pow(c, (p + 1) // 4, p)
    if y * y % p != c: return None
    return (x, y if y % 2 == 0 else p - y)
def verify(agent_hex, owner_hex, cond, sig_hex):
    msg = hashlib.sha256(("nostr:agent-auth:" + agent_hex + ":" + cond).encode()).digest()
    pk, sig = bytes.fromhex(owner_hex), bytes.fromhex(sig_hex)
    P = lift_x(int.from_bytes(pk, "big"))
    r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
    if P is None or r >= p or s >= n: return False
    e = int.from_bytes(tagged("BIP0340/challenge", sig[:32] + pk + msg), "big") % n
    R = add(mul(G, s), mul(P, n - e))
    return R is not None and R[1] % 2 == 0 and R[0] == r
try:
    ok = verify(*sys.argv[1:5])
except Exception:
    sys.exit(3)
sys.exit(0 if ok else 1)
PY
    case $status in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# Check PROOF_* (from normalize_proof) for AGENT_HEX and the expected OWNER_HEX. Prints one line per
# check. Returns 0 when nothing failed. With SKIP_SIGNATURE=yes the signature alone is not checked.
check_proof() { # AGENT_HEX OWNER_HEX [SKIP_SIGNATURE]
    local agent=$1 owner=$2 skip_sig=${3:-no} now clause num failed=0 kinds='' clauses=() sig=0
    now=$(date +%s)
    say "  format:     valid NIP-OA auth tag"
    if [ -n "$owner" ] && [ "$PROOF_OWNER" != "$owner" ]; then
        say "  owner:      FAILED: signed by $PROOF_OWNER, but this agent's owner is $owner"
        failed=1
    else
        say "  owner:      $PROOF_OWNER"
    fi
    if [ "$PROOF_OWNER" = "$agent" ]; then say '  owner:      FAILED: the owner and the agent are the same key'; failed=1; fi
    if [ -n "$PROOF_COND" ]; then
        IFS='&' read -r -a clauses <<< "$PROOF_COND"
        for clause in "${clauses[@]}"; do
            case $clause in
                'created_at<'*) num=${clause#created_at<}
                    if [ "$now" -lt "$num" ]; then say "  valid until: $(utc_of "$num")"
                    else say "  time:       FAILED: expired at $(utc_of "$num")"; failed=1; fi ;;
                'created_at>'*) num=${clause#created_at>}
                    if [ "$now" -gt "$num" ]; then say "  valid from: $(utc_of "$num")"
                    else say "  time:       FAILED: not valid before $(utc_of "$num")"; failed=1; fi ;;
                kind=*) kinds="$kinds${kinds:+,}${clause#kind=}" ;;
            esac
        done
    else
        say '  conditions: none (no time limit)'
    fi
    if [ -n "$kinds" ]; then
        say "  warning:    limited to event kinds $kinds; the agent's other events (messages, profile, presence) may be refused"
    fi
    if [ "$skip_sig" = yes ]; then
        say '  signature:  NOT CHECKED (--no-signature-check)'
        return "$failed"
    fi
    verify_signature "$agent" "$PROOF_OWNER" "$PROOF_COND" "$PROOF_SIG" || sig=$?
    case $sig in
        0) say "  signature:  valid for agent $agent" ;;
        1) say "  signature:  FAILED: not signed for agent $agent (a proof for another key, or altered)"; failed=1; SIG_FAILED=yes ;;
        *) say '  signature:  not checked offline (python3 not available); the harness checks it at start' ;;
    esac
    return "$failed"
}

# ---------------------------------------------------------------- create
usage() {
    cat <<'EOF'
Usage: agent-team.sh <command> [options]

  preflight [NAME] [--backend claude|codex] [--assistant-backend B] [--supervisor-backend B]
            [--roles assistant,supervisor|assistant] [--partner]
            [--roles reviewer] [--reviewer-backend B]
           Check everything a setup needs: the agents' root, the settings file, the
           key generator, the launcher (its path is printed), buzz, buzz-acp, and for
           each role its ACP adapter, its runtime and its sign-in. Each agent signs in
           through your subscription only: the CLI the role runs must report a Claude
           subscription or a ChatGPT sign-in, and no Claude settings file or Codex
           config may add an API key, token, helper or endpoint. With NAME, the team's
           saved backends and the agents' own runtimes are checked (the options then
           preview a switch). Prints one fix line per problem and exits 1 when a
           required item is missing. Changes nothing. --partner is accepted and has no
           effect (the channel supervisor's role is always checked).
  settings [--keygen PATH] [--launcher PATH] [--community URL] [--owner HEX]
           [--model ID] [--from-env FILE] [--unset NAME]
           Show or change the public defaults kept in <root>/settings.conf (mode 600):
           tool paths that are not on PATH, and the community, owner and Claude model
           that create uses when no option gives them. --from-env copies only those
           three public values. A value that is or holds a key, a proof, an API key or a
           URL with credentials is refused. NAME is one of keygen, launcher, community,
           owner, model, base_url (base_url is no longer used; --unset removes it).
  create   Make the agents for one workspace and one channel: a new key, an env file
           and a prompt per agent. Safe to repeat: existing files are kept. The two
           agents of a team have two jobs (their ids are assistant and supervisor):
             assistant   the workspace agent: the stock adapter with all its tools and
                         worker subagents; it answers the owner and the channel
                         supervisor, and starts work only on the owner's acceptance
             supervisor  the channel supervisor: the restricted runtime; it takes a turn
                         on every ordinary message in its channel, talks with anyone
                         there, and hands accepted work to the workspace agent
           For a workspace agent on Claude it first puts the sandbox settings into the
           project folder, as .claude/settings.json (workspace-settings.py in this skill
           says which, and what they hold); an existing file keeps everything else it holds.
             --workspace DIR      the project folder the agents work in (required)
             --channel UUID       the Buzz channel (required)
             --backend NAME       claude (default) or codex, for both new agents
             --assistant-backend NAME, --supervisor-backend NAME
                                  the backend of one role; wins over --backend
             --name NAME          the workspace name under the root (default: the
                                  folder name); needed when two folders share a name
             --roles LIST         assistant,supervisor (default); assistant: a workspace
                                  agent for a channel that already has a channel
                                  supervisor in another team; or reviewer: one
                                  independent reviewer, as a team of its own (give it
                                  its own --name). It reads the project and comments
                                  in Buzz; it cannot edit files or run commands, and it
                                  answers anyone in its channels who mentions it.
             --reviewer-name N    the reviewer's display name (default "<Folder> Reviewer")
             --reviewer-backend NAME, --reviewer-model ID
                                  the reviewer's backend and model, as for the other roles
             --effort LEVEL       reasoning effort for the new agents (optional)
             --assistant-effort LEVEL, --supervisor-effort LEVEL, --reviewer-effort LEVEL
                                  the effort of one role; wins over --effort. Claude: low,
                                  medium, high, xhigh or max. Codex: a level the model
                                  list offers for that model (low to ultra), which needs a
                                  model too. Kept one per backend, like the model. Without
                                  one, Claude Code uses your own level for the model and
                                  Codex its own default. default clears a saved one.
             --assistant-name N   the workspace agent's display name (default "<Name>")
             --supervisor-name N  the channel supervisor's display name (default
                                  "<Name> Supervisor"); with --roles assistant: the
                                  display name of the channel's existing channel
                                  supervisor, which the workspace agent answers
             --brief TEXT         a few lines about the workspace, added to the end of
                                  each prompt create writes (optional; - reads it
                                  from standard input; kept in <root>/<name>/brief.md)
             --community URL      wss:// community address
             --owner HEX          your own public key, 64 hex characters (not npub)
             --model ID           model for the new agents (default: the runtime
                                  default; a saved model applies to Claude agents only)
             --assistant-model ID, --supervisor-model ID
                                  the model of one role; wins over --model. A model
                                  must be one its backend offers for that role: the
                                  list from "models" when retrieved, else the
                                  documented one. Each agent keeps one model per
                                  backend, so a backend switch picks that backend's model.
             --from-env FILE      copy the three values above from a working env file;
                                  options win; no key, API key or gateway is copied
           Without these options, create uses the defaults in settings.conf. Agents sign
           in by subscription only: there is no gateway option. A team in an earlier
           team folder format (1, or 2 from 1.0.0 and 2.0.0) is refused: run upgrade first.
  upgrade  NAME [--dry-run] [--backend B] [--assistant-backend B] [--supervisor-backend B]
           [--model ID] [--assistant-model ID] [--supervisor-model ID]
           [--reviewer-backend B] [--reviewer-model ID]
           [--effort LEVEL] [--assistant-effort LEVEL] [--supervisor-effort LEVEL]
           [--reviewer-effort LEVEL]   (the saved reasoning effort; default clears it)
           Bring a team to the current format (3) and to the chosen backends: subscription
           sign-in env files, the current prompts, the channel supervisor's runtime and
           its subscription rules. In a format-2 team the assistant and the supervisor
           swap their jobs: each keeps its folder, key, proof, display name, backend,
           models and effort, and gets the other job's files; the plan says which job
           each one has from now on and which saved model it keeps (the model options
           below pick new ones in the same run). identity.key, the stored proof and the workspace's
           PROJECT.md stay byte-identical. Every replaced or removed file is kept beside
           itself as <file>.bak-<UTC time>. Refuses while an agent runs. Safe to repeat:
           a second run changes nothing. Each agent keeps its saved model per backend;
           the model options set the model of the new backend (checked as create
           checks them). A format-1 agent's single model is not carried. --dry-run
           prints the plan. The team's own files (team.sh, each start.sh, acp-models.py,
           workspace-settings.py) are refreshed the same way. The wall programs of a
           team made before 2.0.0 (wall/) are removed, and the sandbox settings of the
           workspace agent on Claude are put into the project folder
           (.claude/settings.json; an existing file keeps everything else it holds).
           VERSION in the team folder is set to this skill's version, last.
  models   [NAME] [--backend claude|codex] [--role assistant|supervisor]
           (--role reviewer for a reviewer; without --role: assistant)
           List the models your own sign-in offers for that backend and role, without
           a model turn: one ACP session with the runtime the role runs, in the agents'
           subscription-only environment, at most 30 s, no retry. The list is kept in
           <root>/models/ and used by the model checks. When it cannot be retrieved,
           the reason and the documented list are shown and the exit status is 1.
  proof    NAME AGENT [PROOF | -] [--force] [--no-signature-check]
           Store the ownership proof from Buzz Desktop for one agent. Reads standard
           input when PROOF is - or missing. Checks the format, the owner, the time
           limits and (with python3) the signature against the agent's key.
             --force               replace a different proof already stored for
                                   this agent; it skips no check
             --no-signature-check  store without the signature check (format, owner
                                   and time checks stay); the agent's first start
                                   is then the first real check. Use it only for a
                                   proof copied from Buzz Desktop for this agent's
                                   public key that the signature check refused.
  verify-proof AGENT_PUBKEY [PROOF | -]
           Check a proof against a public key; stores nothing.
  finish   NAME [AGENT...] [--dry-run] [--channel-step add|join|skip] [--role bot|member]
           Check each env file with the launcher, set each agent's display name
           (as the agent), then add it to the channel. add (default): as you,
           through your Buzz desktop pairing; join: the agent joins an open channel
           itself; skip: you add it in Buzz Desktop. --dry-run prints the commands.
  start    NAME [AGENT...] [--backend claude|codex] [--model ID] [--check]
           Run agents in the background, one log each, each on its saved backend.
           --backend chooses another backend for this run only (all named agents);
           --model chooses a model for this run (checked for that backend); in a
           terminal, start asks for the backend, then the model, offering the
           retrieved list (Enter keeps the saved ones). An agent that
           runs on another backend than the one chosen stops start with an error.
           --check validates every launcher configuration and starts nothing.
           Every team folder also has its own command, <root>/NAME/team.sh (check,
           start, stop, status), written by create and upgrade. It asks which agents
           to start and the provider and model of each, uses the same agent.pid and
           agent.log, and needs only the launcher, buzz-acp, buzz and the adapters on
           PATH, not this skill. The agents work in the folder it is run from, or in
           --workspace DIR. It is the command to start a team with.
           Every agent folder also has its own start command, <root>/NAME/AGENT/start.sh,
           written by create and upgrade: it starts that agent only, through team.sh. In a
           terminal both ask the provider, the model and the reasoning effort, and the
           model menu shows the list the provider's adapter offers at that moment
           (acp-models.py in the team folder); --yes asks nothing and keeps the saved ones.
  stop     NAME [AGENT...] [--force]
           stop agents this tool started (SIGTERM, then wait; --force: SIGKILL after)
  status   [NAME]            show agents, backends, sign-in, proofs, whom each agent
           answers and running state, and the version of the skill that wrote each
           team's files
  version  Print this skill's version: the one line of VERSION in the skill folder.
           create records it in a new team folder (<root>/NAME/VERSION) and upgrade
           replaces it there; "status NAME" and "<root>/NAME/team.sh version" show it.

Environment:
  AGENT_TEAM_ROOT        root folder (default ~/.buzz-agents); outside any Git work tree
  AGENT_TEAM_LAUNCHER    launcher (default: settings.conf, then run-buzz-acp.sh on PATH)
  AGENT_TEAM_KEYGEN      key generator (default: settings.conf, then buzz-admin on PATH)
  AGENT_TEAM_BUZZ        Buzz CLI used by finish (default buzz on PATH)
  AGENT_TEAM_PYTHON      python3 for the offline signature check; "none" skips it
  AGENT_TEAM_TEMPLATES   prompt templates (default: templates/ in the skill folder)
  CLAUDE_AGENT_ACP_PROTOCOL  passed to started agents (default v1)
  AGENT_TEAM_STOP_GRACE  seconds stop waits after SIGTERM (default 30)
  AGENT_TEAM_START_WAIT  seconds start watches for an early exit (default 3)
  AGENT_TEAM_LOG_MAX_BYTES  a log above this is moved to agent.log.1 at start (10 MiB)
  BUZZ_CLAUDE_MANAGED_DIR   Claude's managed settings folder (default
                         /Library/Application Support/ClaudeCode), for the settings check
EOF
}

derive_ws_name() {
    local b
    b=$(basename -- "$1")
    b=$(printf '%s' "$b" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '-')
    while :; do case $b in [.-]*) b=${b#?} ;; *) break ;; esac; done
    b=${b%-}
    printf '%s' "${b:0:64}"
}
default_name() { # WS_NAME ROLE_WORD
    local first rest
    first=$(printf '%s' "${1:0:1}" | LC_ALL=C tr 'a-z' 'A-Z')
    rest=${1:1}
    printf '%s%s%s' "$first" "$rest" "${2:+ $2}"
}
job_words() { # ID: the job of that role id, as the docs name it
    if is_workspace_role "$1"; then printf 'the workspace agent'
    elif is_channel_role "$1"; then printf 'the channel supervisor'
    else printf 'the independent reviewer'; fi
}
# The description an agent's Buzz profile gets (finish), from its job. Needs C_NAME C_WS_PATH.
default_about() { # ID
    if is_workspace_role "$1"; then printf 'Workspace agent for %s: plans, worker runs and the project record.' "$C_NAME"
    elif is_channel_role "$1"; then printf 'Channel supervisor for %s: project discussions, shared knowledge and proposed todos.' "$C_NAME"
    else printf 'Independent reviewer for %s.' "$(derive_ws_name "$C_WS_PATH")"; fi
}
format_words() { # FORMAT: how an earlier team folder format is named to the user
    case $1 in
        1) printf 'format 1, made before 20 November' ;;
        2) printf 'format 2, made by version 1.0.0 or 2.0.0 of this skill' ;;
        *) printf 'format %s' "$1" ;;
    esac
}
old_format_message() { # NAME FORMAT
    local swap=''
    [ "$2" != 2 ] || swap=' In format 3 the assistant and the supervisor swap their jobs; the dry run says what each one does from now on.'
    printf '%s' "workspace \"$1\" is in an earlier team folder format ($(format_words "$2")). Bring it to the current format ($FORMAT) first: $PROG upgrade $1 --dry-run, then $PROG upgrade $1. It keeps keys, proofs and PROJECT.md.$swap"
}

cmd_create() {
    local ws_arg='' roles_arg='assistant,supervisor' a_opt='' s_opt='' r_opt='' from_env=''
    local opt_comm='' opt_owner='' opt_model='' model_set=no name_opt='' b_all='' b_a='' b_s='' b_r=''
    local v role id home tmp_home f top roles existing name lc n peers ws pid prole pname
    local brief_arg='' brief_set=no brief_changed=no cr saved b m created_now='' key stamp m_a='' m_s='' m_r='' mc mx e e_all='' e_a='' e_s='' e_r=''
    C_CHANNEL='' REQ_assistant='' REQ_supervisor='' REQ_reviewer=''
    EFFORT_assistant='' EFFORT_supervisor='' EFFORT_reviewer=''
    while [ "$#" -gt 0 ]; do
        case $1 in
            --backend) need_value "$@"; check_backend "$2"; b_all=$2; shift ;;
            --assistant-backend) need_value "$@"; check_backend "$2"; b_a=$2; shift ;;
            --supervisor-backend) need_value "$@"; check_backend "$2"; b_s=$2; shift ;;
            --reviewer-backend) need_value "$@"; check_backend "$2"; b_r=$2; shift ;;
            --brief) need_value "$@"; brief_arg=$2; brief_set=yes; shift ;;
            --workspace) need_value "$@"; ws_arg=$2; shift ;;
            --channel) need_value "$@"; C_CHANNEL=$2; shift ;;
            --name) need_value "$@"; name_opt=$2; shift ;;
            --roles) need_value "$@"; roles_arg=$2; shift ;;
            --assistant-name) need_value "$@"; a_opt=$2; shift ;;
            --supervisor-name) need_value "$@"; s_opt=$2; shift ;;
            --reviewer-name) need_value "$@"; r_opt=$2; shift ;;
            --community | --relay) need_value "$@"; opt_comm=$2; shift ;;
            --owner) need_value "$@"; opt_owner=$2; shift ;;
            --model) [ "$#" -ge 2 ] || die '--model needs a value'; opt_model=$2; model_set=yes; shift ;;
            --assistant-model) need_value "$@"; m_a=$2; shift ;;
            --supervisor-model) need_value "$@"; m_s=$2; shift ;;
            --reviewer-model) need_value "$@"; m_r=$2; shift ;;
            --effort) need_value "$@"; e_all=$2; shift ;;
            --assistant-effort) need_value "$@"; e_a=$2; shift ;;
            --supervisor-effort) need_value "$@"; e_s=$2; shift ;;
            --reviewer-effort) need_value "$@"; e_r=$2; shift ;;
            --base-url) die 'create: agents sign in through your subscription only; a gateway address (--base-url) is not used' ;;
            --from-env) need_value "$@"; from_env=$2; shift ;;
            -h | --help) usage; exit 0 ;;
            *) die "create: unknown option: $1 (see agent-team.sh help)" ;;
        esac
        shift
    done
    REQ_assistant=${b_a:-$b_all} REQ_supervisor=${b_s:-$b_all} REQ_reviewer=${b_r:-$b_all}
    need_skill_version

    [ -n "$ws_arg" ] || die 'create: --workspace DIR is required'
    [ -d "$ws_arg" ] || die "create: workspace folder not found: $ws_arg"
    C_WS_PATH=$(cd -P -- "$ws_arg" && pwd)
    case $C_WS_PATH in *[[:cntrl:]]*) die 'the workspace path contains control characters' ;; esac
    [ -n "$C_CHANNEL" ] || die 'create: --channel UUID is required'
    is_uuid "$C_CHANNEL" || die "create: --channel must be a channel UUID (8-4-4-4-12 hex digits), got: $C_CHANNEL"
    C_CHANNEL=$(lower "$C_CHANNEL")
    C_NAME=${name_opt:-$(derive_ws_name "$C_WS_PATH")}
    valid_ws_name "$C_NAME" || die "create: workspace name \"$C_NAME\" must be 1-64 of A-Z a-z 0-9 . _ - (start with a letter or digit); choose one with --name"
    # The supervisor is made first, so that the workspace agent's env file can name its public key.
    case $roles_arg in
        assistant,supervisor | supervisor,assistant) roles='supervisor assistant' ;;
        assistant) roles=assistant ;;
        reviewer) roles=reviewer ;;
        supervisor) die 'create: a team with a supervisor only is no longer made: since 3.0.0 the supervisor is the channel supervisor. For a workspace agent in a channel that already has a channel supervisor: --roles assistant' ;;
        *) die "create: --roles must be assistant,supervisor, assistant or reviewer (got: $roles_arg)" ;;
    esac

    resolve_root git

    # The brief, when given: plain text, bounded, no secret. "-" reads it from standard input.
    C_BRIEF=''
    if [ "$brief_set" = yes ]; then
        if [ "$brief_arg" = - ]; then brief_arg=$(cat) || die 'create: could not read the brief from standard input'; fi
        cr=$(printf '\r')
        brief_arg=${brief_arg//"$cr"/}
        brief_arg=$(trim "$brief_arg")
        v=$(printf '%s' "$brief_arg" | LC_ALL=C tr -d '\n\t')
        case $v in *[[:cntrl:]]*) die 'create: the brief contains control characters; give plain text' ;; esac
        [ "${#brief_arg}" -le "$BRIEF_MAX" ] ||
            die "create: the brief is ${#brief_arg} characters; keep it to $BRIEF_MAX or fewer. A longer description belongs in a file in the workspace."
        refuse_secret_brief "$brief_arg"
        C_BRIEF=$brief_arg
        [ -n "$C_BRIEF" ] || say 'The brief is empty: no brief was added.'
    fi

    # Community, owner and model: options win over --from-env, which wins over settings.conf.
    C_COMMUNITY='' C_OWNER='' C_MODEL=''
    if [ -n "$from_env" ]; then
        [ -f "$from_env" ] && [ -r "$from_env" ] || die "create: cannot read --from-env file: $from_env"
        C_COMMUNITY=$(env_get "$from_env" BUZZ_RELAY_URL) || C_COMMUNITY=''
        C_OWNER=$(env_get "$from_env" BUZZ_ACP_AGENT_OWNER) || C_OWNER=''
        C_MODEL=$(env_get "$from_env" BUZZ_ACP_MODEL) || C_MODEL=''
        if env_get "$from_env" ANTHROPIC_BASE_URL >/dev/null; then
            say "Not copied from $from_env: ANTHROPIC_BASE_URL (agents sign in through your subscription only)."
        fi
    fi
    [ -z "$opt_comm" ] || C_COMMUNITY=$opt_comm
    [ -z "$opt_owner" ] || C_OWNER=$opt_owner
    [ "$model_set" = no ] || C_MODEL=$opt_model
    [ -n "$C_COMMUNITY" ] || C_COMMUNITY=$(setting community)
    [ -n "$C_OWNER" ] || C_OWNER=$(setting owner)
    if [ "$model_set" = no ] && [ -z "$C_MODEL" ]; then C_MODEL=$(setting model); fi
    [ -n "$C_COMMUNITY" ] || die 'create: the community address is required: --community wss://..., --from-env FILE, or agent-team.sh settings --community wss://...'
    refuse_secret create "$C_COMMUNITY"
    valid_ws_url "$C_COMMUNITY" || die "create: the community address must be a plain ws:// or wss:// address, with no user name, password, query or spaces (got: $C_COMMUNITY)"
    case $C_OWNER in
        '') die 'create: your public key is required: --owner HEX, --from-env FILE, or agent-team.sh settings --owner HEX' ;;
        npub1*) die 'create: --owner needs the 64-character hex public key; an npub does not work' ;;
    esac
    refuse_secret create "$C_OWNER"
    is_hex64 "$C_OWNER" || die 'create: --owner must be your 64-character hex public key'
    C_OWNER=$(lower "$C_OWNER")
    refuse_secret create "$C_MODEL"
    if is_within "$C_WS_PATH" "$ROOT"; then die "the workspace $C_WS_PATH is inside the agents' root $ROOT"; fi
    if is_within "$ROOT" "$C_WS_PATH"; then
        die "the agents' root $ROOT is inside the workspace $C_WS_PATH; keys must stay out of the workspace"
    fi
    if top=$(git_top "$C_WS_PATH") && is_within "$ROOT" "$top"; then
        die "the agents' root $ROOT is inside the workspace's Git work tree $top"
    fi

    # Models are checked before anything is written, so a refused one leaves nothing behind.
    T_DIR=$ROOT/$C_NAME T_NAME=$C_NAME
    # Each new agent's model: its own option, else --model, else a saved Claude default for Claude
    # agents. It must be one its backend offers for that role.
    for id in $roles; do
        [ ! -f "$T_DIR/$id/agent.conf" ] || continue
        eval "b=\${REQ_$id:-claude}"
        case $id in assistant) m=$m_a ;; reviewer) m=$m_r ;; *) m=$m_s ;; esac
        if [ -z "$m" ] && [ "$model_set" = yes ]; then m=$opt_model; fi
        if [ -z "$m" ] && [ "$model_set" = no ] && [ "$b" = claude ]; then m=$C_MODEL; fi
        require_model "$b" "$id" "$m"
        eval "MODEL_$id=\$m"
        case $id in assistant) e=$e_a ;; reviewer) e=$e_r ;; *) e=$e_s ;; esac
        [ -n "$e" ] || e=$e_all
        case $e in default | none) e='' ;; esac
        require_effort "$b" "$id" "$m" "$e"
        eval "EFFORT_$id=\$e"
    done

    mkdir -p -- "$ROOT"
    chmod 700 "$ROOT"
    mkdir -p -- "$T_DIR"
    chmod 700 "$T_DIR"
    take_lock "$T_DIR"
    # Anything named .new-* is from a run that was interrupted; it was never trusted.
    for f in "$T_DIR"/.new-* "$T_DIR"/*/.new-*; do
        if [ -e "$f" ]; then rm -rf -- "$f"; say "Removed an unfinished file from an interrupted run: $f"; fi
    done
    if upgrade_interrupted; then die "an upgrade of workspace \"$C_NAME\" was interrupted; finish it first with: $PROG upgrade $C_NAME"; fi

    # The workspace record: one name, one folder, one channel, one community, one owner.
    C_EXT_ASSISTANT='' C_EXT_SUPERVISOR=''
    if [ -f "$T_DIR/team.conf" ]; then
        load_team "$C_NAME"
        if [ "$T_WORKSPACE" != "$C_WS_PATH" ]; then
            die "the name \"$C_NAME\" is already used for the workspace $T_WORKSPACE. Choose another name with --name (for example --name $C_NAME-2)."
        fi
        [ "$T_CHANNEL" = "$C_CHANNEL" ] || die "this workspace's agents were made for channel $T_CHANNEL, not $C_CHANNEL. Use another --name for a second set."
        [ "$T_COMMUNITY" = "$C_COMMUNITY" ] || die "this workspace's agents were made for community $T_COMMUNITY, not $C_COMMUNITY"
        [ "$T_OWNER" = "$C_OWNER" ] || die "this workspace's agents were made for owner $T_OWNER, not $C_OWNER"
        # A team in an earlier format is only read here; upgrade rewrites it (defect: create once rebuilt
        # T-7 prompts). Format 2 holds the other assignment of the two jobs.
        v=$(team_format)
        [ "$v" = "$FORMAT" ] || die "$(old_format_message "$C_NAME" "$v")"
        C_EXT_ASSISTANT=$T_EXT_ASSISTANT C_EXT_SUPERVISOR=$T_EXT_SUPERVISOR
        say "Workspace \"$C_NAME\" exists: $T_DIR (kept)"
    fi
    for id in $ALL_ROLES; do
        [ -f "$T_DIR/$id/agent.conf" ] || continue
        v=$(agent_format "$id")
        [ "$v" = "$FORMAT" ] || die "$(old_format_message "$C_NAME" "$v")"
        eval "b=\$REQ_$id"
        saved=$(agent_backend "$id")
        if [ -n "$b" ] && [ "$b" != "$saved" ]; then
            die "the $id already runs on $saved; create keeps existing agents. To change its saved backend: $PROG upgrade $C_NAME --$id-backend $b"
        fi
    done
    # Display names: existing agents keep theirs; new ones come from options or defaults.
    NAME_assistant='' NAME_supervisor='' NAME_reviewer=''
    for id in $ALL_ROLES; do
        if [ -f "$T_DIR/$id/agent.conf" ]; then
            name=$(conf_get "$T_DIR/$id/agent.conf" name) || die "$T_DIR/$id/agent.conf has no name"
            eval "NAME_$id=\$name"
        fi
    done
    if [ -z "$NAME_assistant" ]; then
        case " $roles " in *' assistant '*) NAME_assistant=${a_opt:-$(default_name "$C_NAME" "")} ;; esac
    elif [ -n "$a_opt" ] && [ "$a_opt" != "$NAME_assistant" ]; then
        warn "the assistant already exists as \"$NAME_assistant\"; --assistant-name was ignored"
    fi
    if [ -z "$NAME_supervisor" ]; then
        case " $roles " in
            *' supervisor '*) NAME_supervisor=${s_opt:-$(default_name "$C_NAME" Supervisor)} ;;
            *' assistant '*)
                # A workspace agent for a channel whose channel supervisor is in another team.
                if [ -n "$C_EXT_SUPERVISOR" ]; then :
                elif [ -n "$s_opt" ]; then C_EXT_SUPERVISOR=$s_opt
                else
                    # The first one found; the whole list is read, so the writer never meets a closed pipe.
                    C_EXT_SUPERVISOR=$(channel_peers "$C_CHANNEL" "$C_NAME" | {
                        v=''
                        while IFS="$(printf '\t')" read -r ws pid prole pname; do
                            if [ -z "$v" ] && is_channel_role "$prole"; then v=$pname; fi
                        done
                        printf '%s' "$v"
                    })
                    [ -n "$C_EXT_SUPERVISOR" ] || die 'create: with --roles assistant, name the channel'"'"'s existing channel supervisor: --supervisor-name "<its display name>"'
                    say "Using the channel supervisor \"$C_EXT_SUPERVISOR\" found in another workspace of this channel."
                fi ;;
        esac
    elif [ -n "$s_opt" ] && [ "$s_opt" != "$NAME_supervisor" ]; then
        warn "the supervisor already exists as \"$NAME_supervisor\"; --supervisor-name was ignored"
    fi
    # A reviewer is named after the project folder, since its team has a name of its own.
    if [ -z "$NAME_reviewer" ]; then
        case " $roles " in *' reviewer '*) NAME_reviewer=${r_opt:-$(default_name "$(derive_ws_name "$C_WS_PATH")" Reviewer)} ;; esac
    elif [ -n "$r_opt" ] && [ "$r_opt" != "$NAME_reviewer" ]; then
        warn "the reviewer already exists as \"$NAME_reviewer\"; --reviewer-name was ignored"
    fi
    if [ -n "$C_EXT_SUPERVISOR" ]; then
        valid_display_name "$C_EXT_SUPERVISOR" || die "channel supervisor name \"$C_EXT_SUPERVISOR\": $display_name_rule"
    fi
    if [ -n "$C_EXT_ASSISTANT" ]; then
        valid_display_name "$C_EXT_ASSISTANT" || die "workspace agent name \"$C_EXT_ASSISTANT\": $display_name_rule"
    fi

    # Q5, the offline part: names must differ (ignoring case, as Buzz mention lookup does) from each
    # other, from the channel's agent named in team.conf, and from agents of other local workspaces in
    # this channel.
    peers=$(channel_peers "$C_CHANNEL" "$C_NAME")
    for id in $roles; do
        [ ! -f "$T_DIR/$id/agent.conf" ] || continue
        eval "name=\$NAME_$id"
        valid_display_name "$name" || die "$id display name \"$name\": $display_name_rule"
        lc=$(lower "$name")
        for n in $ALL_ROLES; do
            [ "$n" != "$id" ] || continue
            eval "v=\$NAME_$n"
            if [ -n "$v" ] && [ "$(lower "$v")" = "$lc" ]; then die "the $id and the $n cannot both be named \"$name\"; give one another name"; fi
        done
        if [ -n "$C_EXT_SUPERVISOR" ] && [ "$(lower "$C_EXT_SUPERVISOR")" = "$lc" ]; then
            die "\"$name\" is the name of the channel supervisor this team works with; give the $id another name"
        fi
        if [ -n "$C_EXT_ASSISTANT" ] && [ "$(lower "$C_EXT_ASSISTANT")" = "$lc" ]; then
            die "\"$name\" is the name of the workspace agent this team works with; give the $id another name"
        fi
        while IFS="$(printf '\t')" read -r ws pid prole pname; do
            [ -n "$ws" ] || continue
            if [ "$(lower "$pname")" = "$lc" ]; then
                die "\"$name\" is already the $prole of workspace \"$ws\" in this channel; give the $id another name (--$id-name)"
            fi
        done <<EOF
$peers
EOF
    done

    # The workspace record first, so a later run can finish an interrupted one.
    if [ ! -f "$T_DIR/team.conf" ]; then
        tmp_home=$(mktemp "$T_DIR/.new-team.XXXXXX")
        TMP_PATHS+=("$tmp_home")
        write_team_conf "$tmp_home"
        chmod 600 "$tmp_home"
        publish_file "$tmp_home" "$T_DIR/team.conf"
        # Only a new team folder records this skill's version. A folder that exists keeps its
        # files, so it keeps the version that wrote them until upgrade refreshes both.
        install_team_file VERSION
        say "Workspace \"$C_NAME\": $T_DIR"
    fi

    # A brief given now replaces the stored one; without one, the stored brief is used again.
    if [ -n "$C_BRIEF" ]; then
        if [ -f "$T_DIR/brief.md" ] && [ "$(cat -- "$T_DIR/brief.md")" = "$C_BRIEF" ]; then
            say "Brief: unchanged ($T_DIR/brief.md)"
        else
            if [ -f "$T_DIR/brief.md" ]; then v=replaced; else v=saved; fi
            tmp_home=$(mktemp "$T_DIR/.new-brief.XXXXXX")
            TMP_PATHS+=("$tmp_home")
            printf '%s\n' "$C_BRIEF" > "$tmp_home"
            chmod 600 "$tmp_home"
            mv -f -- "$tmp_home" "$T_DIR/brief.md"
            brief_changed=yes
            say "Brief: $v ($T_DIR/brief.md); it goes at the end of each prompt written from now on."
        fi
    fi

    # Prompt placeholders shared by both roles.
    P_WORKSPACE=$C_WS_PATH P_CHANNEL=$C_CHANNEL P_OWNER=$C_OWNER
    set_role_names "$peers"

    for id in $roles; do
        home=$T_DIR/$id
        eval "name=\$NAME_$id"
        P_AGENT_NAME=$name
        if [ -d "$home" ] || [ -e "$home" ]; then
            [ -f "$home/identity.key" ] && [ -f "$home/agent.conf" ] ||
                die "$home exists but has no identity.key or agent.conf. It is not trusted; move it aside to make this agent again."
            chmod 700 "$home"
            saved=$(agent_backend "$id")
            mc=$(agent_model "$id" claude) mx=$(agent_model "$id" codex)
            if uses_partner_runtime "$id"; then install_partner_runtime "$home"; fi
            existing=''
            for f in "$ENV_NAME" prompt.md; do
                if [ -f "$home/$f" ]; then existing="$existing $f"; continue; fi
                tmp_home=$(mktemp "$home/.new-$f.XXXXXX")
                TMP_PATHS+=("$tmp_home")
                if [ "$f" = prompt.md ]; then
                    render_prompt "$id" "$tmp_home"
                else
                    write_env "$tmp_home" "$home" "$name" "$id" "$saved" "$mc" "$mx"
                fi
                chmod 600 "$tmp_home"
                publish_file "$tmp_home" "$home/$f"
                say "$id: created the missing $f"
                [ "$f" != "$ENV_NAME" ] || say "$id: the stored proof was in the missing env file; store it again with: $PROG proof $C_NAME $id"
            done
            say "$id: exists, kept identity.key agent.conf$existing ($name, $saved, public key $(agent_field "$id" pubkey))"
            case "$brief_changed:$existing" in
                yes:*prompt.md*) say "$id: its prompt.md was written earlier and is unchanged. To rebuild it with the new brief, delete $home/prompt.md, run create again and restart the agent." ;;
            esac
            continue
        fi
        # A new agent is built in a temporary folder and renamed into place in one step.
        eval "b=\${REQ_$id:-claude}"
        eval "m=\${MODEL_$id:-}"
        mc='' mx=''
        if [ "$b" = claude ]; then mc=$m; else mx=$m; fi
        eval "e=\${EFFORT_$id:-}"
        W_EFFORT_CLAUDE='' W_EFFORT_CODEX=''
        if [ "$b" = claude ]; then W_EFFORT_CLAUDE=$e; else W_EFFORT_CODEX=$e; fi
        tmp_home=$(mktemp -d "$T_DIR/.new-$id.XXXXXX")
        TMP_PATHS+=("$tmp_home")
        chmod 700 "$tmp_home"
        NEW_PUBKEY=''
        generate_key "$tmp_home"
        about=$(default_about "$id")
        write_agent_conf "$tmp_home/agent.conf" "$id" "$name" "$NEW_PUBKEY" "$about" "$b" "$mc" "$mx"
        write_env "$tmp_home/$ENV_NAME" "$home" "$name" "$id" "$b" "$mc" "$mx"
        render_prompt "$id" "$tmp_home/prompt.md"
        chmod 600 "$tmp_home"/*
        if uses_partner_runtime "$id"; then install_partner_runtime "$tmp_home"; fi
        [ ! -e "$home" ] || die "$home appeared while this run was creating it; nothing was replaced"
        mv -- "$tmp_home" "$home"
        created_now="$created_now $id"
        say "$id: created $home ($name, $b)"
    done

    # The channel supervisor's subscription rules, written once every agent of the team has its key.
    # They are derived from public keys; a changed set replaces them and keeps the earlier file beside them.
    for id in $(team_agents); do
        is_channel_role "$id" || continue
        key=$(lower "$(agent_field "$id" pubkey)")
        tmp_home=$(mktemp "$T_DIR/$id/.new-rules.XXXXXX")
        TMP_PATHS+=("$tmp_home")
        write_rules "$tmp_home" "$key"
        chmod 600 "$tmp_home"
        if [ ! -f "$T_DIR/$id/subscriptions.toml" ]; then
            publish_file "$tmp_home" "$T_DIR/$id/subscriptions.toml"
            say "$id: wrote subscriptions.toml (it takes no turn for this channel's local agents)"
        elif ! cmp -s "$tmp_home" "$T_DIR/$id/subscriptions.toml"; then
            stamp=$(date -u '+%Y%m%dT%H%M%SZ')
            cp -p -- "$T_DIR/$id/subscriptions.toml" "$T_DIR/$id/subscriptions.toml.bak-$stamp"
            mv -f -- "$tmp_home" "$T_DIR/$id/subscriptions.toml"
            say "$id: refreshed subscriptions.toml for the agents now in this channel (earlier file: subscriptions.toml.bak-$stamp)"
        else
            rm -f -- "$tmp_home"
        fi
    done
    # Whom the workspace agent answers: the env file names the channel supervisor's public key. An env
    # file written before that supervisor existed is kept, as every existing file is; upgrade rewrites it.
    for id in $(team_agents); do
        is_workspace_role "$id" || continue
        v=$(env_get "$T_DIR/$id/$ENV_NAME" BUZZ_ACP_RESPOND_TO_ALLOWLIST 2>/dev/null) || v=''
        if [ "$v" != "$(answer_keys)" ]; then
            say "Note: the $id was set up to answer $(answers_text "$id"); to let it answer the channel supervisor now in this team or channel: $PROG upgrade $C_NAME"
        fi
    done
    if [ -n "$created_now" ] && [ -n "$peers" ]; then
        printf '%s\n' "$peers" | while IFS="$(printf '\t')" read -r ws pid prole pname; do
            is_channel_role "$prole" || continue
            say "Note: the channel supervisor of workspace \"$ws\" in this channel takes turns for these new agents until: $PROG upgrade $ws"
        done
    fi

    # The first thing a set of agents gets in its project folder: the sandbox settings of an agent
    # on the stock Claude adapter. A file that cannot be completed is reported; team.sh, which
    # writes the settings before every start, then refuses to start that agent until it is fixed.
    for id in $(team_agents); do
        on_stock_claude "$id" "$(agent_backend "$id")" || continue
        v=0
        f=$(workspace_settings apply "$C_WS_PATH") || v=$?
        if [ "$v" = 0 ]; then say "Project folder settings: $f"
        else warn "the settings of the $id were not written into the project folder: $f. $T_DIR/team.sh writes them before a start."; fi
        break
    done
    ensure_project_record
    say "Shared project record: $C_WS_PATH/PROJECT.md"
    # The team's own files. An existing file is kept, as every existing file is; upgrade refreshes it.
    for f in $(team_files); do
        [ "$f" != VERSION ] || continue
        v=$(team_file_state "$f")
        [ "$v" != missing ] || install_team_file "$f"
        [ "$f" = team.sh ] || continue
        case $v in
            missing) say "Team command: $T_DIR/team.sh (check, start, stop and status for this folder)" ;;
            differs) say "Team command: $T_DIR/team.sh exists and was kept; $PROG upgrade $C_NAME refreshes it" ;;
            *) say "Team command: $T_DIR/team.sh" ;;
        esac
    done

    say ''
    say "Agents of workspace \"$C_NAME\" (folder $C_WS_PATH, channel $C_CHANNEL):"
    for id in $(team_agents); do
        b=$(agent_backend "$id")
        m=$(agent_model "$id" "$b")
        printf '  %-11s %-26s %-7s %-18s public key %s\n' "$id" "$(agent_field "$id" name)" "$b" "${m:-runtime default}" "$(agent_field "$id" pubkey)"
    done
    for id in $(team_agents); do
        is_workspace_role "$id" || continue
        say "The workspace agent ($id) answers $(answers_text "$id")."
    done
    if [ -s "$T_DIR/brief.md" ]; then say "Workspace brief: $T_DIR/brief.md"; else say 'Workspace brief: none'; fi
    say ''
    say 'Next steps:'
    say '  1. In Buzz Desktop: Settings > Security > "Authorize external identity". Paste one'
    say '     public key above and copy the proof it gives you. Repeat for each agent.'
    say "  2. Store each proof: $PROG proof $C_NAME <agent>   (paste the proof, then Enter)"
    say "  3. Preview the community steps: $PROG finish $C_NAME --dry-run, then run them without --dry-run."
    say "  4. Check, then start the agents with the team's own command, from the project folder:"
    say "       cd $(shquote "$C_WS_PATH") && $T_DIR/team.sh check, then $T_DIR/team.sh"
    say '     The agents work in the folder it is run from, or in --workspace DIR. In a terminal it asks'
    say '     which agents to start, then the provider and the model of each.'
    say "     One agent at a time: $T_DIR/<agent>/start.sh starts that agent only. In a terminal it"
    say '     asks its provider, model and reasoning effort (Enter keeps the saved one; --yes asks nothing).'
}

# ---------------------------------------------------------------- proof
read_proof_input() { # ARG_OR_EMPTY -> PROOF_RAW
    local line n=0
    if [ -n "$1" ] && [ "$1" != - ]; then PROOF_RAW=$1; return; fi
    PROOF_RAW=''
    if [ -t 0 ]; then
        # A pasted proof may be wrapped over several lines: read until its closing bracket (at most 20 lines).
        printf 'Paste the proof from Buzz Desktop, then press Enter:\n' >&2
        while [ "$n" -lt 20 ] && IFS= read -r line; do
            PROOF_RAW="$PROOF_RAW$line"
            n=$((n + 1))
            case $PROOF_RAW in *']'*) break ;; esac
        done
    else
        PROOF_RAW=$(head -c 8192 || true)
    fi
}

cmd_verify_proof() {
    local agent=${1:-} arg=${2:-}
    is_hex64 "$agent" || die 'verify-proof: give the agent public key (64 hex characters) and the proof'
    agent=$(lower "$agent")
    read_proof_input "$arg"
    normalize_proof "$PROOF_RAW" || die "verify-proof: malformed proof: $PROOF_ERR"
    say "Proof for $agent:"
    check_proof "$agent" '' || die 'verify-proof: the proof failed a check (see above)'
    say 'All offline checks passed.'
}

cmd_proof() {
    local ws='' agent='' arg='' force=no skip_sig=no home env pubkey owner current tmp line done_line=no
    while [ "$#" -gt 0 ]; do
        case $1 in
            --force) force=yes ;;
            --no-signature-check) skip_sig=yes ;;
            -h | --help) usage; exit 0 ;;
            *) if [ -z "$ws" ]; then ws=$1; elif [ -z "$agent" ]; then agent=$1; elif [ -z "$arg" ]; then arg=$1
               else die 'proof: too many arguments (quote the proof, or pipe it in)'; fi ;;
        esac
        shift
    done
    [ -n "$ws" ] && [ -n "$agent" ] || die 'proof: usage: agent-team.sh proof NAME AGENT [PROOF | -] [--force] [--no-signature-check]'
    load_team "$ws"
    agent=$(select_agents "$agent")
    home=$T_DIR/$agent env=$home/$ENV_NAME
    [ -f "$env" ] || die "$env is missing; run create again to restore it"
    pubkey=$(agent_field "$agent" pubkey)
    owner=$(env_get "$env" BUZZ_ACP_AGENT_OWNER) || owner=$T_OWNER
    owner=$(lower "$owner")
    read_proof_input "$arg"
    normalize_proof "$PROOF_RAW" || die "proof: malformed proof, nothing stored: $PROOF_ERR"
    say "Proof for $agent ($(agent_field "$agent" name), public key $pubkey):"
    SIG_FAILED=no
    if ! check_proof "$pubkey" "$owner" "$skip_sig"; then
        if [ "$SIG_FAILED" = yes ]; then
            say 'If you copied this proof in Buzz Desktop for exactly the public key above, copy it again and retry.' >&2
            say 'If the same proof is still refused, the offline check may be wrong: store it with' >&2
            say "--no-signature-check; the agent's first start then checks it." >&2
        fi
        die 'proof: the proof failed a check (see above); nothing stored'
    fi
    take_lock "$T_DIR"
    current=$(proof_of "$agent")
    if [ "$current" = "$PROOF_JSON" ]; then say 'This proof is already stored; the env file is unchanged.'; return; fi
    if [ -n "$current" ] && [ "$force" = no ]; then
        die "$agent already has a different proof. To replace it, run the same command with --force."
    fi
    tmp=$(mktemp "$home/.new-env.XXXXXX")
    TMP_PATHS+=("$tmp")
    while IFS= read -r line || [ -n "$line" ]; do
        case ${line#"${line%%[![:space:]]*}"} in
            BUZZ_AUTH_TAG=* | BUZZ_AUTH_TAG[[:space:]]*=* | 'export '*BUZZ_AUTH_TAG=* | 'export '*BUZZ_AUTH_TAG[[:space:]]*=*)
                if [ "$done_line" = no ]; then printf 'BUZZ_AUTH_TAG=%s\n' "$PROOF_JSON"; done_line=yes; fi ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$env" > "$tmp"
    if [ "$done_line" = no ]; then printf 'BUZZ_AUTH_TAG=%s\n' "$PROOF_JSON" >> "$tmp"; fi
    chmod 600 "$tmp"
    [ "$(env_get "$tmp" BUZZ_AUTH_TAG)" = "$PROOF_JSON" ] || die 'proof: could not write the proof; the env file is unchanged'
    mv -f -- "$tmp" "$env"
    if [ -n "$current" ]; then say "Replaced the stored proof in $env"; else say "Stored the proof in $env"; fi
    if [ "$skip_sig" = yes ]; then
        say "Warning: this proof was stored WITHOUT checking its signature. The agent's first start is the"
        say "first real check: if $home/agent.log shows \"BUZZ_AUTH_TAG verification failed\" or a relay"
        say "connection error, or the agent never comes online, the proof is wrong. Then copy a new proof"
        say "in Buzz Desktop for public key $pubkey and store it with --force."
    fi
}

# ---------------------------------------------------------------- finish
cmd_finish() {
    local dry=no step=add role=bot ids=() id home name about pubkey launcher buzz rc agents relay
    while [ "$#" -gt 0 ]; do
        case $1 in
            --dry-run) dry=yes ;;
            --channel-step) need_value "$@"; step=$2; shift ;;
            --role) need_value "$@"; role=$2; shift ;;
            -h | --help) usage; exit 0 ;;
            -*) die "finish: unknown option: $1" ;;
            *) ids+=("$1") ;;
        esac
        shift
    done
    [ "${#ids[@]}" -ge 1 ] || die 'finish: usage: agent-team.sh finish NAME [AGENT...] [--dry-run] [--channel-step add|join|skip] [--role bot|member]'
    case $step in add | join | skip) ;; *) die "finish: --channel-step must be add, join or skip (got: $step)" ;; esac
    case $role in bot | member) ;; *) die "finish: --role must be bot or member (got: $role)" ;; esac
    load_team "${ids[0]}"
    agents=$(select_agents ${ids[@]:1}) || exit 1
    set -- $agents
    for id in "$@"; do
        [ -n "$(proof_of "$id")" ] || die "$id has no ownership proof yet; run: $PROG proof $T_NAME $id"
    done
    launcher=$(launcher_path)
    buzz=$(tool_path "${AGENT_TEAM_BUZZ:-}" buzz)
    if [ "$dry" = no ]; then
        [ -n "$launcher" ] || die 'launcher not found. Fix: agent-team.sh settings --launcher /path/to/run-buzz-acp.sh (or put it on PATH)'
        [ -n "$buzz" ] || die 'Buzz CLI not found: put buzz on PATH or set AGENT_TEAM_BUZZ'
    fi
    launcher=${launcher:-run-buzz-acp.sh} buzz=${buzz:-buzz}

    if [ "$dry" = yes ]; then say 'Dry run: nothing is run. These commands would run, in this order.'; fi
    say "Step 1, offline: the launcher checks each env file (from the agent's folder)."
    for id in "$@"; do
        home=$T_DIR/$id
        say "[$id]"
        print_cmd '  ' cd "$home"
        print_cmd '  ' "$launcher" --check
        if [ "$dry" = no ]; then
            rc=0
            (scrub_env; cd -- "$home" && exec "$launcher" --check) || rc=$?
            [ "$rc" = 0 ] || die "$id: the launcher check failed (exit $rc); fix the env file and run finish again"
        fi
    done

    say "Step 2, contacts the community: each agent sets its display name, signing as itself"
    say "(BUZZ_PRIVATE_KEY from identity.key and BUZZ_AUTH_TAG from $ENV_NAME, set only for this command)."
    for id in "$@"; do
        home=$T_DIR/$id name=$(agent_field "$id" name) about=$(agent_field "$id" about)
        relay=$(env_get "$home/$ENV_NAME" BUZZ_RELAY_URL) || relay=$T_COMMUNITY
        say "[$id]"
        print_cmd '  ' "$buzz" --relay "$relay" users set-profile --name "$name" --about "$about"
        if [ "$dry" = no ]; then
            rc=0
            run_as_agent "$home" "$buzz" --relay "$relay" users set-profile --name "$name" --about "$about" || rc=$?
            [ "$rc" = 0 ] || die "$id: setting the display name failed (exit $rc); nothing after it was run. Earlier steps are safe to repeat: run finish again."
        fi
    done

    case $step in
        add) say 'Step 3, contacts the community: you add each agent to the channel, signing as yourself'
             say '(your Buzz desktop pairing: buzz --relay <community> auth desktop pair, once; BUZZ_PRIVATE_KEY and BUZZ_AUTH_TAG are unset).' ;;
        join) say 'Step 3, contacts the community: each agent joins the open channel, signing as itself.' ;;
        skip) say 'Step 3, in Buzz Desktop: add each agent to the channel yourself (channel members).' ;;
    esac
    for id in "$@"; do
        home=$T_DIR/$id pubkey=$(agent_field "$id" pubkey)
        relay=$(env_get "$home/$ENV_NAME" BUZZ_RELAY_URL) || relay=$T_COMMUNITY
        say "[$id]"
        case $step in
            add)
                print_cmd '  ' "$buzz" --relay "$relay" channels add-member --channel "$T_CHANNEL" --pubkey "$pubkey" --role "$role"
                if [ "$dry" = no ]; then
                    rc=0
                    (unset BUZZ_PRIVATE_KEY BUZZ_AUTH_TAG; exec "$buzz" --relay "$relay" channels add-member --channel "$T_CHANNEL" --pubkey "$pubkey" --role "$role") || rc=$?
                    [ "$rc" = 0 ] || die "$id: adding it to the channel failed (exit $rc). Pair the CLI once with \`buzz --relay $relay auth desktop pair\`, or add the agent in Buzz Desktop and run finish with --channel-step skip."
                fi ;;
            join)
                print_cmd '  ' "$buzz" --relay "$relay" channels join --channel "$T_CHANNEL"
                if [ "$dry" = no ]; then
                    rc=0
                    run_as_agent "$home" "$buzz" --relay "$relay" channels join --channel "$T_CHANNEL" || rc=$?
                    [ "$rc" = 0 ] || die "$id: joining the channel failed (exit $rc). A private channel needs a member to add the agent: use --channel-step add or skip."
                fi ;;
            skip) say "  add $(agent_field "$id" name) (public key $pubkey) to channel $T_CHANNEL" ;;
        esac
    done
    say ''
    say "Before you start them, make sure no other member of the channel uses these display names."
    if [ "$dry" = yes ]; then say 'Dry run complete; nothing was run.'
    else say "Finished. Start the agents with: $PROG start $T_NAME"; fi
}

# Run ARGV with the agent's identity, set only in a subshell's environment (never in arguments).
run_as_agent() { # HOME ARGV...
    local home=$1
    shift
    (
        scrub_env
        BUZZ_PRIVATE_KEY=''
        IFS= read -r BUZZ_PRIVATE_KEY < "$home/identity.key" || [ -n "$BUZZ_PRIVATE_KEY" ] || exit 90
        BUZZ_AUTH_TAG=$(env_get "$home/$ENV_NAME" BUZZ_AUTH_TAG) || exit 91
        export BUZZ_PRIVATE_KEY BUZZ_AUTH_TAG
        exec "$@"
    )
}

# ---------------------------------------------------------------- start, stop, status
PF_PID='' PF_START='' PF_BACKEND=''
read_pidfile() { # HOME -> PF_PID PF_START PF_BACKEND; returns 1 when there is none
    PF_PID='' PF_START='' PF_BACKEND=''
    [ -f "$1/agent.pid" ] || return 1
    { IFS= read -r PF_PID && IFS= read -r PF_START && IFS= read -r PF_BACKEND; } < "$1/agent.pid" || true
    case $PF_PID in '' | *[!0-9]*) PF_PID=''; return 1 ;; esac
}
proc_start() { trim "$(ps -o lstart= -p "$1" 2>/dev/null || true)"; }
# The recorded process is alive and is the same process (same PID and start time) this tool started.
ours_alive() { # HOME
    read_pidfile "$1" || return 1
    kill -0 "$PF_PID" 2>/dev/null || return 1
    [ "$(proc_start "$PF_PID")" = "$PF_START" ]
}
# An upgrade that stopped half-way leaves .<agent>.upgrade.* or .<agent>.prev.* beside the agent folders.
upgrade_interrupted() {
    local p id
    for id in $ALL_ROLES; do
        for p in "$T_DIR/.$id.upgrade."* "$T_DIR/.$id.prev."*; do
            if [ -e "$p" ]; then return 0; fi
        done
    done
    return 1
}
require_current() { # ID...: stop unless each agent has the current record format
    local id v
    if upgrade_interrupted; then die "an upgrade of workspace \"$T_NAME\" was interrupted; finish it with: $PROG upgrade $T_NAME. Nothing was started."; fi
    for id in "$@"; do
        v=$(agent_format "$id")
        [ "$v" = "$FORMAT" ] || die "$(old_format_message "$T_NAME" "$v") Nothing was started."
    done
}

cmd_start() {
    local requested='' check_only=no role_args=() choice saved b runtime run_model='' m list
    local id home log pid launcher protocol wait_s max_bytes size i started='' alive agents eff am walled am_out
    [ "$#" -ge 1 ] || die 'start: usage: agent-team.sh start NAME [AGENT...] [--backend claude|codex] [--check]'
    load_team "$1"
    shift
    while [ "$#" -gt 0 ]; do
        case $1 in
            --backend) need_value "$@"; check_backend "$2"; requested=$2; shift ;;
            --model) need_value "$@"; run_model=$2; shift ;;
            --check) check_only=yes ;;
            -h | --help) usage; exit 0 ;;
            -*) die "start: unknown option: $1" ;;
            *) role_args+=("$1") ;;
        esac
        shift
    done
    agents=$(select_agents ${role_args[@]+"${role_args[@]}"}) || exit 1
    set -- $agents
    require_current "$@"
    if [ -z "$requested" ] && [ -t 0 ]; then
        printf 'Backend for %s [1 Claude, 2 Codex, Enter for the saved backends]: ' "$(printf '%s' "$agents" | tr '\n' ' ')" >&2
        IFS= read -r choice || die 'backend selection cancelled'
        case $choice in '') ;; 1|[Cc]laude) requested=claude ;; 2|[Cc]odex) requested=codex ;; *) die 'choose Claude or Codex' ;; esac
        if [ -z "$run_model" ]; then
            # The model, after the backend: the retrieved list when there is one; Enter keeps each saved model.
            b=${requested:-$(agent_backend "$1")}
            list=$(models_cache "$b" "$1")
            if [ -s "$list" ]; then
                say "Models offered for $b (retrieved $(sed -n '1s/^# retrieved //p' "$list" | cut -d' ' -f1)):" >&2
                grep -v '^#' "$list" | cut -f1 | tr '\n' ' ' | fold -s -w 100 | sed 's/^/  /' >&2
                printf '\n' >&2
            else
                say "No retrieved model list for $b yet ($PROG models --backend $b); the documented values apply." >&2
            fi
            for id in "$@"; do m=$(agent_model "$id" "$b"); say "  saved for $id on $b: ${m:-runtime default}" >&2; done
            printf 'Model for this run [Enter keeps each saved model]: ' >&2
            IFS= read -r choice || die 'model selection cancelled'
            run_model=$(trim "$choice")
        fi
    fi
    # Each agent's backend for this run: the choice, else its saved backend. A choice that would
    # switch an agent that is already running stops here, before anything starts.
    for id in "$@"; do
        saved=$(agent_backend "$id")
        check_backend "$saved"
        b=${requested:-$saved}
        eval "RUN_BACKEND_$id=\$b"
        if [ -n "$run_model" ]; then require_model "$b" "$id" "$run_model"; fi
        if [ "$check_only" = no ] && [ -n "$requested" ] && ours_alive "$T_DIR/$id" && [ "${PF_BACKEND:-unrecorded}" != "$requested" ]; then
            die "$id is running as PID $PF_PID on ${PF_BACKEND:-an unrecorded backend}, not $requested; nothing was started. Stop it first ($PROG stop $T_NAME $id), then start it again with --backend $requested."
        fi
    done
    launcher=$(launcher_path)
    [ -n "$launcher" ] || die 'launcher not found. Fix: agent-team.sh settings --launcher /path/to/run-buzz-acp.sh (or put it on PATH)'
    protocol=${CLAUDE_AGENT_ACP_PROTOCOL:-v1}
    wait_s=${AGENT_TEAM_START_WAIT:-3}
    max_bytes=${AGENT_TEAM_LOG_MAX_BYTES:-10485760}
    case $wait_s in '' | *[!0-9]*) die 'AGENT_TEAM_START_WAIT must be whole seconds' ;; esac
    case $max_bytes in '' | *[!0-9]*) die 'AGENT_TEAM_LOG_MAX_BYTES must be a number of bytes' ;; esac
    [ "$wait_s" -le 60 ] || die 'AGENT_TEAM_START_WAIT is capped at 60 seconds'
    for id in "$@"; do
        [ -n "$(proof_of "$id")" ] || die "$id has no ownership proof; nothing was started. Run: $PROG proof $T_NAME $id"
        [ -f "$T_DIR/$id/$ENV_NAME" ] && [ -f "$T_DIR/$id/identity.key" ] || die "$id is missing its env or key file; nothing was started"
    done
    if [ "$check_only" = no ]; then take_lock "$T_DIR"; fi
    # Validate the whole selection, sign-in included, before starting the first stopped agent.
    for id in "$@"; do
        if [ "$check_only" = no ] && ours_alive "$T_DIR/$id"; then continue; fi
        eval "b=\$RUN_BACKEND_$id"
        if uses_partner_runtime "$id"; then
            # The channel supervisor and the reviewer run their own runtime copy; that copy is what is checked.
            runtime=$T_DIR/$id/runtime/$(backend_command "$b")
            [ -x "$runtime" ] || die "$id: its runtime has no $(backend_command "$b"); refresh it with: $PROG upgrade $T_NAME. Nothing was started."
            "$runtime" --check-runtime || die "$id: the $b restricted runtime check failed (see above); nothing was started"
        fi
        (scrub_env
         cd -- "$T_DIR/$id" && "$launcher" --check --backend "$b" ${run_model:+--model "$run_model"}) || die "$id failed its $b launcher check (see above); nothing was started"
    done
    if [ "$check_only" = yes ]; then say "Launcher checks passed."; return; fi
    say "Launcher: $launcher"
    for id in "$@"; do
        home=$T_DIR/$id log=$home/agent.log
        if ours_alive "$home"; then say "$id: already running as PID $PF_PID on ${PF_BACKEND:-an unrecorded backend}; not started again"; continue; fi
        eval "b=\$RUN_BACKEND_$id"
        if [ -f "$log" ]; then
            size=$(wc -c < "$log" | tr -d ' ')
            if [ "$size" -gt "$max_bytes" ]; then mv -f -- "$log" "$log.1"; fi
        fi
        # The agent's saved reasoning effort for that backend: Claude by variable, Codex in the model name.
        eff=$(agent_effort "$id" "$b") am=$run_model
        if [ "$b" = codex ] && [ -n "$eff" ]; then
            am=${run_model:-$(agent_model "$id" codex)}
            am=${am%\[*\]}
            if [ -n "$am" ]; then am="$am[$eff]"; fi
        fi
        # An agent on the stock Claude adapter gets its settings in the project folder first, as team.sh does.
        if on_stock_claude "$id" "$b"; then
            walled=0
            am_out=$(workspace_settings apply "$T_WORKSPACE") || walled=$?
            [ "$walled" = 0 ] || die "$id: its settings could not be put into the project folder: $am_out. Nothing more was started."
            case $am_out in 'in place:'*) ;; *) say "$id: project folder settings: $am_out" ;; esac
        fi
        printf '\n=== %s: agent-team.sh start (%s, backend %s) ===\n' "$(now_utc)" "$launcher" "$b" >> "$log"
        (
            scrub_env
            export CLAUDE_AGENT_ACP_PROTOCOL=$protocol
            if [ "$b" = claude ] && [ -n "$eff" ]; then export CLAUDE_CODE_EFFORT_LEVEL=$eff; fi
            # The stock Codex adapter's workspace-write mode, whatever the calling shell exports.
            if on_stock_codex "$id" "$b"; then export INITIAL_AGENT_MODE=agent; fi
            trap '' HUP
            cd -- "$home" && exec "$launcher" --run --backend "$b" ${am:+--model "$am"}
        ) >> "$log" 2>&1 < /dev/null &
        pid=$!
        printf '%s\n%s\n%s\n' "$pid" "$(proc_start "$pid")" "$b" > "$home/.new-pid"
        mv -f -- "$home/.new-pid" "$home/agent.pid"
        alive=yes
        i=0
        while [ "$i" -lt $((wait_s * 5)) ]; do
            if ! kill -0 "$pid" 2>/dev/null; then alive=no; break; fi
            sleep 0.2
            i=$((i + 1))
        done
        if [ "$alive" = no ] || ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            say "$PROG: $id exited right after starting. Last lines of $log:" >&2
            tail -n 20 "$log" >&2 || true
            [ -z "$started" ] || say "Still running: $started" >&2
            die "$id did not start"
        fi
        say "$id: started as PID $pid on $b (log $log)"
        started="$started${started:+, }$id"
    done
}

stop_one() { # ID FORCE GRACE -> 0 stopped or not running, 1 still running
    local id=$1 home=$T_DIR/$1 i
    if ! read_pidfile "$home"; then say "$id: not started by this tool; nothing to stop"; return 0; fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then say "$id: not running"; rm -f -- "$home/agent.pid"; return 0; fi
    if [ "$(proc_start "$PF_PID")" != "$PF_START" ]; then
        say "$id: PID $PF_PID now belongs to another process; it was not touched"
        rm -f -- "$home/agent.pid"
        return 0
    fi
    kill -TERM "$PF_PID" 2>/dev/null || true
    i=0
    while [ "$i" -lt $(($3 * 5)) ] && kill -0 "$PF_PID" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
    if kill -0 "$PF_PID" 2>/dev/null && [ "$2" = yes ]; then
        kill -KILL "$PF_PID" 2>/dev/null || true
        i=0
        while [ "$i" -lt 25 ] && kill -0 "$PF_PID" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
    fi
    if kill -0 "$PF_PID" 2>/dev/null; then
        say "$id: still running as PID $PF_PID after ${3}s; run stop again, or stop --force" >&2
        return 1
    fi
    rm -f -- "$home/agent.pid"
    say "$id: stopped (PID $PF_PID)"
}

cmd_stop() {
    local force=no grace ids=() id failed=0 agents
    while [ "$#" -gt 0 ]; do
        case $1 in
            --force) force=yes ;;
            -h | --help) usage; exit 0 ;;
            -*) die "stop: unknown option: $1" ;;
            *) ids+=("$1") ;;
        esac
        shift
    done
    [ "${#ids[@]}" -ge 1 ] || die 'stop: usage: agent-team.sh stop NAME [AGENT...] [--force]'
    grace=${AGENT_TEAM_STOP_GRACE:-30}
    case $grace in '' | *[!0-9]*) die 'AGENT_TEAM_STOP_GRACE must be whole seconds' ;; esac
    [ "$grace" -le 600 ] || die 'AGENT_TEAM_STOP_GRACE is capped at 600 seconds'
    load_team "${ids[0]}"
    agents=$(select_agents ${ids[@]:1}) || exit 1
    set -- $agents
    for id in "$@"; do stop_one "$id" "$force" "$grace" || failed=1; done
    [ "$failed" = 0 ] || die 'some agents are still running (see above)'
}

cmd_status() {
    local id home size proof run d fmt b mode m e sv tv
    sv=$(version_in "$(skill_dir)/VERSION") || sv='(no valid VERSION file)'
    if [ "$#" -eq 0 ]; then
        resolve_root
        say "Root: $ROOT"
        say "Skill: buzz-agent-team $sv"
        for d in "$ROOT"/*/; do
            [ -f "$d/team.conf" ] || continue
            fmt=$(conf_get "$d/team.conf" format || printf '1')
            [ "$fmt" = "$FORMAT" ] || fmt="$fmt, earlier than $FORMAT: $PROG upgrade $(basename -- "$d") --dry-run"
            say "  $(basename -- "$d")  $(conf_get "$d/team.conf" workspace)  channel $(conf_get "$d/team.conf" channel)  format $fmt  skill $(version_in "$d/VERSION" || printf 'not recorded')"
        done
        return
    fi
    load_team "$1"
    say "Workspace \"$T_NAME\": $T_WORKSPACE"
    say "Channel $T_CHANNEL on $T_COMMUNITY; owner $T_OWNER"
    if ! tv=$(team_version); then say "Team files: no skill version recorded (written before 1.0.0); this skill is $sv: $PROG upgrade $T_NAME --dry-run shows what it would change"
    elif [ "$tv" = "$sv" ]; then say "Team files: written by buzz-agent-team $tv, this skill's version"
    else say "Team files: written by buzz-agent-team $tv; this skill is $sv: $PROG upgrade $T_NAME --dry-run shows what it would change"; fi
    d=$(launcher_path)
    say "Launcher for start: ${d:-not found (agent-team.sh settings --launcher /path/to/run-buzz-acp.sh)}"
    [ -z "$T_EXT_SUPERVISOR" ] || say "Channel supervisor (in another team of this channel): $T_EXT_SUPERVISOR"
    [ -z "$T_EXT_ASSISTANT" ] || say "Workspace agent (in another team of this channel): $T_EXT_ASSISTANT"
    fmt=$(team_format)
    if [ "$fmt" != "$FORMAT" ]; then
        say "Team folder: $(format_words "$fmt"); it starts only after: $PROG upgrade $T_NAME --dry-run, then $PROG upgrade $T_NAME"
    fi
    if upgrade_interrupted; then say "An upgrade was interrupted: run $PROG upgrade $T_NAME to finish it."; fi
    for id in $(team_agents); do
        home=$T_DIR/$id
        fmt=$(agent_format "$id")
        b=$(agent_backend "$id")
        mode=''
        if [ -f "$home/$ENV_NAME" ]; then mode=$(env_get "$home/$ENV_NAME" BUZZ_SIGN_IN) || mode=''; fi
        if [ "$mode" = subscription ]; then
            if [ "$b" = codex ]; then mode='sign-in: your ChatGPT sign-in only'; else mode='sign-in: your Claude subscription only'; fi
        else
            mode="sign-in: not limited to a subscription; run $PROG upgrade $T_NAME"
        fi
        if [ -n "$(proof_of "$id")" ]; then proof='proof stored'; else proof='NO PROOF YET'; fi
        if ours_alive "$home"; then run="running on ${PF_BACKEND:-an unrecorded backend}, PID $PF_PID since $PF_START"
        elif read_pidfile "$home"; then run='not running (exited; see the log)'
        else run='not running'; fi
        size=0
        if [ -f "$home/agent.log" ]; then size=$(wc -c < "$home/agent.log" | tr -d ' '); fi
        if [ "$fmt" = "$FORMAT" ]; then
            say "  $id: $(agent_field "$id" name), $(job_words "$id")"
            m=$(agent_model "$id" "$b"); e=$(agent_effort "$id" "$b")
            say "    backend $b, model ${m:-runtime default}${e:+, reasoning effort $e}; $mode"
            say "    answers $(answers_text "$id")"
        else
            say "  $id: $(agent_field "$id" name)"
            say "    $(format_words "$fmt"): run $PROG upgrade $T_NAME --dry-run, then $PROG upgrade $T_NAME"
        fi
        say "    public key $(agent_field "$id" pubkey); $proof; $run"
        say "    folder $home; log agent.log ($size bytes)"
    done
}

# ---------------------------------------------------------------- settings
# Validate one setting before it is written. A failure stops the run; nothing is saved.
validate_setting() { # NAME VALUE
    local n=$1 v=$2
    case $v in *[[:cntrl:]]*) die "settings: $n contains control characters" ;; esac
    refuse_secret "settings: $n" "$v"
    case $n in
        keygen | launcher)
            case $v in /*) ;; *) die "settings: $n must be an absolute path (got: $v)" ;; esac
            [ -f "$v" ] && [ -x "$v" ] || die "settings: $n is not an executable file: $v" ;;
        community)
            valid_ws_url "$v" || die "settings: community must be a plain ws:// or wss:// address, with no user name, password, query or spaces (got: $v)" ;;
        owner)
            case $v in npub1*) die 'settings: owner needs the 64-character hex public key; an npub does not work' ;; esac
            is_hex64 "$v" || die 'settings: owner must be your 64-character hex public key' ;;
        model)
            claude_documented_model "$v" || die 'settings: model is the default for Claude agents: an alias Claude Code documents (opus, sonnet, haiku, fable) or a full name such as claude-opus-5-5 ("default" names no model; unset it for the runtime default)' ;;
        base_url)
            die 'settings: base_url is no longer used: agents sign in through your subscription only. Remove it with: agent-team.sh settings --unset base_url' ;;
        *) die "settings: unknown setting: $n" ;;
    esac
}

show_settings() {
    local f=$ROOT/settings.conf n v
    if [ -f "$f" ]; then say "Settings: $f (mode $(file_mode "$f"))"; else say "Settings: $f (not created yet)"; fi
    for n in $SETTING_NAMES; do
        v=$(setting "$n")
        printf '  %-9s %s\n' "$n" "${v:-(not set)}"
    done
}
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

cmd_settings() {
    local n v from_env='' changes=0 f tmp new_keygen='' new_launcher='' new_community='' new_owner='' new_model='' new_base_url=''
    local set_list=' ' unset_list=' '
    while [ "$#" -gt 0 ]; do
        case $1 in
            --base-url) die 'settings: agents sign in through your subscription only; a gateway address (--base-url) is not stored' ;;
            --keygen | --launcher | --community | --relay | --owner | --model)
                need_value "$@"
                case $1 in --relay) n=community ;; *) n=${1#--} ;; esac
                eval "new_$n=\$2"
                set_list="$set_list$n "
                shift ;;
            --from-env) need_value "$@"; from_env=$2; shift ;;
            --unset)
                need_value "$@"
                case " $SETTING_NAMES " in *" $2 "*) ;; *) die "settings: --unset takes one of: $SETTING_NAMES" ;; esac
                unset_list="$unset_list$2 "
                shift ;;
            -h | --help) usage; exit 0 ;;
            *) die "settings: unknown option: $1 (see agent-team.sh help)" ;;
        esac
        shift
    done
    resolve_root git
    f=$ROOT/settings.conf
    if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then die "settings: $f is not a regular file; it was not touched"; fi
    if [ -n "$from_env" ]; then
        [ -f "$from_env" ] && [ -r "$from_env" ] || die "settings: cannot read --from-env file: $from_env"
        # Only these three public values are read from the file; options win over them.
        for n in community owner model; do
            case " $set_list" in *" $n "*) continue ;; esac
            case $n in
                community) v=$(env_get "$from_env" BUZZ_RELAY_URL) || v='' ;;
                owner) v=$(env_get "$from_env" BUZZ_ACP_AGENT_OWNER) || v='' ;;
                model) v=$(env_get "$from_env" BUZZ_ACP_MODEL) || v='' ;;
            esac
            if [ -n "$v" ]; then eval "new_$n=\$v"; set_list="$set_list$n "; fi
        done
    fi
    if [ "$set_list" = ' ' ] && [ "$unset_list" = ' ' ]; then show_settings; return; fi
    # The new file: every kept, set or cleared value, each validated again before writing.
    for n in $SETTING_NAMES; do
        case " $unset_list" in *" $n "*) eval "V_$n=''"; changes=$((changes + 1)); continue ;; esac
        case " $set_list" in
            *" $n "*) eval "v=\$new_$n"; changes=$((changes + 1)) ;;
            *) v=$(setting "$n") ;;
        esac
        [ "$n" != owner ] || v=$(lower "$v")
        if [ "$n" = base_url ] && [ -n "$v" ]; then
            say 'Removed base_url: agents sign in through your subscription only, so no gateway address is kept.'
            v=''
        fi
        if [ -n "$v" ]; then validate_setting "$n" "$v"; fi
        eval "V_$n=\$v"
    done
    mkdir -p -- "$ROOT"
    chmod 700 "$ROOT"
    take_lock "$ROOT"
    tmp=$(mktemp "$ROOT/.new-settings.XXXXXX")
    TMP_PATHS+=("$tmp")
    {
        printf '# agent-team.sh settings: public values only. No key, proof or API key is stored here.\n'
        printf '# Change them with: agent-team.sh settings --help\n'
        printf 'format=1\n'
        for n in $SETTING_NAMES; do
            eval "v=\$V_$n"
            if [ -n "$v" ]; then printf '%s=%s\n' "$n" "$v"; fi
        done
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$f"
    say "Saved $changes change(s) to $f"
    show_settings
}

# ---------------------------------------------------------------- preflight
PF_MISSING=0
pf_line() { # STATE NAME DETAIL [FIX]
    printf '  %-8s %-17s %s\n' "$1" "$2" "$3"
    if [ -n "${4:-}" ]; then
        if [ "$1" = 'not set' ]; then printf '  %-8s %-17s to set: %s\n' '' '' "$4"
        else printf '  %-8s %-17s fix: %s\n' '' '' "$4"; fi
    fi
    case $1 in MISSING | PROBLEM) PF_MISSING=$((PF_MISSING + 1)) ;; esac
}
# One role's checks: its adapter, the runtime it runs, and the sign-in of the CLI that runtime runs.
signin_env() { # CMD...: run CMD in this subshell's environment without the names the launcher removes
    local n
    for n in $(compgen -e); do if credential_name "$n"; then unset "$n"; fi; done
    unset CLAUDE_CODE_EXECUTABLE
    "$@"
}
pf_role() { # ID BACKEND RUNTIME_DIR WORKDIR
    local id=$1 b=$2 rt=$3 ws=$4 adapter cmd d out status=0 method plan f names
    adapter=$(backend_command "$b")
    say "Role $id ($(job_words "$id" | sed 's/^the //')): $b"
    d=$(command -v -- "$adapter" 2>/dev/null || true)
    if [ -z "$d" ]; then
        if [ "$b" = codex ]; then pf_line MISSING "$adapter" 'not on PATH' 'install @agentclientprotocol/codex-acp@1.13.1 under your user npm prefix'
        else pf_line MISSING "$adapter" 'not on PATH (the agents'"'"' model runtime)' 'install the Claude Code ACP adapter and put claude-agent-acp on PATH'; fi
        return 0
    fi
    pf_line ok "$adapter" "$d"
    # The stock Codex adapter that the workspace agent runs must be the tested one.
    if [ "$b" = codex ] && ! uses_partner_runtime "$id"; then
        case $(codex-acp --version 2>/dev/null) in
            *' 1.13.1') pf_line ok 'adapter protocol' '1.13.1 (Buzz-compatible)' ;;
            *) pf_line PROBLEM 'adapter protocol' 'unverified adapter version' 'install @agentclientprotocol/codex-acp@1.13.1 under the user npm prefix' ;;
        esac
    fi
    out=$(mktemp "${TMPDIR:-/tmp}/agent-team-preflight.XXXXXX")
    TMP_PATHS+=("$out")
    cmd=$adapter
    if uses_partner_runtime "$id"; then
        cmd=$rt/$adapter
        if [ ! -x "$cmd" ]; then
            pf_line PROBLEM 'restricted runtime' "$cmd is missing" "$PROG upgrade <name> (or install the skill again)"
            return 0
        fi
        if bounded 60 "$out" "$cmd" --check-runtime; then pf_line ok 'restricted runtime' "$cmd"
        else pf_line PROBLEM 'restricted runtime' "$(tail -n 1 "$out" | cut -c1-160)" 'install what the line names (see SKILL.md, step 1)'; fi
    fi
    # The sign-in, asked of the CLI this role will run (the channel supervisor: its restricted runtime).
    status=0
    if [ "$b" = claude ]; then
        (signin_env bounded 30 "$out" "$cmd" --cli auth status) || status=$?   # as the launcher will run it
        method=$(grep -Eo '"authMethod"[[:space:]]*:[[:space:]]*"[^"]*"' "$out" | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/') || true
        plan=$(grep -Eo '"subscriptionType"[[:space:]]*:[[:space:]]*"[^"]*"' "$out" | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/') || true
        if [ "$status" = 124 ]; then pf_line PROBLEM 'Claude sign-in' 'the check did not answer within 30 s' 'run claude auth status --text in your terminal and retry'
        else
            case $method in
                claude.ai) pf_line ok 'Claude sign-in' "your Claude subscription${plan:+ ($plan)}" ;;
                '' | none) pf_line PROBLEM 'Claude sign-in' 'not signed in' 'in your own terminal: claude auth login (choose your Claude subscription)' ;;
                *) pf_line PROBLEM 'Claude sign-in' "uses $method, not your Claude subscription" 'remove that credential (unset it or delete it from the settings file), then: claude auth login' ;;
            esac
        fi
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            names=$(claude_settings_overrides "$f")
            [ -z "$names" ] || pf_line PROBLEM 'Claude settings' "$f sets ${names% }" "remove those entries from $f; agents sign in by subscription only"
        done < <(claude_settings_files "$ws")
    else
        if uses_partner_runtime "$id"; then (signin_env bounded 30 "$out" "$cmd" --sign-in-status) || status=$?
        else (signin_env bounded 30 "$out" "$cmd" cli login status) || status=$?; fi   # the Codex CLI the stock adapter runs
        if [ "$status" = 124 ]; then pf_line PROBLEM 'Codex sign-in' 'the check did not answer within 30 s' 'run codex login status in your terminal and retry'
        elif grep -iq 'Logged in using ChatGPT' "$out"; then pf_line ok 'Codex sign-in' 'your ChatGPT sign-in'
        else pf_line PROBLEM 'Codex sign-in' 'not signed in with ChatGPT' 'in your own terminal: codex login (choose Sign in with ChatGPT)'; fi
        names=$(codex_config_overrides)
        [ -z "$names" ] || pf_line PROBLEM 'Codex config' "${CODEX_HOME:-$HOME/.codex}/config.toml sets ${names% }" 'remove or change those top-level keys; agents use your ChatGPT sign-in and the OpenAI provider'
    fi
    rm -f -- "$out"
}
cmd_preflight() {
    local top f p n v d team='' roles_arg='' roles='assistant supervisor' b_all='' b_a='' b_s='' b_r='' id b rt ws='' names
    while [ "$#" -gt 0 ]; do
        case $1 in
            --backend) need_value "$@"; check_backend "$2"; b_all=$2; shift ;;
            --assistant-backend) need_value "$@"; check_backend "$2"; b_a=$2; shift ;;
            --supervisor-backend) need_value "$@"; check_backend "$2"; b_s=$2; shift ;;
            --reviewer-backend) need_value "$@"; check_backend "$2"; b_r=$2; shift ;;
            --roles) need_value "$@"; roles_arg=$2; shift ;;
            --partner) ;;
            -h|--help) usage; return ;;
            -*) die "unknown preflight option: $1" ;;
            *) [ -z "$team" ] || die 'preflight takes one workspace NAME'; team=$1 ;;
        esac
        shift
    done
    case $roles_arg in
        '' | assistant,supervisor | supervisor,assistant) ;;
        assistant) roles=assistant ;;
        reviewer) roles=reviewer ;;
        *) die "preflight: --roles must be assistant,supervisor, assistant or reviewer (got: $roles_arg)" ;;
    esac
    PF_MISSING=0
    say 'Preflight (changes nothing):'
    resolve_root
    if top=$(git_top "$ROOT"); then
        pf_line PROBLEM 'agents root' "$ROOT is inside the Git work tree $top" 'export AGENT_TEAM_ROOT=/some/folder/outside/git (the default is ~/.buzz-agents)'
    elif [ -d "$ROOT" ]; then
        if [ -w "$ROOT" ]; then pf_line ok 'agents root' "$ROOT"; else pf_line PROBLEM 'agents root' "$ROOT is not writable" "chmod u+w '$ROOT'"; fi
    else
        p=$ROOT
        while [ ! -d "$p" ]; do p=$(dirname -- "$p"); done
        if [ -w "$p" ]; then pf_line ok 'agents root' "$ROOT (created by create or settings)"
        else pf_line PROBLEM 'agents root' "$ROOT cannot be created: $p is not writable" 'export AGENT_TEAM_ROOT=/a/writable/folder'; fi
    fi
    f=$ROOT/settings.conf
    if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
        pf_line PROBLEM 'settings file' "$f is not a regular file" "move it aside: mv '$f' '$f.old'"
    elif [ -f "$f" ]; then
        if [ "$(file_mode "$f")" = 600 ]; then pf_line ok 'settings file' "$f"
        else pf_line PROBLEM 'settings file' "$f has mode $(file_mode "$f")" "chmod 600 '$f'"; fi
        for n in $SETTING_NAMES; do
            v=$(setting "$n")
            [ -n "$v" ] || continue
            if [ "$n" = base_url ]; then
                pf_line PROBLEM 'setting base_url' 'a gateway address is saved; agents sign in by subscription only' 'agent-team.sh settings --unset base_url'
            elif ! (validate_setting "$n" "$v") >/dev/null 2>&1; then
                pf_line PROBLEM "setting $n" 'holds an invalid value' "agent-team.sh settings --unset $n"
            fi
        done
    else
        pf_line ok 'settings file' "none yet (agent-team.sh settings creates it)"
    fi
    d=$(keygen_path)
    if [ -n "$d" ]; then pf_line ok 'key generator' "$d"
    else pf_line MISSING 'key generator' 'buzz-admin not found' 'agent-team.sh settings --keygen /path/to/buzz-admin (in a Buzz checkout: target/debug/buzz-admin)'; fi
    d=$(launcher_path)
    if [ -n "$d" ]; then pf_line ok 'launcher' "$d"
    else pf_line MISSING 'launcher' 'run-buzz-acp.sh not found' 'agent-team.sh settings --launcher /path/to/run-buzz-acp.sh (in a Buzz checkout: local/buzz-acp/run-buzz-acp.sh)'; fi
    say "  Launcher: ${d:-not found}"
    # The launcher itself requires these on PATH, so settings cannot stand in for them.
    for n in buzz buzz-acp; do
        d=$(command -v -- "$n" 2>/dev/null || true)
        if [ -n "$d" ]; then pf_line ok "$n" "$d"
        else pf_line MISSING "$n" 'not on PATH' "export PATH=\"/folder/with/$n:\$PATH\" (in a Buzz checkout: target/release)"; fi
    done
    if [ -n "${AGENT_TEAM_BUZZ:-}" ]; then
        if [ -n "$(tool_path "$AGENT_TEAM_BUZZ" buzz)" ]; then pf_line ok 'buzz for finish' "$AGENT_TEAM_BUZZ"
        else pf_line PROBLEM 'buzz for finish' "AGENT_TEAM_BUZZ=$AGENT_TEAM_BUZZ is not executable" 'unset AGENT_TEAM_BUZZ'; fi
    fi
    if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then pf_line ok 'sha256 tool' 'found'
    else pf_line MISSING 'sha256 tool' 'neither shasum nor sha256sum found (the launcher needs one)' 'install shasum or sha256sum'; fi
    if command -v git >/dev/null 2>&1; then pf_line ok 'git' 'found (used to keep keys out of Git work trees)'
    else pf_line warning 'git' 'not found: the Git work-tree check is skipped'; fi
    d=${AGENT_TEAM_PYTHON:-python3}
    if [ "$d" != none ] && command -v -- "$d" >/dev/null 2>&1; then pf_line ok 'python3' 'found (offline proof signature check)'
    else pf_line warning 'python3' 'not found: proof signatures are checked only when an agent starts'; fi
    names=''
    for n in $(compgen -e); do if credential_name "$n"; then names="$names${names:+ }$n"; fi; done
    if [ -n "$names" ]; then pf_line note 'this shell' "exports $names; the launcher removes them for every agent (names only)"; fi
    # Each role: its backend, the runtime it runs and that runtime's sign-in.
    if [ -n "$team" ]; then
        load_team "$team"
        ws=$T_WORKSPACE
        roles=$(team_agents | tr '\n' ' ')
        [ -n "$roles" ] || die "workspace \"$team\" has no agents"
    fi
    for id in $roles; do
        case $id in assistant) b=$b_a ;; reviewer) b=$b_r ;; *) b=$b_s ;; esac
        b=${b:-$b_all}
        rt=$(skill_dir)/runtime
        if [ -n "$team" ]; then
            b=${b:-$(agent_backend "$id")}
            v=$(agent_format "$id")
            if [ "$v" = "$FORMAT" ]; then rt=$T_DIR/$id/runtime
            else pf_line PROBLEM "$id record" "$(format_words "$v")" "$PROG upgrade $team --dry-run, then $PROG upgrade $team"; fi
        fi
        pf_role "$id" "${b:-claude}" "$rt" "$ws"
    done
    say 'Defaults (asked for when not set):'
    for n in community owner model; do
        v=$(setting "$n")
        case $n in
            community | owner)
                if [ -n "$v" ]; then pf_line ok "$n" "$v"; else pf_line 'not set' "$n" 'create needs it: give it once, or remember it' "agent-team.sh settings --$n <value>"; fi ;;
            model)
                if [ -n "$v" ]; then pf_line ok model "$v (Claude agents only)"
                else pf_line 'not set' model "optional: each runtime's default model is used" 'agent-team.sh settings --model <value>'; fi ;;
        esac
    done
    if [ "$PF_MISSING" -gt 0 ]; then
        say "Preflight: $PF_MISSING required item(s) missing or wrong; fix the lines marked MISSING or PROBLEM, then run preflight again."
        exit 1
    fi
    say 'Preflight passed: everything a setup needs is in place.'
}

# ---------------------------------------------------------------- models
# List the models the user's own sign-in offers for a backend and role, without a model turn: one ACP
# session (initialize, session/new) with the runtime that role runs, in the agents' subscription-only
# environment (scripts/acp-models.py; at most 30 s, no retry). The list is kept under <root>/models/
# for the model checks; on failure the reason is shown with the documented list, and exit is 1.
cmd_models() {
    # Without --role: the workspace agent's, the role on the stock adapter (before 3.0.0, the supervisor's).
    local backend='' role=assistant team='' adapter cmd py out status=0 list ok n saved line id name timeout
    while [ "$#" -gt 0 ]; do
        case $1 in
            --backend) need_value "$@"; check_backend "$2"; backend=$2; shift ;;
            --role) need_value "$@"; role=$2; shift ;;
            -h | --help) usage; return ;;
            -*) die "models: unknown option: $1" ;;
            *) [ -z "$team" ] || die 'models takes one workspace NAME'; team=$1 ;;
        esac
        shift
    done
    case $role in assistant | supervisor | reviewer) ;; *) die 'models: --role must be assistant, supervisor or reviewer' ;; esac
    resolve_root
    if [ -n "$team" ]; then load_team "$team"; backend=${backend:-$(agent_backend "$role")}; fi
    backend=${backend:-claude}
    adapter=$(backend_command "$backend")
    if uses_partner_runtime "$role"; then
        cmd=$(skill_dir)/runtime/$adapter
        if [ -n "$team" ] && [ "$(agent_format "$role")" = "$FORMAT" ]; then cmd=$T_DIR/$role/runtime/$adapter; fi
        [ -x "$cmd" ] || die "models: the restricted runtime $cmd is missing"
    else
        cmd=$(command -v -- "$adapter" 2>/dev/null) || die "models: $adapter is not on PATH"
    fi
    py=${AGENT_TEAM_PYTHON:-python3}
    [ "$py" != none ] && command -v -- "$py" >/dev/null 2>&1 || die 'models: python3 is needed to read the model list'
    # At most 30 s (AGENT_TEAM_MODELS_TIMEOUT may only shorten it, for tests).
    timeout=${AGENT_TEAM_MODELS_TIMEOUT:-30}
    case $timeout in '' | *[!0-9]*) die 'AGENT_TEAM_MODELS_TIMEOUT must be whole seconds' ;; esac
    [ "$timeout" -ge 1 ] && [ "$timeout" -le 30 ] || timeout=30
    out=$(mktemp "${TMPDIR:-/tmp}/agent-team-models.XXXXXX")
    TMP_PATHS+=("$out")
    (
        scrub_env
        for n in $(compgen -e); do if credential_name "$n"; then unset "$n"; fi; done
        unset CLAUDE_CODE_EXECUTABLE
        export CLAUDE_AGENT_ACP_PROTOCOL=v1
        "$py" -I "$(script_dir)/acp-models.py" --timeout "$timeout" -- "$cmd"
    ) > "$out" 2>/dev/null || status=$?
    say "Models for the $role on $backend ($cmd):"
    if [ "$status" = 0 ] && "$py" -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") and d.get("models")
for m in d["models"]: print(m + "\t" + (d.get("names") or {}).get(m, "").replace("\t", " "))' "$out" > "$out.list" 2>/dev/null && [ -s "$out.list" ]; then
        list=$(models_cache "$backend" "$role")
        mkdir -p -- "$ROOT/models"
        chmod 700 "$ROOT/models"
        { printf '# retrieved %s from %s\n' "$(now_utc)" "$cmd"; cat -- "$out.list"; } > "$out.save"
        chmod 600 "$out.save"
        mv -f -- "$out.save" "$list"
        saved=''
        if [ -n "$team" ]; then saved=$(agent_model "$role" "$backend"); fi
        while IFS="$(printf '\t')" read -r id name; do
            line="  $id"
            [ -z "$name" ] || line="$line   $name"
            [ "$id" != "$saved" ] || line="$line   (saved for this agent)"
            [ "$id" != claude-opus-5-5 ] || line="$line   (live-test default)"
            say "$line"
        done < "$out.list"
        if [ "$backend" = claude ] && ! cut -f1 "$out.list" | grep -qx claude-opus-5-5; then
            if cut -f2 "$out.list" | grep -q 'Opus 5.5'; then
                say "claude-opus-5-5 is not listed by that name; the list offers Opus 5.5 as $(awk -F '\t' '$2 ~ /Opus 5.5/ { print $1; exit }' "$out.list"), so claude-opus-5-5 is accepted and the adapter resolves it."
            else
                say 'claude-opus-5-5 (Opus 5.5) is not in this list: choose another model from it.'
            fi
        fi
        say "Kept for the model checks: $list"
        rm -f -- "$out.list"
        return 0
    fi
    rm -f -- "$out.list"
    say "  not retrieved: $("$py" -I -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(d.get("reason") or "the listing gave no answer")' "$out" 2>/dev/null || printf 'the listing gave no answer')"
    say 'Documented list instead (not from your sign-in):'
    if [ "$backend" = claude ]; then
        say '  aliases: best fable sonnet opus haiku sonnet[1m] opus[1m] opusplan (Claude Code model-config; "default" names no model here)'
        say '  full names, for example: claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-2'
    else
        list=$(codex_bundled_models "$role" | tr '\n' ' ')
        if [ -n "$list" ]; then say "  $list(the bundled catalog of $(codex_cli_of "$role"))"; else say "  none available offline (the $role's Codex CLI could not list its bundled catalog)"; fi
    fi
    exit 1
}

# ---------------------------------------------------------------- upgrade
# Bring a team to the current format (3) and to the chosen backends. identity.key, the stored proof
# and PROJECT.md stay byte-identical. Each agent folder is rebuilt beside itself and swapped in with
# two renames; the next run finishes or undoes an interrupted swap, so a folder is old or new.
# From format 2 the two jobs swap: each agent keeps its folder, key, proof, display name, backend,
# models and efforts, and gets the generated files of its new job (the runtime and the subscription
# rules move from the assistant to the supervisor; every replaced or removed file is kept beside itself).
GENERATED_COMMON='agent.conf .env.buzz-acp.local prompt.md'
GENERATED_RUNTIME='runtime/claude-agent-acp runtime/restricted-claude runtime/buzz-tools runtime/codex-acp'
GENERATED_RULES='subscriptions.toml'
generated_files() { # ID: the files upgrade writes for that role
    local gen=$GENERATED_COMMON
    if uses_partner_runtime "$1"; then gen="$gen $GENERATED_RUNTIME"; fi
    if is_channel_role "$1"; then gen="$gen $GENERATED_RULES"; fi
    printf '%s' "$gen"
}
# What a format-2 agent did before it is converted: the other job of its role id.
old_job_words() { # ID
    if is_workspace_role "$1"; then printf 'the discussion partner'
    elif is_channel_role "$1"; then printf 'the workspace supervisor'
    else job_words "$1"; fi
}
job_detail() { # ID: what the new job holds, for the upgrade plan
    local keys k names=''
    if is_workspace_role "$1"; then
        keys=$(answer_keys)
        for k in ${keys//,/ }; do names="$names${names:+, }$(key_name "$k")"; done
        if [ -n "$names" ]; then names="the owner and $names"; else names='the owner only'; fi
        printf 'the stock adapter with all its tools and worker subagents, in bypass-permissions; it answers %s' "$names"
    else
        printf 'the restricted runtime: it reads the project folder and cannot edit or run commands; it takes a turn on every ordinary message in its channel'
    fi
}
recover_upgrade() {
    local id home p
    for id in $ALL_ROLES; do
        home=$T_DIR/$id
        for p in "$T_DIR/.$id.upgrade."*; do
            [ -d "$p" ] || continue
            if [ ! -e "$home" ] && [ -f "$p/.upgrade-complete" ]; then
                mv -- "$p" "$home"
                say "$id: finished an interrupted upgrade"
            else
                rm -rf -- "$p"
                say "$id: removed the unfinished copy of an interrupted upgrade (the folder is unchanged)"
            fi
        done
        for p in "$T_DIR/.$id.prev."*; do
            [ -d "$p" ] || continue
            if [ ! -e "$home" ]; then mv -- "$p" "$home"; say "$id: restored its folder from before an interrupted upgrade"
            else rm -rf -- "$p"; fi
        done
        rm -f -- "$home/.upgrade-complete"
    done
}
# The launcher's single-copy lock for this agent's key is held by a live process (run-buzz-acp.sh lock).
launcher_lock_alive() { # HOME
    local key='' name lock pid args
    IFS= read -r key < "$1/identity.key" || true
    key=$(printf '%s' "$key" | tr -d '[:space:]' | LC_ALL=C tr 'A-Z' 'a-z')
    case $key in nsec1* | '') key=''; return 1 ;; esac
    name=$(printf 'buzz-acp-lock:%s' "$key" | sha256_text)
    key=''
    lock=${TMPDIR:-/tmp}
    lock=${lock%/}/buzz-acp-locks-$(id -u)/agent-$name.lock
    [ -f "$lock" ] || return 1
    IFS= read -r pid < "$lock" || return 1
    case $pid in '' | *[!0-9]*) return 1 ;; esac
    name=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    case ${name##*/} in buzz-acp) return 0 ;; esac
    args=$(ps -ww -o args= -p "$pid" 2>/dev/null) || return 1
    case $args in *run-buzz-acp.sh*) return 0 ;; esac
    return 1
}
# The stored proof as one line, its value bytes unchanged; BUZZ_AUTH_TAG= when there is none.
auth_tag_line() { # ENV_FILE
    local line key out='BUZZ_AUTH_TAG='
    if [ -f "$1" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%$'\r'}
            line=${line#"${line%%[![:space:]]*}"}
            case $line in 'export '*) line=${line#export }; line=${line#"${line%%[![:space:]]*}"} ;; esac
            case $line in *=*) ;; *) continue ;; esac
            key=${line%%=*}
            key=${key%"${key##*[![:space:]]}"}
            [ "$key" = BUZZ_AUTH_TAG ] || continue
            line=${line#*=}
            line=${line#"${line%%[![:space:]]*}"}
            line=${line%"${line##*[![:space:]]}"}
            out="BUZZ_AUTH_TAG=$line"
        done < "$1"
    fi
    printf '%s' "$out"
}
env_keys() { # FILE: setting names, one line, sorted (names only)
    [ -f "$1" ] || return 0
    sed -E -e 's/^[[:space:]]*(export[[:space:]]+)?//' -e '/^#/d' -e '/^$/d' -e 's/[[:space:]]*=.*$//' "$1" | LC_ALL=C sort -u | tr '\n' ' '
}
build_agent_files() { # ID HOME STAGE BACKEND MODEL_CLAUDE MODEL_CODEX: every generated file, into STAGE
    local id=$1 home=$2 st=$3 b=$4 name pubkey about created upgraded file
    name=$(agent_field "$id" name)
    pubkey=$(lower "$(agent_field "$id" pubkey)")
    about=$(conf_get "$home/agent.conf" about) || about=''
    created=$(conf_get "$home/agent.conf" created) || created=$UPGRADE_NOW
    if [ "$(agent_format "$id")" = "$FORMAT" ]; then upgraded=$(conf_get "$home/agent.conf" upgraded) || upgraded=''
    else
        # A converted agent: the description of its profile follows its new job (finish publishes it).
        upgraded=$UPGRADE_NOW about=$(default_about "$id")
    fi
    write_agent_conf "$st/agent.conf" "$id" "$name" "$pubkey" "$about" "$b" "$5" "$6" "$created" "$upgraded"
    write_env "$st/$ENV_NAME" "$home" "$name" "$id" "$b" "$5" "$6" "$(auth_tag_line "$home/$ENV_NAME")"
    P_AGENT_NAME=$name
    render_prompt "$id" "$st/prompt.md"
    chmod 600 "$st/agent.conf" "$st/$ENV_NAME" "$st/prompt.md"
    if uses_partner_runtime "$id"; then
        mkdir -p -- "$st/runtime"
        chmod 700 "$st/runtime"
        for file in $RUNTIME_FILES; do
            cp -- "$(skill_dir)/runtime/$file" "$st/runtime/$file"
            chmod 700 "$st/runtime/$file"
        done
    fi
    if is_channel_role "$id"; then
        write_rules "$st/subscriptions.toml" "$pubkey"
        chmod 600 "$st/subscriptions.toml"
    fi
}
cmd_upgrade() {
    local dry=no b_all='' b_a='' b_s='' b_r='' model_set=no opt_model='' team='' id home fmt old_b new_b st m old_m
    local gen rel f changed added removed any=no stamp prev ws peers dropped k old_keys new_keys tmp list keep pass m_a='' m_s='' m_r='' mc mx e old_e ec ex e_all='' e_a='' e_s='' e_r=''
    local v ws_claude=no
    while [ "$#" -gt 0 ]; do
        case $1 in
            --dry-run) dry=yes ;;
            --backend) need_value "$@"; check_backend "$2"; b_all=$2; shift ;;
            --assistant-backend) need_value "$@"; check_backend "$2"; b_a=$2; shift ;;
            --supervisor-backend) need_value "$@"; check_backend "$2"; b_s=$2; shift ;;
            --reviewer-backend) need_value "$@"; check_backend "$2"; b_r=$2; shift ;;
            --model) [ "$#" -ge 2 ] || die '--model needs a value'; opt_model=$2; model_set=yes; shift ;;
            --assistant-model) need_value "$@"; m_a=$2; shift ;;
            --supervisor-model) need_value "$@"; m_s=$2; shift ;;
            --reviewer-model) need_value "$@"; m_r=$2; shift ;;
            --effort) need_value "$@"; e_all=$2; shift ;;
            --assistant-effort) need_value "$@"; e_a=$2; shift ;;
            --supervisor-effort) need_value "$@"; e_s=$2; shift ;;
            --reviewer-effort) need_value "$@"; e_r=$2; shift ;;
            -h | --help) usage; exit 0 ;;
            -*) die "upgrade: unknown option: $1" ;;
            *) [ -z "$team" ] || die 'upgrade takes one workspace NAME'; team=$1 ;;
        esac
        shift
    done
    [ -n "$team" ] || die 'upgrade: usage: agent-team.sh upgrade NAME [--dry-run] [--backend B] [--assistant-backend B] [--supervisor-backend B] [--model ID]'
    need_skill_version
    load_team "$team"
    [ -n "$(team_agents)" ] || die "workspace \"$team\" has no agent folders to upgrade"
    C_NAME=$T_NAME C_WS_PATH=$T_WORKSPACE C_CHANNEL=$T_CHANNEL C_COMMUNITY=$T_COMMUNITY C_OWNER=$T_OWNER
    C_EXT_ASSISTANT=$T_EXT_ASSISTANT C_EXT_SUPERVISOR=$T_EXT_SUPERVISOR
    [ -d "$C_WS_PATH" ] || die "the workspace folder $C_WS_PATH is missing; nothing was changed"
    # A running agent stops the upgrade before anything, the lock included, is written.
    for id in $ALL_ROLES; do
        [ -f "$T_DIR/$id/identity.key" ] || continue
        if ours_alive "$T_DIR/$id" || launcher_lock_alive "$T_DIR/$id"; then
            die "$id is running; stop it first ($PROG stop $T_NAME), then upgrade. Nothing was changed."
        fi
    done
    if upgrade_interrupted; then
        if [ "$dry" = yes ]; then say 'Note: an earlier upgrade was interrupted; upgrade without --dry-run finishes or undoes it first.'
        else take_lock "$T_DIR"; recover_upgrade; fi
    fi
    UPGRADE_NOW=$(now_utc)
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    # Prompt placeholders, as create sets them.
    NAME_assistant='' NAME_supervisor='' NAME_reviewer=''
    for id in $(team_agents); do eval "NAME_$id=\$(agent_field \"\$id\" name)"; done
    peers=$(channel_peers "$C_CHANNEL" "$C_NAME")
    P_WORKSPACE=$C_WS_PATH P_CHANNEL=$C_CHANNEL P_OWNER=$C_OWNER
    set_role_names "$peers"
    if [ "$dry" = yes ]; then say "Upgrade plan for workspace \"$T_NAME\" ($T_DIR); nothing is changed:"
    else say "Upgrade of workspace \"$T_NAME\" ($T_DIR):"; fi
    [ "$(team_format)" = "$FORMAT" ] || any=yes
    # Pass 1 plans in a temporary folder outside the team, so an up-to-date team is never touched.
    # Pass 2 rebuilds each changed agent beside its folder and swaps it in.
    for pass in plan apply; do
        if [ "$pass" = apply ]; then
            if [ "$dry" = yes ] || [ "$any" = no ]; then break; fi
            [ -n "$LOCK_DIR" ] || take_lock "$T_DIR"
        fi
        for id in $(team_agents); do
            home=$T_DIR/$id
            fmt=$(agent_format "$id")
            old_b=$(agent_backend "$id")
            case $id in assistant) new_b=${b_a:-${b_all:-$old_b}} ;; reviewer) new_b=${b_r:-${b_all:-$old_b}} ;; *) new_b=${b_s:-${b_all:-$old_b}} ;; esac
            check_backend "$new_b"
            if on_stock_claude "$id" "$new_b"; then ws_claude=yes; fi
            # One model per backend: the chosen one for the new backend, else the saved one; the
            # other backend's saved model stays. A format-1 agent's single model is not carried.
            old_m='' mc='' mx=''
            if [ "$fmt" != 1 ] && grep -q '^model_' "$home/agent.conf"; then
                mc=$(agent_model "$id" claude) mx=$(agent_model "$id" codex)
                if [ "$new_b" = claude ]; then old_m=$mc; else old_m=$mx; fi
            elif [ -f "$home/$ENV_NAME" ]; then
                old_m=$(env_get "$home/$ENV_NAME" BUZZ_ACP_MODEL) || old_m=''
                # A 20 November record keeps its one model for its own backend only.
                if [ "$fmt" != 1 ] && [ -n "$old_m" ]; then
                    if [ "$old_b" = claude ]; then mc=$old_m; else mx=$old_m; fi
                    [ "$new_b" = "$old_b" ] || old_m=''
                fi
            fi
            case $id in assistant) m=$m_a ;; reviewer) m=$m_r ;; *) m=$m_s ;; esac
            if [ -z "$m" ] && [ "$model_set" = yes ]; then m=$opt_model; fi
            if [ -n "$m" ]; then
                [ "$pass" = apply ] || require_model "$new_b" "$id" "$m"
                if [ "$new_b" = claude ]; then mc=$m; else mx=$m; fi
            fi
            if [ "$new_b" = claude ]; then m=$mc; else m=$mx; fi
            # One reasoning effort per backend, kept as the model is. An option sets the one of the
            # new backend; "default" clears it.
            ec=$(agent_effort "$id" claude) ex=$(agent_effort "$id" codex)
            if [ "$new_b" = claude ]; then old_e=$ec; else old_e=$ex; fi
            case $id in assistant) e=$e_a ;; reviewer) e=$e_r ;; *) e=$e_s ;; esac
            [ -n "$e" ] || e=$e_all
            if [ -n "$e" ]; then
                case $e in default | none) e='' ;; esac
                [ "$pass" = apply ] || require_effort "$new_b" "$id" "$m" "$e"
                if [ "$new_b" = claude ]; then ec=$e; else ex=$e; fi
            fi
            if [ "$new_b" = claude ]; then e=$ec; else e=$ex; fi
            W_EFFORT_CLAUDE=$ec W_EFFORT_CODEX=$ex
            if [ "$pass" = plan ]; then st=$(mktemp -d "${TMPDIR:-/tmp}/agent-team-plan.XXXXXX")
            else st=$(mktemp -d "$T_DIR/.$id.upgrade.XXXXXX"); fi
            TMP_PATHS+=("$st")
            chmod 700 "$st"
            build_agent_files "$id" "$home" "$st" "$new_b" "$mc" "$mx"
            gen=$(generated_files "$id")
            changed='' added='' removed=''
            for rel in $gen; do
                if [ ! -e "$home/$rel" ]; then added="$added $rel"
                elif ! cmp -s "$st/$rel" "$home/$rel"; then changed="$changed $rel"; fi
            done
            if [ -d "$home/runtime" ]; then
                for f in "$home/runtime"/*; do
                    [ -f "$f" ] || continue
                    rel=runtime/${f##*/}
                    case $rel in *.bak-*) continue ;; esac
                    case " $gen " in *" $rel "*) ;; *) removed="$removed $rel" ;; esac
                done
            fi
            if ! is_channel_role "$id" && [ -f "$home/subscriptions.toml" ]; then removed="$removed $GENERATED_RULES"; fi
            if [ "$pass" = plan ]; then
                old_keys=$(env_keys "$home/$ENV_NAME")
                new_keys=$(env_keys "$st/$ENV_NAME")
                dropped=''
                for k in $old_keys; do case " $new_keys " in *" $k "*) ;; *) dropped="$dropped $k" ;; esac; done
                say "  $id ($(agent_field "$id" name)): format $fmt -> $FORMAT; backend $old_b -> $new_b"
                rm -rf -- "$st"
                if [ -z "$changed$added$removed" ]; then say '    up to date; nothing to change'; continue; fi
                # A converted agent: the job it has from now on, and the model it keeps for it.
                if [ "$fmt" != "$FORMAT" ] && [ "$id" != reviewer ]; then
                    say "    job: $(old_job_words "$id") until now; from now on $(job_words "$id") ($(job_detail "$id"))"
                    if [ "$old_m" = "$m" ]; then
                        say "    keeps its saved model on $new_b: ${m:-runtime default}${e:+, reasoning effort $e}. It was chosen for the earlier job; to choose another: --$id-model ID"
                    fi
                fi
                any=yes
                [ -z "$changed" ] || say "    replace (each kept as <file>.bak-$stamp):$changed"
                [ -z "$added" ] || say "    add:$added"
                [ -z "$removed" ] || say "    remove (each kept as <file>.bak-$stamp):$removed"
                say '    keep byte-identical: identity.key, the stored proof'
                [ -z "$dropped" ] || say "    settings not carried into the new env file (names only):$dropped"
                if [ "$old_m" != "$m" ]; then say "    model ($new_b): ${old_m:-runtime default} -> ${m:-runtime default}"; fi
                if [ "$old_e" != "$e" ]; then say "    reasoning effort ($new_b): ${old_e:-none set here} -> ${e:-none set here}"; fi
                continue
            fi
            if [ -z "$changed$added$removed" ]; then rm -rf -- "$st"; continue; fi
            # Everything not generated is carried over; every replaced or removed file is kept beside itself.
            cp -p -- "$home/identity.key" "$st/identity.key"
            list=$st/.upgrade-list
            (cd -- "$home" && find . -type f) > "$list"
            while IFS= read -r rel; do
                rel=${rel#./}
                case $rel in identity.key | .upgrade-complete | .upgrade-list) continue ;; esac
                mkdir -p -- "$(dirname -- "$st/$rel")"
                case " $changed $removed " in
                    *" $rel "*) cp -p -- "$home/$rel" "$st/$rel.bak-$stamp"; chmod 600 "$st/$rel.bak-$stamp"; continue ;;
                esac
                # A generated file that did not change is already in the new folder.
                case " $gen " in *" $rel "*) continue ;; esac
                cp -p -- "$home/$rel" "$st/$rel"
            done < "$list"
            rm -f -- "$list"
            cmp -s "$home/identity.key" "$st/identity.key" || die "$id: could not copy identity.key; nothing was changed"
            [ "$(env_get "$st/$ENV_NAME" BUZZ_AUTH_TAG || true)" = "$(proof_of "$id")" ] || die "$id: the proof did not carry over; nothing was changed"
            : > "$st/.upgrade-complete"
            # From here an interruption is finished by the next run (recover_upgrade), never torn.
            keep=()
            for f in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do [ "$f" = "$st" ] || keep+=("$f"); done
            TMP_PATHS=(${keep[@]+"${keep[@]}"})
            prev=$T_DIR/.$id.prev.$stamp
            mv -- "$home" "$prev"
            # Test hook (as AGENT_TEAM_INSTALL_FAULT in install.sh): die between the two renames.
            if [ "${AGENT_TEAM_UPGRADE_FAULT:-}" = between-renames ]; then kill -9 $$; fi
            mv -- "$st" "$home"
            rm -f -- "$home/.upgrade-complete"
            rm -rf -- "$prev"
            say "  $id: upgraded"
        done
        if [ "$pass" = plan ] && [ "$(team_format)" != "$FORMAT" ]; then
            say "  team.conf: format $(team_format) -> $FORMAT (kept as team.conf.bak-$stamp)"
            # The two jobs swap (the lines of each agent say which it has from now on).
            v=''
            for id in $(team_agents); do
                if is_workspace_role "$id"; then v="${v}w"; elif is_channel_role "$id"; then v="${v}c"; fi
            done
            if [ "$v" = c ]; then
                say "  note: this team has no assistant, so it has no workspace agent of its own. Its supervisor becomes a channel supervisor and takes a turn on every ordinary message in its channel${C_EXT_ASSISTANT:+, beside $C_EXT_ASSISTANT, the assistant of another team}."
            fi
            if [ -n "$v" ]; then
                say "  Buzz profiles: each agent's description follows its new job; Buzz shows the earlier one until finish runs again ($PROG finish $T_NAME --dry-run shows its steps)"
            fi
        fi
        if [ "$pass" = plan ]; then
            for f in $(team_files); do
                [ "$f" != VERSION ] || continue
                case $(team_file_state "$f") in
                    missing) any=yes; say "  $f: add" ;;
                    differs) any=yes; say "  $f: replace (kept as $f.bak-$stamp)" ;;
                esac
            done
            # A team made before 2.0.0 holds the wall programs; the settings in the project folder replace them.
            if [ -e "$T_DIR/wall" ]; then any=yes; say "  wall/: remove (kept as wall.bak-$stamp); the settings in the project folder replace it"; fi
            if [ "$ws_claude" = yes ]; then
                v=0
                f=$(workspace_settings check "$C_WS_PATH") || v=$?
                case $v in
                    0) ;;
                    3) any=yes; say "  $C_WS_PATH/.claude/settings.json: add (the workspace agent's sandbox settings)" ;;
                    4) any=yes; say "  $C_WS_PATH/.claude/settings.json: complete (${f#*json }; the earlier file is kept beside it)" ;;
                    5) say "  $C_WS_PATH/.claude/settings.json: not checked ($f)" ;;
                    *) die "the settings file in the project folder cannot be used: $f" ;;
                esac
            fi
            if [ "$(team_file_state VERSION)" != current ]; then
                any=yes
                say "  VERSION: $(team_version || printf 'not recorded') -> $SKILL_VERSION"
            fi
        fi
    done
    if [ "$dry" = no ] && [ "$any" = yes ]; then
        for f in $(team_files); do
            [ "$f" != VERSION ] || continue
            case $(team_file_state "$f") in
                missing) install_team_file "$f"; say "  $f: added" ;;
                differs) install_team_file "$f" "$stamp"; say "  $f: replaced" ;;
            esac
        done
        if [ -e "$T_DIR/wall" ]; then
            mv -- "$T_DIR/wall" "$T_DIR/wall.bak-$stamp"
            say "  wall/: removed (kept as wall.bak-$stamp)"
        fi
        if [ "$ws_claude" = yes ]; then
            v=0
            f=$(workspace_settings apply "$C_WS_PATH") || v=$?
            [ "$v" = 0 ] || die "the workspace agent's settings could not be put into the project folder: $f. Fix that, then run $PROG upgrade $T_NAME again; the version is recorded only then."
            case $f in 'in place:'*) ;; *) say "  $f" ;; esac
        fi
    fi
    if [ "$dry" = no ] && [ "$any" = yes ] && [ "$(team_format)" != "$FORMAT" ]; then
        cp -p -- "$T_DIR/team.conf" "$T_DIR/team.conf.bak-$stamp"
        tmp=$(mktemp "$T_DIR/.new-team.XXXXXX")
        TMP_PATHS+=("$tmp")
        sed -E "s/^format=[0-9]+\$/format=$FORMAT/" "$T_DIR/team.conf" > "$tmp"
        grep -qx "format=$FORMAT" "$tmp" || printf 'format=%s\n' "$FORMAT" >> "$tmp"
        chmod 600 "$tmp"
        mv -f -- "$tmp" "$T_DIR/team.conf"
        say '  team.conf: upgraded'
    fi
    if [ -f "$C_WS_PATH/PROJECT.md" ]; then say "  $C_WS_PATH/PROJECT.md: kept unchanged"
    elif [ "$dry" = yes ]; then say "  $C_WS_PATH/PROJECT.md: would be created from the template"
    else ensure_project_record; say "  $C_WS_PATH/PROJECT.md: created from the template"; fi
    # The version is recorded last: until every other file is this skill's, the folder keeps the
    # version it had, and the next upgrade finishes what an interrupted one left.
    if [ "$dry" = no ] && [ "$any" = yes ] && [ "$(team_file_state VERSION)" != current ]; then
        [ "${AGENT_TEAM_UPGRADE_FAULT:-}" != before-version ] || kill -9 $$
        install_team_file VERSION
        say "  VERSION: $SKILL_VERSION"
    fi
    if [ "$any" = no ]; then say "Workspace \"$T_NAME\" is up to date; nothing was changed."; return; fi
    if [ "$dry" = yes ]; then say "Run it: $PROG upgrade $T_NAME$( [ -z "$b_all" ] || printf ' --backend %s' "$b_all")$( [ -z "$b_a" ] || printf ' --assistant-backend %s' "$b_a")$( [ -z "$b_s" ] || printf ' --supervisor-backend %s' "$b_s")$( [ -z "$b_r" ] || printf ' --reviewer-backend %s' "$b_r")$( [ "$model_set" = no ] || printf ' --model %s' "$(shquote "$opt_model")")$( [ -z "$m_a" ] || printf ' --assistant-model %s' "$(shquote "$m_a")")$( [ -z "$m_s" ] || printf ' --supervisor-model %s' "$(shquote "$m_s")")$( [ -z "$m_r" ] || printf ' --reviewer-model %s' "$(shquote "$m_r")")$( [ -z "$e_all" ] || printf ' --effort %s' "$e_all")$( [ -z "$e_a" ] || printf ' --assistant-effort %s' "$e_a")$( [ -z "$e_s" ] || printf ' --supervisor-effort %s' "$e_s")$( [ -z "$e_r" ] || printf ' --reviewer-effort %s' "$e_r")"
    else say "Upgraded. Next, with the team's own command, from the project folder: cd $(shquote "$T_WORKSPACE") && $T_DIR/team.sh check, then $T_DIR/team.sh"; fi
}

# ---------------------------------------------------------------- version
cmd_version() {
    [ "$#" -eq 0 ] || die 'version takes no argument (a team'"'"'s recorded version: agent-team.sh status NAME)'
    need_skill_version
    say "buzz-agent-team $SKILL_VERSION"
}

# ---------------------------------------------------------------- main
[ "$#" -ge 1 ] || { usage >&2; exit 1; }
cmd=$1
shift
case $cmd in
    create) cmd_create "$@" ;;
    proof) cmd_proof "$@" ;;
    verify-proof) cmd_verify_proof "$@" ;;
    finish) cmd_finish "$@" ;;
    start) cmd_start "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    models) cmd_models "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    preflight) cmd_preflight "$@" ;;
    settings) cmd_settings "$@" ;;
    version | --version | -V) cmd_version "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command: $cmd (see agent-team.sh help)" ;;
esac
