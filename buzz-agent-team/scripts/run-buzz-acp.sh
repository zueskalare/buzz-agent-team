#!/usr/bin/env bash
# Standalone Buzz ACP launcher, Bash 3.2+. The env-file template is embedded here.
# No companion example file and no repository lookup are needed.
#
# FIRST RUN (from the project where the agent should work):
#   run-buzz-acp.sh --init             # creates ./.env.buzz-acp.local, mode 600
#   nano .env.buzz-acp.local           # fill in community, owner and agent keys
#   run-buzz-acp.sh --check            # validates settings; starts nothing
#   run-buzz-acp.sh                    # runs the agent in this directory
# Run and check refuse while Git could stage a file that holds a secret.
#
# If using the project copy, replace run-buzz-acp.sh above with:
#   ./local/buzz-acp/run-buzz-acp.sh
#
# BINARIES: buzz, buzz-acp, and the selected ACP runtime must be on PATH.
# To use this checkout's release binaries, from the checkout root run:
#   export PATH="$PWD/target/release:$PATH"
# The default runtime is claude-agent-acp. Install/configure it separately.
#
# ONE-RUN OVERRIDES (options > exported environment > env file > defaults):
#   run-buzz-acp.sh --community wss://community.example.org \
#     --base-url https://api.anthropic.com --model YOUR_MODEL_ID \
#     --prompt 'Read AGENTS.md. Work in this directory and report your checks.'
#   run-buzz-acp.sh --prompt-file ./prompt.md
#   BUZZ_ACP_INITIAL_MESSAGE='Inspect this project.' run-buzz-acp.sh
# System prompt = instructions; initial message = a task to run on startup.
#
# IDENTITY: use a separate agent key. Admit its public key to the community and
# a channel, then @mention it from your owner account. The owner setting itself
# grants no membership. BUZZ_AUTH_TAG must be issued for this exact agent.
# A second run with the same agent key on this machine is refused; another
# machine is not checked. Ctrl-C stops this foreground run.
#
# MOVING PROJECTS/DEVICES: carry the script and your private project env file;
# install binaries matching the new device's OS/CPU. Stop an old instance before
# reusing its identity. The script takes no settings from global files or keys.
#
# SUBSCRIPTION SIGN-IN: with BUZZ_SIGN_IN=subscription (agent-team.sh writes it) the
# agent signs in only through your Claude or ChatGPT subscription. Credential,
# endpoint and provider variables are removed and refused in the env file; the
# Claude settings files or the Codex config are checked for overrides; and the
# CLI the agent runs must report a subscription sign-in.

set -euo pipefail

die() { printf 'run-buzz-acp.sh: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
is_secret_name() {
    case $1 in
        RUN_BUZZ_ACP_KEY_FILE) return 1 ;;
        *PRIVATE_KEY | *_API_KEY | *_TOKEN | *SECRET* | *PASSWORD*) return 0 ;;
    esac
    return 1
}

# True when Git could stage FILE: inside a work tree, not ignored (or already tracked).
stageable() {
    local dir base status
    STAGE_TOP='' STAGE_TRACKED=no
    command -v git >/dev/null 2>&1 || return 1
    dir=$(cd -- "$(dirname -- "$1")" && pwd -P) || return 1
    base=$(basename -- "$1")
    STAGE_TOP=$(cd -- "$dir" && unset GIT_DIR GIT_WORK_TREE && git rev-parse --show-toplevel 2>/dev/null) || return 1
    status=0
    (cd -- "$dir" && unset GIT_DIR GIT_WORK_TREE && git check-ignore -q -- "$base") || status=$?
    case $status in
        0) return 1 ;;
        1) ;;
        *) die "cannot check Git ignore rules for $1 (git check-ignore exit $status)" ;;
    esac
    STAGE_REL=${dir#"$STAGE_TOP"}/$base
    STAGE_EXCLUDE=$(cd -- "$dir" && unset GIT_DIR GIT_WORK_TREE CDPATH && cd -- "$(git rev-parse --git-common-dir)" && pwd -P)/info/exclude ||
        STAGE_EXCLUDE=.git/info/exclude
    if (cd -- "$dir" && unset GIT_DIR GIT_WORK_TREE && git ls-files --error-unmatch -- "$base" >/dev/null 2>&1); then
        STAGE_TRACKED=yes
    fi
}
stage_advice() { # FILE WHAT
    printf '%s holds %s, and Git can stage it:\n' "$1" "$2"
    if [ "$STAGE_TRACKED" = yes ]; then
        printf '  it is already tracked; untrack it first: git -C '\''%s'\'' rm --cached -- '\''%s'\''\n' "$STAGE_TOP" "${STAGE_REL#/}"
    else
        printf '  it is inside the Git work tree %s and not ignored.\n' "$STAGE_TOP"
    fi
    printf '  Fix: add an ignore rule, for example: echo '\''%s'\'' >> '\''%s'\''\n' "$STAGE_REL" "$STAGE_EXCLUDE"
    printf '  (or the same line in a .gitignore), or keep the secret outside the repository\n'
    printf '  (--env-file FILE, or RUN_BUZZ_ACP_KEY_FILE with BUZZ_PRIVATE_KEY empty).\n'
    printf '  This script never edits ignore files.\n'
}
refuse_stageable() { # FILE WHAT
    stageable "$1" || return 0
    { printf 'run-buzz-acp.sh: '; stage_advice "$1" "$2"; } >&2
    die 'refusing to continue while Git can stage a secret; nothing was started'
}

usage() {
    cat <<'EOF'
Usage: run-buzz-acp.sh [--init | --run | --check] [OPTIONS]

  --init           Create ./.env.buzz-acp.local from this script's template.
                   Never overwrites an existing file. Starts nothing.
  --check          Load the project env file and validate settings/executables.
                   Starts nothing; does not check network, membership or auth.
  --run            Load the project env file and start buzz-acp (default).
  --env-file FILE  Use another env file for init/check/run (launch-relative).
  --community URL  Community WebSocket URL (alias: --relay).
  --owner HEX      Your own 64-character hex public key.
  --base-url URL   Claude Code model API base URL, separate from the community.
  --backend NAME   Choose claude or codex. Interactive runs offer a choice.
                   With --init, save it in the new env file with subscription
                   sign-in (BUZZ_SIGN_IN=subscription; no API key or endpoint).
  --model ID       ACP session model; otherwise the runtime chooses its default.
                   An env file may keep one model per backend (BUZZ_MODEL_CLAUDE,
                   BUZZ_MODEL_CODEX); the selected backend's model is used.
  --prompt TEXT    Inline agent instructions; overrides any prompt file.
  --prompt-file F  Instructions from a launch-relative or absolute file.
  --workdir DIR    Override the agent workspace (or RUN_BUZZ_ACP_WORKDIR); env,
                   key, prompt and workspace paths resolve from the directory
                   where this script was invoked.
  -h, --help       Show this help without reading configuration.

Precedence: options > exported environment > env file > defaults. The inline
prompt and prompt file count as one setting, as do the agent key and key file.
The env file contains literal KEY=value lines (optional surrounding quotes).
No shell expansion, command execution, multiline values or end-of-line comments.
Use a prompt file for multiline instructions. Examples are embedded in this script.

Run and check refuse while Git could stage a file holding a secret (the env
file when it sets a key, or the key file): add an ignore rule (.gitignore or
.git/info/exclude) or keep the secret outside the repository. --init warns.

Run refuses a second copy of the same agent key on this machine, from any
directory (lock in $TMPDIR/buzz-acp-locks-<uid>, named by a hash of the key);
check reports a running copy. A lock left by an exited copy is reclaimed.
EOF
}

write_env_template() {
    cat <<'EOF'
# Buzz ACP settings for this project, generated by run-buzz-acp.sh --init.
# Edit this file, then run: run-buzz-acp.sh --check
# Keep it private (chmod 600) and out of Git; it may contain secret keys.
# Run/check refuse while Git could stage this file with a key in it.
# Literal KEY=value lines; no $VAR/~ expansion or comments after a value.
# Exported environment variables override this file; CLI options override both.

# COMMUNITY: the relay host selects the community, not the model provider.
# Local: ws://localhost:3000; hosted example: wss://community.example.org
BUZZ_RELAY_URL=ws://localhost:3000

# IDENTITY: your own PUBLIC key (64 hex characters) and the agent's SECRET key.
# Use different identities for yourself and the agent. Never put your own secret
# key here. Alternatively, leave BUZZ_PRIVATE_KEY blank and use ./identity.key.
BUZZ_ACP_AGENT_OWNER=
BUZZ_PRIVATE_KEY=
#RUN_BUZZ_ACP_KEY_FILE=./identity.key
# Optional owner attestation issued for this agent:
#BUZZ_AUTH_TAG=["auth","OWNER_PUBLIC_KEY","CONDITIONS","SIGNATURE"]

# RUNTIME / MODEL: Claude Code ACP adapter by default.
BUZZ_ACP_AGENT_COMMAND=claude-agent-acp
ANTHROPIC_BASE_URL=https://api.anthropic.com
# Set a model API key, or use the runtime's existing authentication.
#ANTHROPIC_API_KEY=YOUR_MODEL_API_KEY
# Empty = use the runtime's default model.
BUZZ_ACP_MODEL=

# WORKSPACE: unset = the directory where the script is run.
#RUN_BUZZ_ACP_WORKDIR=./path/to/workspace

# PROMPT: choose inline instructions OR a file (comment out the other).
BUZZ_ACP_SYSTEM_PROMPT=Work in the current directory. Read AGENTS.md before making changes. Report what you changed and tested.
#BUZZ_ACP_SYSTEM_PROMPT_FILE=./prompt.md
# Optional task to start immediately; otherwise wait for Buzz events.
#BUZZ_ACP_INITIAL_MESSAGE=Inspect this project and summarize its current state.

# BEHAVIOR: the agent must be admitted to the community and its channels.
BUZZ_ACP_RESPOND_TO=owner-only
# Harness default: tool commands run as your OS user without per-command prompts.
BUZZ_ACP_PERMISSION_MODE=bypass-permissions
#BUZZ_ACP_CHANNELS=CHANNEL_UUID_1,CHANNEL_UUID_2
#BUZZ_ACP_SESSION_POLICY=channel

# ALTERNATIVE: built-in Buzz Agent with an OpenAI-compatible provider.
# Install buzz-agent and buzz-dev-mcp first; replace the runtime line above.
#BUZZ_ACP_AGENT_COMMAND=buzz-agent
#BUZZ_ACP_MCP_COMMAND=buzz-dev-mcp
#BUZZ_AGENT_PROVIDER=openai
#OPENAI_COMPAT_BASE_URL=https://models.example.org/v1
#OPENAI_COMPAT_API_KEY=YOUR_MODEL_API_KEY
#OPENAI_COMPAT_MODEL=YOUR_MODEL_ID
# This runtime uses OPENAI_COMPAT_BASE_URL instead of --base-url.
EOF
}

init_env() {
    if [ -e "$ENV_FILE" ] || [ -L "$ENV_FILE" ]; then
        printf 'Already exists; kept unchanged: %s\n' "$ENV_FILE"
        warn_stageable
        return
    fi
    [ -d "$(dirname "$ENV_FILE")" ] || die 'env-file directory does not exist'
    ENV_TEMP=$(umask 077; mktemp "$ENV_FILE.tmp.XXXXXX") || die 'cannot create env-file template'
    trap 'rm -f -- "$ENV_TEMP"' EXIT
    if [ -n "$BACKEND" ]; then
        # A chosen backend means a subscription sign-in: no model key or endpoint lines.
        write_env_template | sed -e "s/^BUZZ_ACP_AGENT_COMMAND=claude-agent-acp$/BUZZ_ACP_AGENT_COMMAND=${INIT_COMMAND:-claude-agent-acp}/" \
            -e '/^ANTHROPIC_BASE_URL=/d' -e '/^#ANTHROPIC_API_KEY=/d' \
            -e "s/^# Set a model API key, or use the runtime's existing authentication.$/# Sign-in: your subscription only (BUZZ_SIGN_IN below); no API key or gateway./" > "$ENV_TEMP"
        printf '\nBUZZ_SIGN_IN=subscription\n' >> "$ENV_TEMP"
    else
        write_env_template > "$ENV_TEMP"
    fi
    # Publish atomically, without replacing a file created by another init.
    ln "$ENV_TEMP" "$ENV_FILE" 2>/dev/null || die 'env file appeared during init; it was not overwritten'
    rm -f -- "$ENV_TEMP"
    trap - EXIT
    printf 'Created: %s\nEdit it, then run this script with --check.\n' "$ENV_FILE"
    warn_stageable
}
warn_stageable() {
    stageable "$ENV_FILE" || return 0
    { printf 'run-buzz-acp.sh: warning: '; stage_advice "$ENV_FILE" 'the agent and model keys you put in it'; } >&2
}

# Read dotenv values as data, never as shell code. Preserve exported overrides.
load_env() {
    [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ] ||
        die "cannot read $ENV_FILE; run this script with --init first"
    local line key value keys=' ' number=0
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        case $line in '' | '#'* ) continue ;; esac
        case $line in 'export '*) line=${line#export }; line=${line#"${line%%[![:space:]]*}"} ;; esac
        case $line in *=*) ;; *) die "$ENV_FILE:$number: expected KEY=value" ;; esac
        key=${line%%=*}
        key=${key%"${key##*[![:space:]]}"}
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$ENV_FILE:$number: invalid variable name"
        case $key in
            BUZZ_* | ANTHROPIC_* | OPENAI_* | OPENROUTER_* | GOOSE_* | CODEX_* | DATABRICKS_* | RUN_BUZZ_ACP_KEY_FILE | RUN_BUZZ_ACP_WORKDIR | RUST_LOG) ;;
            *) die "$ENV_FILE:$number: unsupported setting $key" ;;
        esac
        case $keys in *" $key "*) die "$ENV_FILE:$number: duplicate setting $key" ;; esac
        keys="$keys$key "
        value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        case $value in
            \"*) [[ ${#value} -ge 2 && $value = *\" ]] || die "$ENV_FILE:$number: unclosed quote"
                value=${value#\"}; value=${value%\"} ;;
            \'*) [[ ${#value} -ge 2 && $value = *\' ]] || die "$ENV_FILE:$number: unclosed quote"
                value=${value#\'}; value=${value%\'} ;;
        esac
        # A file that sets a secret must not be stageable, even when this run overrides it.
        if [ -n "$value" ] && is_secret_name "$key"; then FILE_SECRETS="$FILE_SECRETS${FILE_SECRETS:+, }$key"; fi
        # Each pair is one setting: an option or exported value of either form replaces both lines.
        case $key in
            BUZZ_ACP_SYSTEM_PROMPT | BUZZ_ACP_SYSTEM_PROMPT_FILE) [ "$PROMPT_ABOVE_FILE" = no ] || continue ;;
            BUZZ_PRIVATE_KEY | RUN_BUZZ_ACP_KEY_FILE) [ "$KEY_ABOVE_FILE" = no ] || continue ;;
        esac
        if ! printenv "$key" >/dev/null 2>&1; then export "$key=$value"; FROM_FILE="$FROM_FILE$key "; fi
    done < "$ENV_FILE"
    FILE_KEYS=$keys
}
set_above_file() { # VAR...: yes when any is already in the environment (option or export)
    local name
    for name in "$@"; do
        if printenv "$name" >/dev/null 2>&1; then echo yes; return; fi
    done
    echo no
}
model_keys() { # names (never values) of exported provider secrets
    local name list=''
    for name in $(compgen -e); do
        case $name in BUZZ_PRIVATE_KEY | BUZZ_ACP_PRIVATE_KEY) continue ;; esac
        case $name in ANTHROPIC_* | OPENAI_* | OPENROUTER_* | GOOSE_* | CODEX_* | DATABRICKS_* | BUZZ_*) ;; *) continue ;; esac
        if is_secret_name "$name" && [ -n "${!name}" ]; then list="$list${list:+, }$name"; fi
    done
    if [ -n "$list" ]; then printf '%s (values hidden)\n' "$list"; else echo 'none set; the runtime uses its own sign-in'; fi
}
with_default() { # VALUE DEFAULT
    if [ "$1" = "$2" ]; then printf '%s (harness default)' "$1"; else printf '%s' "$1"; fi
}

# One live copy per agent key on this machine: a lock named by a hash of the key holds
# this script's PID, which exec hands to the harness. The key itself is never written.
nsec_hex() { # bech32 nsec -> 64 hex digits; the harness validates the key itself
    local data=${1#nsec1} cs=qpzry9x8gf2tvdw0s3jn54khce6mua7l hex=0123456789abcdef acc=0 bits=0 out='' i v
    data=${data%??????}
    for ((i = 0; i < ${#data}; i++)); do
        v=${cs%%"${data:i:1}"*}
        [ ${#v} -lt 32 ] || return 1
        acc=$(((acc << 5) | ${#v}))
        bits=$((bits + 5))
        while [ "$bits" -ge 4 ]; do
            bits=$((bits - 4))
            out=$out${hex:$(((acc >> bits) & 15)):1}
        done
        acc=$((acc & ((1 << bits) - 1)))
    done
    [ ${#out} -ge 64 ] || return 1
    printf '%s' "${out:0:64}"
}
agent_lock_name() {
    local key hex hasher
    key=$(printf '%s' "$BUZZ_PRIVATE_KEY" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case $key in nsec1*) if hex=$(nsec_hex "$key"); then key=$hex; fi ;; esac
    if command -v shasum >/dev/null 2>&1; then hasher='shasum -a 256'
    elif command -v sha256sum >/dev/null 2>&1; then hasher=sha256sum
    else die 'need shasum or sha256sum to name the agent lock'; fi
    printf 'agent-%s.lock' "$(printf 'buzz-acp-lock:%s' "$key" | $hasher | cut -c1-64)"
}
lock_holder_alive() { # PID: a live buzz-acp, or this launcher before its exec
    local name args
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    name=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    case ${name##*/} in buzz-acp) return 0 ;; esac
    args=$(ps -ww -o args= -p "$1" 2>/dev/null) || return 1
    case $args in *run-buzz-acp.sh*) return 0 ;; esac
    return 1
}
read_lock() {
    LOCK_PID='' LOCK_WS=''
    { IFS= read -r LOCK_PID && IFS= read -r LOCK_WS; } 2>/dev/null < "$LOCK_FILE" || true
}
running_message() {
    printf 'this agent is already running as PID %s (workspace %s). Stop it first: Ctrl-C in its terminal, kill -INT %s, or !shutdown from the owner' \
        "$LOCK_PID" "${LOCK_WS:-unknown}" "$LOCK_PID"
}
acquire_lock() { # atomic: ln never replaces; a stale lock is reclaimed under a guard
    local guard=$LOCK_FILE.reclaim attempt
    [ ! -L "$LOCK_DIR" ] || die "unsafe lock directory (a symlink): $LOCK_DIR"
    mkdir -m 700 -- "$LOCK_DIR" 2>/dev/null || [ -d "$LOCK_DIR" ] || die "cannot create lock directory $LOCK_DIR"
    [ -O "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "unsafe lock directory (not yours): $LOCK_DIR"
    LOCK_TMP=$(umask 077; mktemp "$LOCK_DIR/.new.XXXXXX") || die 'cannot create the agent lock'
    trap 'rm -f -- "$LOCK_TMP"' EXIT
    printf '%s\n%s\n' "$$" "$(pwd -P)" > "$LOCK_TMP"
    for attempt in 1 2; do
        if ln -- "$LOCK_TMP" "$LOCK_FILE" 2>/dev/null; then break; fi
        read_lock
        if lock_holder_alive "$LOCK_PID"; then die "$(running_message); nothing was started"; fi
        if ! mkdir -- "$guard" 2>/dev/null; then
            if [ -n "$(find "$guard" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir -- "$guard" 2>/dev/null || true; continue; fi
            die 'another launch of this agent is starting; nothing was started, try again in a moment'
        fi
        read_lock
        if lock_holder_alive "$LOCK_PID"; then rmdir -- "$guard"; die "$(running_message); nothing was started"; fi
        rm -f -- "$LOCK_FILE"
        if ln -- "$LOCK_TMP" "$LOCK_FILE" 2>/dev/null; then rmdir -- "$guard"; break; fi
        rmdir -- "$guard"
        [ "$attempt" = 1 ] || die 'could not take the agent lock; nothing was started, try again'
    done
    [ -f "$LOCK_FILE" ] && [ "$LOCK_FILE" -ef "$LOCK_TMP" ] || die 'could not take the agent lock; nothing was started, try again'
    rm -f -- "$LOCK_TMP"
    trap 'rm -f -- "$LOCK_FILE"' EXIT
}

# ---------------------------------------------------------------- subscription sign-in
# BUZZ_SIGN_IN=subscription: the agent may sign in only through the user's Claude or ChatGPT
# subscription. Every credential, endpoint and provider variable that Claude Code or Codex
# documents is removed from the agent's environment and refused in the env file.
credential_name() { # NAME: a credential, endpoint or provider selection of either runtime
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
# apiKeyHelper. Keep this list identical in agent-team.sh (its tests compare the two).
CLAUDE_SETTINGS_PATTERN='"(apiKeyHelper|ANTHROPIC_(API_KEY|AUTH_TOKEN|AWS_API_KEY|AWS_BASE_URL|AWS_WORKSPACE_ID|BASE_URL|BEDROCK_BASE_URL|BEDROCK_MANTLE_BASE_URL|CUSTOM_HEADERS|FEDERATION_RULE_ID|FOUNDRY_API_KEY|FOUNDRY_AUTH_TOKEN|FOUNDRY_BASE_URL|FOUNDRY_RESOURCE|GOOGLE_CLOUD_BASE_URL|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_WORKSPACE_ID|ORGANIZATION_ID|PROFILE|VERTEX_BASE_URL|VERTEX_PROJECT_ID|WORKSPACE_ID)|AWS_BEARER_TOKEN_BEDROCK|CLAUDE_CODE_(API_KEY_HELPER_TTL_MS|OAUTH_TOKEN|OAUTH_REFRESH_TOKEN|OAUTH_SCOPES|USE_(BEDROCK|VERTEX|FOUNDRY|MANTLE|ANTHROPIC_AWS|ANTHROPIC_GOOGLE_CLOUD)|SKIP_(BEDROCK|VERTEX|FOUNDRY|MANTLE|ANTHROPIC_AWS|ANTHROPIC_GOOGLE_CLOUD)_AUTH|ENABLE_GATEWAY_MODEL_DISCOVERY|GATEWAY_HINT_HEADERS|PROVIDER_MANAGED_BY_HOST))"[[:space:]]*:'
# Claude settings files that can set env or apiKeyHelper for a session in DIR (user, project, local, managed).
claude_settings_files() { # WORKDIR
    local cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude} managed=${BUZZ_CLAUDE_MANAGED_DIR:-/Library/Application Support/ClaudeCode} f
    for f in "$cfg/settings.json" "$cfg/settings.local.json" "$1/.claude/settings.json" "$1/.claude/settings.local.json" \
        "$managed/managed-settings.json" "$managed"/managed-settings.d/*.json; do
        if [ -f "$f" ]; then printf '%s\n' "$f"; fi
    done
    return 0
}
check_claude_settings() { # WORKDIR: stop on a credential or endpoint override in any settings file
    local f names files
    files=$(claude_settings_files "$1")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        names=$(grep -Eo "$CLAUDE_SETTINGS_PATTERN" "$f" 2>/dev/null | sed -E 's/^"([A-Za-z_]*)".*/\1/' | sort -u | tr '\n' ' ') || true
        [ -z "$names" ] || die "$f sets ${names% }; with subscription sign-in no API key, token, helper or endpoint may reach an agent. Remove those entries (names only are shown), then run this again"
    done <<< "$files"
}
# Codex configuration that would replace the ChatGPT sign-in or the OpenAI provider.
check_codex_config() {
    local f=${CODEX_HOME:-$HOME/.codex}/config.toml bad
    [ -f "$f" ] || return 0
    bad=$(awk '
        /^[[:space:]]*\[/ { exit }
        /^[[:space:]]*(model_provider|openai_base_url|chatgpt_base_url|profile|forced_login_method)[[:space:]]*=/ {
            line = $0; sub(/^[[:space:]]*/, "", line); key = line; sub(/[[:space:]]*=.*/, "", key)
            value = line; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/#.*/, "", value); gsub(/["\047[:space:]]/, "", value)
            if (key == "model_provider" && value == "openai") next
            if (key == "forced_login_method" && value == "chatgpt") next
            printf "%s ", key
        }' "$f")
    [ -z "$bad" ] || die "$f sets ${bad% } at the top level; with subscription sign-in the agent must use your ChatGPT sign-in and the OpenAI provider. Remove or change those keys (names only are shown)"
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
# Ask the CLI this agent will actually run how it is signed in. Sets SIGN_IN_NOTE or stops.
check_sign_in() { # BACKEND COMMAND
    local out status=0 method plan
    out=$(umask 077; mktemp "${TMPDIR:-/tmp}/run-buzz-acp-signin.XXXXXX") || die 'cannot create a temporary file for the sign-in check'
    if [ "$1" = claude ]; then
        bounded 30 "$out" "$2" --cli auth status || status=$?
        method=$(grep -Eo '"authMethod"[[:space:]]*:[[:space:]]*"[^"]*"' "$out" | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/') || true
        plan=$(grep -Eo '"subscriptionType"[[:space:]]*:[[:space:]]*"[^"]*"' "$out" | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/') || true
        rm -f -- "$out"
        [ "$status" != 124 ] || die 'the Claude sign-in check did not answer within 30 s; nothing was started'
        case $method in
            claude.ai) SIGN_IN_NOTE="Claude subscription${plan:+ ($plan)}" ;;
            '' | none) die 'this agent is not signed in to Claude. In your own terminal run: claude auth login (choose your Claude subscription), then check: claude auth status --text' ;;
            *) die "this agent's Claude sign-in is \"$method\", not your Claude subscription. Remove that credential, then in your own terminal run: claude auth login (choose your subscription)" ;;
        esac
    else
        case $2 in
            */runtime/codex-acp) bounded 30 "$out" "$2" --sign-in-status || status=$? ;;
            *) bounded 30 "$out" "$2" cli login status || status=$? ;;   # the Codex CLI the stock adapter runs
        esac
        if [ "$status" = 124 ]; then rm -f -- "$out"; die 'the Codex sign-in check did not answer within 30 s; nothing was started'; fi
        if ! grep -iq 'Logged in using ChatGPT' "$out"; then
            rm -f -- "$out"
            die 'this agent is not signed in to Codex with ChatGPT. In your own terminal run: codex login (choose Sign in with ChatGPT), then check: codex login status'
        fi
        rm -f -- "$out"
        SIGN_IN_NOTE='Codex with your ChatGPT sign-in'
    fi
}

LAUNCH_DIR=$(pwd -P)
ENV_FILE=$LAUNCH_DIR/.env.buzz-acp.local
FILE_SECRETS='' FROM_FILE=' ' FILE_KEYS=' ' KEY_FILE_USED=''
MODE=''
PROMPT_OPTION=''
BACKEND=''
INIT_COMMAND=''
BASE_URL_OPTION=no
RUNTIME_OPTIONS=no
MODEL_OPTION=no
select_mode() {
    [ -z "$MODE" ] || [ "$MODE" = "$1" ] || die 'choose only one of --init, --check and --run'
    MODE=$1
}

# Parse options first: exported option values win when the env file is loaded.
while [ "$#" -gt 0 ]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --init | init) select_mode init ;;
        --check) select_mode check ;;
        --run) select_mode run ;;
        --env-file)
            need_value "$@"; ENV_FILE=$2; shift ;;
        --backend)
            need_value "$@"; BACKEND=$2
            case $BACKEND in claude | codex) ;; *) die '--backend must be claude or codex' ;; esac
            shift ;;
        --community | --relay | --owner | --base-url | --model | --prompt | --prompt-file | --workdir)
            need_value "$@"
            RUNTIME_OPTIONS=yes
            case $1 in
                --community | --relay) export BUZZ_RELAY_URL=$2 ;;
                --owner) export BUZZ_ACP_AGENT_OWNER=$2 ;;
                --base-url) export ANTHROPIC_BASE_URL=$2; BASE_URL_OPTION=yes ;;
                --model) export BUZZ_ACP_MODEL=$2; MODEL_OPTION=yes ;;
                --prompt | --prompt-file)
                    [ -z "$PROMPT_OPTION" ] || [ "$PROMPT_OPTION" = "$1" ] || die 'choose --prompt or --prompt-file, not both'
                    PROMPT_OPTION=$1
                    if [ "$1" = --prompt ]; then
                        export BUZZ_ACP_SYSTEM_PROMPT=$2; unset BUZZ_ACP_SYSTEM_PROMPT_FILE
                    else
                        export BUZZ_ACP_SYSTEM_PROMPT_FILE=$2; unset BUZZ_ACP_SYSTEM_PROMPT
                    fi ;;
                --workdir) export RUN_BUZZ_ACP_WORKDIR=$2 ;;
            esac
            shift ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
case $ENV_FILE in /*) ;; *) ENV_FILE=$LAUNCH_DIR/$ENV_FILE ;; esac
MODE=${MODE:-run}
if [ "$MODE" = init ]; then
    [ "$RUNTIME_OPTIONS" = no ] || die '--init creates a template; edit the generated env file to set runtime options'
    if [ "$BACKEND" = codex ]; then INIT_COMMAND=codex-acp; fi
    init_env
    exit 0
fi
PROMPT_ABOVE_FILE=$(set_above_file BUZZ_ACP_SYSTEM_PROMPT BUZZ_ACP_SYSTEM_PROMPT_FILE)
KEY_ABOVE_FILE=$(set_above_file BUZZ_PRIVATE_KEY RUN_BUZZ_ACP_KEY_FILE)
load_env

# Defaults are applied after loading the project file. No global files are read.
export BUZZ_RELAY_URL="${BUZZ_RELAY_URL:-ws://localhost:3000}"
export BUZZ_ACP_AGENT_OWNER="${BUZZ_ACP_AGENT_OWNER:-}"
export BUZZ_ACP_AGENT_COMMAND="${BUZZ_ACP_AGENT_COMMAND:-claude-agent-acp}"
adapter_backend() { case ${1##*/} in claude-agent-acp | claude-code-acp) echo claude ;; codex-acp) echo codex ;; *) echo custom ;; esac; }
saved_backend=$(adapter_backend "$BUZZ_ACP_AGENT_COMMAND")
if [ "$MODE" = run ] && [ -t 0 ] && [ -z "$BACKEND" ] && [ "$saved_backend" != custom ]; then
    printf 'Backend [1 Claude, 2 Codex, Enter for %s]: ' "$saved_backend" >&2
    IFS= read -r choice || die 'backend selection cancelled'
    case $choice in '' ) ;; 1|[Cc]laude) BACKEND=claude ;; 2|[Cc]odex) BACKEND=codex ;; *) die 'choose Claude or Codex' ;; esac
fi
if [ -n "$BACKEND" ] && [ "$BACKEND" != "$saved_backend" ]; then
    case $BACKEND in claude) target=claude-agent-acp ;; codex) target=codex-acp ;; esac
    case $BUZZ_ACP_AGENT_COMMAND in
        */runtime/claude-agent-acp | */runtime/codex-acp)
            # A team's discussion partner switches to the other adapter of its own runtime folder.
            BUZZ_ACP_AGENT_COMMAND=${BUZZ_ACP_AGENT_COMMAND%/*}/$target
            [ -x "$BUZZ_ACP_AGENT_COMMAND" ] || die "this agent's runtime folder has no $target; refresh it with: agent-team.sh upgrade <team>" ;;
        claude-agent-acp | claude-code-acp | codex-acp) BUZZ_ACP_AGENT_COMMAND=$target ;;
        *) die 'this agent uses a custom adapter; choose its configured backend or configure a matching adapter' ;;
    esac
    # A single model or adapter arguments saved for the other backend do not carry over.
    if [ "$MODEL_OPTION" = no ]; then case $FROM_FILE in *' BUZZ_ACP_MODEL '*) unset BUZZ_ACP_MODEL ;; esac; fi
    case $FROM_FILE in *' BUZZ_ACP_AGENT_ARGS '*) unset BUZZ_ACP_AGENT_ARGS ;; esac
fi
backend=$(adapter_backend "$BUZZ_ACP_AGENT_COMMAND")
# Sign-in mode. BUZZ_CODEX_AUTH=chatgpt and --backend codex (the 20 Nov forms) also mean subscription for Codex.
SIGN_IN=${BUZZ_SIGN_IN:-}
case $SIGN_IN in '' | subscription) ;; *) die "BUZZ_SIGN_IN must be subscription or unset (got: $SIGN_IN)" ;; esac
if [ "$backend" = codex ] && { [ "$BACKEND" = codex ] || [ "${BUZZ_CODEX_AUTH:-}" = chatgpt ]; }; then SIGN_IN=subscription; fi
REMOVED_NAMES='' SIGN_IN_NOTE=''
if [ "$SIGN_IN" = subscription ]; then
    [ "$backend" != custom ] || die 'subscription sign-in needs claude-agent-acp or codex-acp as the agent runtime'
    [ "$BASE_URL_OPTION" = no ] || die '--base-url is not used with subscription sign-in; the agent reaches its provider only through your subscription'
    for key in $FILE_KEYS; do
        if credential_name "$key"; then
            die "$ENV_FILE sets $key; this agent signs in by subscription only. Remove that line (agent-team.sh upgrade rewrites team env files)"
        fi
    done
    # Remove every credential, endpoint and provider variable this shell exported (names only are reported).
    for key in $(compgen -e); do
        if credential_name "$key"; then unset "$key"; REMOVED_NAMES="$REMOVED_NAMES${REMOVED_NAMES:+ }$key"; fi
    done
    if [ "$backend" = claude ] && [ -n "${CLAUDE_CODE_EXECUTABLE+x}" ]; then
        # The adapter's own CLI both answers the sign-in check and runs the session.
        unset CLAUDE_CODE_EXECUTABLE
        REMOVED_NAMES="$REMOVED_NAMES${REMOVED_NAMES:+ }CLAUDE_CODE_EXECUTABLE"
    fi
fi
if [ "$backend" = codex ]; then
    export BUZZ_ACP_AGENT_ARGS="${BUZZ_ACP_AGENT_ARGS:-}"
    if [ "$SIGN_IN" = subscription ]; then
        export MODEL_PROVIDER=openai
        if [ "$BUZZ_ACP_AGENT_COMMAND" = codex-acp ]; then
            case $(codex-acp --version 2>/dev/null) in *' 1.13.1') ;; *) die 'this Buzz harness needs @agentclientprotocol/codex-acp@1.13.1' ;; esac
        fi
    fi
fi
# The model: --model, else the selected backend's saved model (BUZZ_MODEL_CLAUDE / BUZZ_MODEL_CODEX),
# else BUZZ_ACP_MODEL. Empty means the runtime default.
if [ "$MODEL_OPTION" = no ] && { [ -n "${BUZZ_MODEL_CLAUDE+x}" ] || [ -n "${BUZZ_MODEL_CODEX+x}" ]; }; then
    case $backend in claude) BUZZ_ACP_MODEL=${BUZZ_MODEL_CLAUDE:-} ;; codex) BUZZ_ACP_MODEL=${BUZZ_MODEL_CODEX:-} ;; esac
fi
CLAUDE_MODEL_ENV=no
if [ "$backend" = claude ] && [ "$SIGN_IN" = subscription ] && [ -n "${BUZZ_ACP_MODEL:-}" ]; then
    # Claude Code documents its aliases and full model names (model-config); refuse anything else.
    case $BUZZ_ACP_MODEL in
        default | best | fable | sonnet | opus | haiku | 'sonnet[1m]' | 'opus[1m]' | opusplan) ;;
        *) [[ $BUZZ_ACP_MODEL =~ ^claude-(opus|sonnet|haiku|fable)-[0-9]+(-[0-9]+)*(\[1m\])?$ ]] ||
            die "$BUZZ_ACP_MODEL is not a Claude model: use an alias (opus, sonnet, haiku, fable, default) or a full name such as claude-opus-5-5" ;;
    esac
    # The harness applies only a value the adapter lists exactly (buzz-acp acp.rs resolve_model_switch_method)
    # and otherwise runs the default; the adapter resolves ANTHROPIC_MODEL against its own list first,
    # above the user's settings "model" (claude-agent-acp session-model.js). So Claude gets it that way.
    export ANTHROPIC_MODEL=$BUZZ_ACP_MODEL
    CLAUDE_MODEL_ENV=yes
    BUZZ_ACP_MODEL=''
fi
export PROJECT_BUZZ_AGENT_DIR
PROJECT_BUZZ_AGENT_DIR=$(cd -- "$(dirname -- "$ENV_FILE")" && pwd -P)
if [ "$SIGN_IN" != subscription ]; then export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"; fi
export BUZZ_ACP_RESPOND_TO="${BUZZ_ACP_RESPOND_TO:-owner-only}"
export BUZZ_ACP_PERMISSION_MODE="${BUZZ_ACP_PERMISSION_MODE:-bypass-permissions}"
case $BUZZ_ACP_PERMISSION_MODE:$backend in
    dont-ask:claude | dontAsk:claude | dont-ask:codex | dontAsk:codex)
        die 'BUZZ_ACP_PERMISSION_MODE=dont-ask: this adapter offers no dontAsk mode, so the harness would skip it without a message. Use default (a team partner'"'"'s runtime holds its own read-only mode) or another mode the adapter offers' ;;
esac
BUZZ_PRIVATE_KEY=${BUZZ_PRIVATE_KEY:-}
RUN_BUZZ_ACP_KEY_FILE=${RUN_BUZZ_ACP_KEY_FILE:-$LAUNCH_DIR/identity.key}
WORKDIR=${RUN_BUZZ_ACP_WORKDIR:-$LAUNCH_DIR}
BUZZ_ACP_MODEL=${BUZZ_ACP_MODEL:-}
BUZZ_ACP_SYSTEM_PROMPT=${BUZZ_ACP_SYSTEM_PROMPT:-}
BUZZ_ACP_SYSTEM_PROMPT_FILE=${BUZZ_ACP_SYSTEM_PROMPT_FILE:-}

for executable in buzz buzz-acp "$BUZZ_ACP_AGENT_COMMAND"; do
    command -v "$executable" >/dev/null 2>&1 || die "missing executable: $executable; add its directory to PATH"
done
if [ -n "${BUZZ_ACP_MCP_COMMAND:-}" ]; then
    command -v "$BUZZ_ACP_MCP_COMMAND" >/dev/null 2>&1 || die "missing MCP executable: $BUZZ_ACP_MCP_COMMAND"
fi
case $BUZZ_RELAY_URL in ws://?* | wss://?*) ;; *) die 'community URL must start with ws:// or wss://' ;; esac
[[ $BUZZ_ACP_AGENT_OWNER =~ ^[[:xdigit:]]{64}$ ]] || die 'set BUZZ_ACP_AGENT_OWNER or --owner to your own 64-character hex public key'
if [ -z "$BUZZ_PRIVATE_KEY" ]; then
    case $RUN_BUZZ_ACP_KEY_FILE in /*) ;; *) RUN_BUZZ_ACP_KEY_FILE=$LAUNCH_DIR/$RUN_BUZZ_ACP_KEY_FILE ;; esac
    [ -f "$RUN_BUZZ_ACP_KEY_FILE" ] && [ -r "$RUN_BUZZ_ACP_KEY_FILE" ] || die 'set BUZZ_PRIVATE_KEY or RUN_BUZZ_ACP_KEY_FILE in the project env file'
    IFS= read -r BUZZ_PRIVATE_KEY < "$RUN_BUZZ_ACP_KEY_FILE" || [ -n "$BUZZ_PRIVATE_KEY" ] || die 'the agent key file is empty'
    BUZZ_PRIVATE_KEY=${BUZZ_PRIVATE_KEY%$'\r'}
    KEY_FILE_USED=$RUN_BUZZ_ACP_KEY_FILE
    KEY_SOURCE="key file $RUN_BUZZ_ACP_KEY_FILE"
else
    case $FROM_FILE in
        *" BUZZ_PRIVATE_KEY "*) KEY_SOURCE='BUZZ_PRIVATE_KEY in the env file' ;;
        *) KEY_SOURCE='BUZZ_PRIVATE_KEY exported in the environment, overriding the env file' ;;
    esac
fi
[ -n "$BUZZ_PRIVATE_KEY" ] || die 'the agent secret key is empty'
export BUZZ_PRIVATE_KEY
[ -z "$FILE_SECRETS" ] || refuse_stageable "$ENV_FILE" "$FILE_SECRETS"
[ -z "$KEY_FILE_USED" ] || refuse_stageable "$KEY_FILE_USED" 'the agent secret key'

if [ "$BASE_URL_OPTION" = yes ]; then
    case ${BUZZ_ACP_AGENT_COMMAND##*/} in
        claude-agent-acp | claude-code-acp) ;;
        *) die '--base-url configures Claude Code; set your runtime provider URL in the env file instead' ;;
    esac
fi
[ -z "$BUZZ_ACP_SYSTEM_PROMPT" ] || [ -z "$BUZZ_ACP_SYSTEM_PROMPT_FILE" ] || die 'set only one of BUZZ_ACP_SYSTEM_PROMPT and BUZZ_ACP_SYSTEM_PROMPT_FILE'
if [ -n "$BUZZ_ACP_SYSTEM_PROMPT_FILE" ]; then
    case $BUZZ_ACP_SYSTEM_PROMPT_FILE in /*) ;; *) BUZZ_ACP_SYSTEM_PROMPT_FILE=$LAUNCH_DIR/$BUZZ_ACP_SYSTEM_PROMPT_FILE ;; esac
    [ -f "$BUZZ_ACP_SYSTEM_PROMPT_FILE" ] && [ -r "$BUZZ_ACP_SYSTEM_PROMPT_FILE" ] || die "cannot read prompt file: $BUZZ_ACP_SYSTEM_PROMPT_FILE"
    export BUZZ_ACP_SYSTEM_PROMPT_FILE
    unset BUZZ_ACP_SYSTEM_PROMPT
else
    export BUZZ_ACP_SYSTEM_PROMPT="${BUZZ_ACP_SYSTEM_PROMPT:-Work in the current directory. Read AGENTS.md before making changes. Report what you changed and tested.}"
    unset BUZZ_ACP_SYSTEM_PROMPT_FILE
fi
if [ -n "$BUZZ_ACP_MODEL" ]; then export BUZZ_ACP_MODEL; else unset BUZZ_ACP_MODEL; fi

cd -- "$WORKDIR" || die "cannot enter workspace: $WORKDIR"
if [ "$SIGN_IN" = subscription ]; then
    # Settings files can re-add what the environment no longer has, so they are checked too.
    if [ "$backend" = claude ]; then check_claude_settings "$(pwd -P)"; else check_codex_config; fi
    check_sign_in "$backend" "$BUZZ_ACP_AGENT_COMMAND"
fi
LOCK_DIR=${TMPDIR:-/tmp}
LOCK_DIR=${LOCK_DIR%/}/buzz-acp-locks-$(id -u)
LOCK_FILE=$LOCK_DIR/$(agent_lock_name)
# Run refuses a second copy of this agent before printing or starting anything.
[ "$MODE" = check ] || acquire_lock
if [ -n "${BUZZ_ACP_SYSTEM_PROMPT_FILE:-}" ]; then
    PROMPT_SOURCE="file $BUZZ_ACP_SYSTEM_PROMPT_FILE"
else
    PROMPT_SOURCE="inline, ${#BUZZ_ACP_SYSTEM_PROMPT} characters"
fi
PERMISSION_NOTE=''
[ "$BUZZ_ACP_PERMISSION_MODE" != bypass-permissions ] || PERMISSION_NOTE='; tools run without per-command prompts'
printf 'Env file:     %s\n' "$ENV_FILE"
printf 'Workspace:    %s\n' "$(pwd -P)"
printf 'Community:    %s\n' "$BUZZ_RELAY_URL"
printf 'Owner:        %s\n' "$BUZZ_ACP_AGENT_OWNER"
printf 'Agent key:    %s (value hidden)\n' "$KEY_SOURCE"
printf 'Model keys:   %s\n' "$(model_keys)"
printf 'Auth tag:     %s\n' "$(if [ -n "${BUZZ_AUTH_TAG:-}" ]; then echo 'BUZZ_AUTH_TAG set'; else echo 'not set'; fi)"
printf 'Access:       BUZZ_ACP_RESPOND_TO=%s\n' "$(with_default "$BUZZ_ACP_RESPOND_TO" owner-only)"
printf 'Permissions:  BUZZ_ACP_PERMISSION_MODE=%s%s\n' "$(with_default "$BUZZ_ACP_PERMISSION_MODE" bypass-permissions)" "$PERMISSION_NOTE"
if [ "$CLAUDE_MODEL_ENV" = yes ]; then printf 'Model:        %s (ANTHROPIC_MODEL; wins over a settings "model")\n' "$ANTHROPIC_MODEL"
else printf 'Model:        %s\n' "${BUZZ_ACP_MODEL:-runtime default}"; fi
if [ "$SIGN_IN" = subscription ]; then
    printf 'Sign-in:      %s; no API key, token or endpoint\n' "$SIGN_IN_NOTE"
    printf 'Removed:      %s\n' "${REMOVED_NAMES:-none}"
elif [ "$backend" = codex ]; then
    printf 'Backend:      Codex (configured credentials)\n'
else
    printf 'Base URL:     %s (Claude Code runtimes)\n' "$ANTHROPIC_BASE_URL"
fi
printf 'Prompt:       %s\n' "$PROMPT_SOURCE"
printf 'Harness:      %s\nBuzz CLI:     %s\nRuntime:      %s\n' \
    "$(command -v buzz-acp)" "$(command -v buzz)" "$(command -v "$BUZZ_ACP_AGENT_COMMAND")"
printf 'Agent lock:   %s\n' "$LOCK_FILE"
if [ "$MODE" = check ]; then
    LOCK_PID=''
    if [ -f "$LOCK_FILE" ]; then read_lock; fi
    if lock_holder_alive "$LOCK_PID"; then die "$(running_message); a run would be refused"; fi
    printf 'Running copy: none\nRequired settings and executables found. Keys hidden; no agent started.\n'
    exit 0
fi
trap - EXIT
exec buzz-acp
