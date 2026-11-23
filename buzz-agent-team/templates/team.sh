#!/usr/bin/env bash
# team.sh: check, start and stop the Buzz agents of this team folder. Bash 3.2+.
#
# This file lives in the team folder, beside team.conf and one folder per agent:
#   <team>/team.sh   team.conf   <team>/   supervisor/      (or, for a reviewer's own team: reviewer/)
# The workspace agent's folder is named after the team; team.conf records it (agent_folder=).
# It finds everything from its own location and passes those paths to the launcher at every start,
# so the folder can be copied or moved as a whole. Nothing here names the skill that created it:
# the buzz-agent-team skill is needed to create or upgrade a team, not to run one.
#
# NEEDED ON PATH: run-buzz-acp.sh (the launcher), buzz-acp, buzz, and for each agent the adapter of
# the provider it runs on (claude-agent-acp or codex-acp), signed in through your own subscription.
# "team.sh check" verifies all of it and starts nothing; start runs the same check first.
# python3 is used to retrieve a provider's model list for the model menu (acp-models.py here) and to
# put the sandbox settings of the workspace agent on Claude into the project folder (workspace-settings.py
# here).
#
# THE TWO JOBS of a team (their roles are agent and supervisor; since format 4):
#   agent        the workspace agent, in the folder named after the team: the stock adapter with all
#                its tools and worker subagents. It
#                answers the owner and its channel supervisor, and starts work only on the owner's
#                own acceptance.
#   supervisor   the channel supervisor: the restricted runtime. It takes a turn on every ordinary
#                message in its channel, talks with anyone there, and hands accepted work to the
#                workspace agent.
# A reviewer's own team has one agent, reviewer, on the restricted runtime. This command derives how
# each agent is held, and whom it answers, from that agent's settings file.
#
# THE PROJECT FOLDER the agents work in is the folder this command is started from, or --workspace DIR:
#   cd ~/code/shop && ~/.buzz-agents/shop/team.sh
# It can never be the team folder or a folder around it, because the secret keys are here. Started
# from the team folder itself, the command uses the project folder saved in team.conf.
#
#   team.sh                   start: asks which agents, then the provider, model and effort of each
#   team.sh check             check the environment and every agent's settings
#   team.sh status            what runs, where, on which provider and model
#   team.sh stop              stop the agents this command started
#   team.sh version           the version of the skill that wrote this folder's files (VERSION here)
#   team.sh help              every command and option
#
# Each agent folder also holds start.sh, which starts that one agent through this command:
#   cd ~/code/shop && ~/.buzz-agents/shop/shop/start.sh

set -uo pipefail
umask 077

PROG=team.sh
ENV_NAME=.env.buzz-acp.local
ALL_ROLES='agent supervisor reviewer'

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage: team.sh [start] [AGENT...] [options]   start agents of this team folder
       team.sh check [AGENT...] [options]     check the environment and settings; starts nothing
       team.sh status                         agents, saved choices and running state
       team.sh stop [AGENT...] [--force]      stop agents this command started
       team.sh workspace DIR                  save DIR as the team's project folder in team.conf
       team.sh version                        the version of the skill that wrote this folder's files

AGENT is an agent's folder name: the workspace agent's (named after the team; agent works too),
supervisor or reviewer, whichever this team has. Without one, start asks in a terminal; elsewhere
it means all.

The project folder the agents work in, for start and check:
  --workspace DIR           this folder
  (without it)              the folder you run this command from
  (run from the team folder, or from a folder around it)
                            the folder saved in team.conf, because the secret keys are here
A folder that is inside the team folder, contains it, or is another agent or team folder is refused.
A team works in one project folder at a time: while one agent runs, another starts only there.

start and check:
  --all                     every agent of the team, without the question
  --backend claude|codex    provider for every selected agent, for this run
  --model ID                model for every selected agent, for this run
  --agent-backend B, --supervisor-backend B, --reviewer-backend B
  --agent-model ID, --supervisor-model ID, --reviewer-model ID
                            the same for one agent; these win over --backend and --model
  --effort LEVEL            reasoning effort for every selected agent, for this run
  --agent-effort LEVEL, --supervisor-effort LEVEL, --reviewer-effort LEVEL
                            the same for one agent. On Claude: low, medium, high, xhigh or max.
                            On Codex: a level the model list offers for that model (low to
                            ultra). default sets none for this run, whatever is saved.
  --yes                     ask nothing: every agent keeps its saved provider and model
  --no-wall                 do not put the sandbox settings into the project folder at this
                            start, and start the workspace agent on Claude in a folder that has
                            none. Only the rule in its prompt then holds it. Settings that are
                            already in the folder stay there and apply.
  --verbose                 also print the launcher's own check of each agent
  --check                   with start: the same as "team.sh check"

In a terminal, start asks which agents, then for each one its provider (Claude or Codex), its
model and its reasoning effort. Enter keeps the saved choice. A choice lasts for that run; the
saved choice is changed with the skill (agent-team.sh upgrade).

The model menu shows what the provider offers now. Before the menu of an agent, its provider's
adapter is asked for its model list: one session, no model turn, your subscription sign-in, at
most 30 seconds, one attempt. The list is kept in models/ (in this folder, or in the folder above
it when that one has models/) and replaces the earlier one. When it cannot be retrieved, the reason
is shown and the kept list is offered, with its date. A model given by option that the kept list
does not offer is looked up the same way before it is refused. A start that asks nothing (--yes, or
no terminal) with no model option retrieves nothing. A Claude agent
is never started with the model "default": Claude Code takes it as a model name and refuses every
turn, so the menu leaves it out and it is refused as a choice and as a saved model.

One agent at a time: each agent folder holds its own start command.
  <this folder>/<agent>/start.sh      starts that agent only. In a terminal it asks that agent's
                                      provider, model and reasoning effort, as this command does;
                                      --yes asks nothing (start.sh --help)

The jobs: the agent is the workspace agent, with all the tools of its adapter and worker
subagents; it answers the owner and its channel supervisor. The supervisor is the channel supervisor:
it takes a turn on every ordinary message in its channel and hands accepted work to the workspace
agent. check and status say whom each agent answers.

What holds each agent to the project folder:
  - The channel supervisor and the reviewer run a restricted runtime: they read only the project
    folder, and they cannot edit files or run commands at all.
  - The workspace agent on Claude is held by plain Claude Code settings in the project folder,
    .claude/settings.json, which Claude Code reads itself. Before a start this command puts them
    there with workspace-settings.py from this folder, and an existing file keeps everything else
    it holds. With them its file tools read and write only inside the project folder, and its
    shell commands run in a sandbox: they write only inside the project folder and a temporary
    folder, and they read no user folder outside the project folder. A plain buzz command runs
    outside the sandbox, which has no direct network. Every Claude Code session started in that
    folder, your own included, runs under the same settings.
  - The workspace agent on Codex runs its commands in Codex's workspace-write sandbox, which the stock
    adapter sets on every turn: they write only inside the project folder and temporary folders,
    and they have no network. They can read the whole disk. No file is written for it.
  - The rule in the workspace agent's prompt asks for what no setting holds: a command it runs again
    outside the sandbox, a buzz command given a file outside the project folder, and on Codex
    what it reads. Folders your own Claude settings add as working folders count as inside.

Reasoning effort: how hard the model thinks on each turn; higher levels cost more of your
allowance and take longer. A Claude agent gets its level as CLAUDE_CODE_EFFORT_LEVEL, which wins
over your own Claude Code setting. A Codex agent gets it in the model name, model[level]. With
none set here, Claude Code uses your own saved level for that model, or the model's default, and
Codex uses the default of your Codex configuration.

Before anything starts, the check must pass:
  - run-buzz-acp.sh, buzz-acp and buzz are on PATH, and so is each agent's adapter
  - the project folder exists and is not around the secret keys
  - every agent has its key, settings file, prompt and stored ownership proof
  - the launcher accepts each agent's settings, and its provider is signed in by subscription

The version: VERSION in this folder is the version of the buzz-agent-team skill that created the
folder or last upgraded it (agent-team.sh upgrade), and so the version this command, each
start.sh, acp-models.py and workspace-settings.py come from. "team.sh version" prints it; status
shows it too. A folder made before the skill had versions has none until it is upgraded. An agent
whose record is in an earlier format than 3 (made by version 2.0.0 or earlier of the skill, when
the two jobs were assigned the other way round) does not start until the skill upgrades it.

Moving the team: stop the agents, copy this whole folder (it holds the secret keys, so copy it
privately), install the commands above on the new machine, sign in there, then go to the project
folder and run "<team folder>/team.sh check".

Environment:
  AGENT_TEAM_LAUNCHER       the launcher, when run-buzz-acp.sh is not on PATH
  AGENT_TEAM_START_WAIT     seconds start watches for an early exit (default 3)
  AGENT_TEAM_STOP_GRACE     seconds stop waits after SIGTERM (default 30)
  AGENT_TEAM_LOG_MAX_BYTES  a log above this is moved to agent.log.1 at start (10 MiB)
  AGENT_TEAM_MODELS_TIMEOUT seconds a model list may take to arrive (default and most: 30)
  AGENT_TEAM_PYTHON         the python3 that retrieves a model list (none: never retrieve one)
  CLAUDE_AGENT_ACP_PROTOCOL passed to started agents (default v1)
EOF
}

# ---------------------------------------------------------------- cleanup and lock
LOCK_DIR='' LIST_TMP=''
cleanup() {
    if [ -n "$LOCK_DIR" ]; then rm -rf -- "$LOCK_DIR"; LOCK_DIR=''; fi
    if [ -n "$LIST_TMP" ]; then rm -f -- "$LIST_TMP" "$LIST_TMP.err"; LIST_TMP=''; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# One writer per team folder, shared with agent-team.sh. A lock left by a killed run is reclaimed.
take_lock() {
    local lock=$T_DIR/.lock pid=''
    if ! mkdir -m 700 -- "$lock" 2>/dev/null; then
        IFS= read -r pid < "$lock/pid" 2>/dev/null || true
        case $pid in '' | *[!0-9]*) die "$T_DIR is locked by another run. If none is running, remove $lock and retry." ;; esac
        if kill -0 "$pid" 2>/dev/null; then die "another run (PID $pid) is changing $T_DIR; try again when it ends"; fi
        rm -rf -- "$lock"
        mkdir -m 700 -- "$lock" 2>/dev/null || die "cannot lock $T_DIR; try again"
    fi
    LOCK_DIR=$lock
    printf '%s\n' "$$" > "$lock/pid"
}

# ---------------------------------------------------------------- small helpers
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
check_backend() { case $1 in claude | codex) ;; *) die "choose claude or codex (got: $1)" ;; esac; }
backend_command() { if [ "$1" = codex ]; then printf 'codex-acp'; else printf 'claude-agent-acp'; fi; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '?'; }

# KEY=value data files written by the skill (team.conf, agent.conf): first match wins.
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
    [ -f "$1" ] || return 1
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

# ---------------------------------------------------------------- the team folder
T_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd) || die 'cannot find the folder this script is in'
# The folder this command was started from: the agents' project folder unless --workspace names one.
CALL_DIR=$(pwd -P 2>/dev/null) || CALL_DIR=''

# The version of the skill that created or last upgraded this folder: the one line of VERSION here,
# MAJOR.MINOR.PATCH. It fails for a folder made before the skill had versions.
team_version() {
    local v='' re='^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$'
    [ -f "$T_DIR/VERSION" ] || return 1
    IFS= read -r v < "$T_DIR/VERSION" || [ -n "$v" ] || return 1
    [[ $v =~ $re ]] || return 1
    printf '%s' "$v"
}
version_line() {
    local v
    if v=$(team_version); then printf 'written by buzz-agent-team %s' "$v"
    else printf 'have no skill version recorded (written before 1.0.0); agent-team.sh upgrade <team> records it'; fi
}
load_team() {
    [ -f "$T_DIR/team.conf" ] || die "$T_DIR has no team.conf; team.sh must stay in its team folder"
    T_NAME=$(conf_get "$T_DIR/team.conf" name) || T_NAME=$(basename -- "$T_DIR")
    T_WORKSPACE=$(conf_get "$T_DIR/team.conf" workspace) || die "$T_DIR/team.conf has no workspace"
    T_CHANNEL=$(conf_get "$T_DIR/team.conf" channel) || T_CHANNEL='(not recorded)'
    T_COMMUNITY=$(conf_get "$T_DIR/team.conf" community) || T_COMMUNITY='(not recorded)'
}

lower() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }
# The folder of each agent. The supervisor's and the reviewer's are named after their role. The
# workspace agent's is named after the team, as team.conf records it (agent_folder=), or "agent" when
# the team's name is one a team folder uses for something else. A folder in the layout before format 4
# (assistant/) is found too, so that this command can say it needs upgrading.
RESERVED_NAMES='supervisor reviewer models wall team.sh team.conf acp-models.py workspace-settings.py version brief.md'
agent_folder_for() { # TEAM_NAME
    local n
    n=$(lower "$1")
    case $n in '' | .* | *.bak-* | */*) printf 'agent'; return 0 ;; esac
    case " $RESERVED_NAMES " in *" $n "*) printf 'agent'; return 0 ;; esac
    printf '%s' "$1"
}
agent_dir() { # the workspace agent's folder name, from team.conf
    local v name
    v=$(conf_get "$T_DIR/team.conf" agent_folder 2>/dev/null) || v=''
    if [ -n "$v" ] && [ "$v" != agent ] && [ "$(agent_folder_for "$v")" != "$v" ]; then v=''; fi
    if [ -z "$v" ]; then
        name=$(conf_get "$T_DIR/team.conf" name 2>/dev/null) || name=$(basename -- "$T_DIR")
        v=$(agent_folder_for "$name")
    fi
    if [ ! -d "$T_DIR/$v" ] && [ -d "$T_DIR/assistant" ]; then v=assistant; fi
    printf '%s' "$v"
}
AGENT_DIR=agent   # set from team.conf before any command runs
adir() { if [ "$1" = agent ]; then printf '%s' "$AGENT_DIR"; else printf '%s' "$1"; fi; } # ROLE: its folder, the name to type
ahome() { printf '%s/%s' "$T_DIR" "$(adir "$1")"; } # ROLE
# The role a name on the command line means: an agent's folder name, or agent for the workspace agent.
role_of() { # NAME
    case " $ALL_ROLES " in *" $1 "*) printf '%s' "$1"; return 0 ;; esac
    if [ "$1" = "$AGENT_DIR" ]; then printf 'agent'; return 0; fi
    return 1
}
handles() { local id out=''; for id in $(team_agents); do out="$out${out:+, }$(adir "$id")"; done; printf '%s' "$out"; }
unknown_agent() { # NAME
    if [ "$1" = assistant ]; then printf 'unknown agent: assistant. Since 4.0.0 the workspace agent is named after its folder, %s, or agent' "$AGENT_DIR"
    else printf 'unknown agent: %s (agents here: %s; the workspace agent is also agent)' "$1" "$(handles)"; fi
}
team_agents() { # the roles present here, in role order
    local id
    for id in $ALL_ROLES; do
        if [ -f "$(ahome "$id")/agent.conf" ]; then printf '%s\n' "$id"; fi
    done
}
afield() { conf_get "$(ahome "$1")/agent.conf" "$2" 2>/dev/null || true; } # ROLE KEY
label() { local n; n=$(afield "$1" name); printf '%s' "${n:-$(adir "$1")}"; } # ROLE: its display name
job_words() { case $1 in agent) printf 'the workspace agent' ;; supervisor) printf 'the channel supervisor' ;; *) printf 'the independent reviewer' ;; esac; }
# The record format this command starts. An earlier one is from an earlier version of the skill:
# format 3 kept the workspace agent in assistant/, format 2 assigned the two jobs the other way round,
# format 1 is from before 20 November. The skill upgrades it.
FORMAT=4
agent_format() { conf_get "$(ahome "$1")/agent.conf" format 2>/dev/null || printf '1'; }
# An agent of this team folder, or of a team folder beside it, by public key; else the key itself.
key_label() { # HEX
    local f k n
    for f in "$T_DIR"/*/agent.conf "$T_DIR"/../*/*/agent.conf; do
        [ -f "$f" ] || continue
        k=$(conf_get "$f" pubkey) || continue
        [ "$(lower "$k")" = "$(lower "$1")" ] || continue
        n=$(conf_get "$f" name) || n=''
        f=${f%/agent.conf}
        printf '%s of %s' "${n:-$1}" "$(basename -- "${f%/*}")"
        return 0
    done
    printf 'an agent that is not beside this team folder (public key %s)' "$1"
}
# Whom an agent answers, as its settings file says (public keys only; the harness always adds the
# owner). Returns 1 for allowlist mode with no public key, which the harness refuses to start.
answers() { # ID
    local env mode keys k names=''
    env=$(ahome "$1")/$ENV_NAME
    mode=$(env_get "$env" BUZZ_ACP_RESPOND_TO) || mode=owner-only
    case $mode in
        anyone)
            if [ "$(env_get "$env" BUZZ_ACP_SUBSCRIBE || true)" = config ]; then
                printf 'anyone in its channel (its subscription rules decide which messages start a turn)'
            else printf 'anyone who mentions it'; fi ;;
        allowlist)
            keys=$(env_get "$env" BUZZ_ACP_RESPOND_TO_ALLOWLIST) || keys=''
            for k in ${keys//,/ }; do names="$names${names:+, }$(key_label "$k")"; done
            [ -n "$names" ] || { printf 'nobody: allowlist mode with no public key'; return 1; }
            printf 'the owner and %s' "$names" ;;
        *) printf 'the owner only' ;;
    esac
}
# The saved provider of an agent: agent.conf's backend=, else the adapter its settings file names.
saved_backend() {
    local b
    b=$(afield "$1" backend)
    if [ -z "$b" ]; then
        b=$(env_get "$(ahome "$1")/$ENV_NAME" BUZZ_ACP_AGENT_COMMAND) || b=''
        case ${b##*/} in codex-acp) b=codex ;; *) b=claude ;; esac
    fi
    printf '%s' "$b"
}
saved_model() { afield "$1" "model_$2"; } # ID BACKEND
upgrade_interrupted() {
    local p id
    for id in $ALL_ROLES assistant; do
        for p in "$T_DIR/.$id.upgrade."* "$T_DIR/.$id.prev."*; do
            if [ -e "$p" ]; then return 0; fi
        done
    done
    return 1
}

# ---------------------------------------------------------------- the project folder
# The folder the agents work in: --workspace DIR, else the folder this command was started from.
# The team folder holds the secret keys, and an agent reads its project folder, so the two must be
# apart: a folder inside the team folder, around it, or itself an agent or team folder is never used.
OPT_WORKSPACE='' RUN_WORKSPACE='' WORKSPACE_SOURCE=''
within() { case $1 in "$2" | "$2"/*) return 0 ;; esac; return 1; } # PATH is DIR or inside it
unsafe_workspace() { # DIR: prints why DIR cannot be the project folder; returns 1 when it can
    if within "$1" "$T_DIR"; then printf 'it is the team folder or inside it, where the secret keys are'; return 0; fi
    if within "$T_DIR" "$1"; then printf 'it contains the team folder, where the secret keys are'; return 0; fi
    if [ -f "$1/team.conf" ] || [ -f "$1/identity.key" ]; then printf 'it is an agent or team folder'; return 0; fi
    return 1
}
resolve_workspace() { # -> RUN_WORKSPACE WORKSPACE_SOURCE
    local dir reason
    if [ -n "$OPT_WORKSPACE" ]; then
        dir=$OPT_WORKSPACE
        case $dir in *[[:cntrl:]]*) die '--workspace: the folder name contains control characters' ;; esac
        case $dir in /*) ;; *) dir=${CALL_DIR:-.}/$dir ;; esac
        [ -d "$dir" ] || die "--workspace: not a folder: $dir"
        dir=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd) || die "--workspace: cannot open $dir"
        if reason=$(unsafe_workspace "$dir"); then die "--workspace $dir cannot be the project folder: $reason. Nothing was started."; fi
        RUN_WORKSPACE=$dir WORKSPACE_SOURCE='--workspace'
        return 0
    fi
    if [ -z "$CALL_DIR" ]; then die 'cannot read the current folder; pass --workspace DIR'; fi
    if reason=$(unsafe_workspace "$CALL_DIR"); then
        RUN_WORKSPACE=$T_WORKSPACE
        WORKSPACE_SOURCE="saved in team.conf; the current folder is not used: $reason"
        return 0
    fi
    RUN_WORKSPACE=$CALL_DIR WORKSPACE_SOURCE='the current folder'
}

# ---------------------------------------------------------------- running agents
# agent.pid: PID, the process start time, the provider and (from team.sh) the model, the project
# folder and the reasoning effort of that run.
read_pidfile() { # HOME -> PF_PID PF_START PF_BACKEND PF_MODEL PF_WORKSPACE PF_EFFORT PF_WALL; returns 1 when there is none
    PF_PID='' PF_START='' PF_BACKEND='' PF_MODEL='' PF_WORKSPACE='' PF_EFFORT='' PF_WALL=''
    [ -f "$1/agent.pid" ] || return 1
    { IFS= read -r PF_PID && IFS= read -r PF_START && IFS= read -r PF_BACKEND && IFS= read -r PF_MODEL && IFS= read -r PF_WORKSPACE && IFS= read -r PF_EFFORT && IFS= read -r PF_WALL; } < "$1/agent.pid" || true
    case $PF_PID in '' | *[!0-9]*) PF_PID=''; return 1 ;; esac
}
proc_start() { trim "$(ps -o lstart= -p "$1" 2>/dev/null || true)"; }
# The recorded process is alive and is the same process (same PID and start time) that was started.
ours_alive() { # HOME
    read_pidfile "$1" || return 1
    kill -0 "$PF_PID" 2>/dev/null || return 1
    [ "$(proc_start "$PF_PID")" = "$PF_START" ]
}

# ---------------------------------------------------------------- models
# The list the skill last retrieved for a provider and role ("agent-team.sh models"): ID<TAB>name
# lines. It is read from models/ in this folder, else from models/ in the folder above it.
models_file() { # BACKEND ROLE -> path; returns 1 when there is none
    local f
    for f in "$T_DIR/models/$1-$2.list" "$T_DIR/../models/$1-$2.list"; do
        if [ -s "$f" ]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}
claude_documented_model() {
    case $1 in best | fable | sonnet | opus | haiku | 'sonnet[1m]' | 'opus[1m]' | opusplan) return 0 ;; esac
    [[ $1 =~ ^claude-(opus|sonnet|haiku|fable)-[0-9]+(-[0-9]+)*(\[1m\])?$ ]]
}
# "default" is an entry of the Claude adapter's list, but the launcher hands a model to Claude Code
# as a model name, and Claude Code then refuses every turn ("There's an issue with the selected model
# (default)"). So no Claude agent starts with it: the menu leaves it out, and it is refused as a
# choice and as a saved model.
claude_default_model() { [ "$1" = claude ] && [ "$2" = default ]; } # BACKEND MODEL
menu_models() { # BACKEND LIST: the ID<TAB>name lines the model menu offers
    awk -F'\t' -v b="$1" '!/^#/ && !(b == "claude" && $1 == "default")' "$2"
}

# ---------------------------------------------------------------- the provider's list, retrieved now
# A credential, endpoint or provider selection of either runtime. They are removed before an adapter
# is asked for its models, so the list is the one the subscription sign-in offers. Keep this function
# identical to credential_name in agent-team.sh and run-buzz-acp.sh (test-team-sh.sh compares them).
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
# Where a retrieved list is kept: where the kept one is; else in the folder above when it has models/
# (the skill's own lists, shared by the teams beside this one); else in models/ of this folder.
models_store() { # BACKEND ROLE -> path
    local f
    if f=$(models_file "$1" "$2"); then printf '%s' "$f"
    elif [ -d "$T_DIR/../models" ]; then printf '%s' "$T_DIR/../models/$1-$2.list"
    else printf '%s' "$T_DIR/models/$1-$2.list"; fi
}
# Ask the adapter an agent runs for the models it offers now, and keep the list. One session with
# the adapter and no model turn (acp-models.py in this folder); one attempt per provider and agent
# in a run, at most 30 seconds. On any failure the reason is said and the kept list stays as it was.
MODELS_TRIED=' ' MODELS_NOW=' '
refresh_models() { # BACKEND ID: 0 when the list in place was retrieved in this run
    local b=$1 id=$2 py=${AGENT_TEAM_PYTHON:-python3} fetch=$T_DIR/acp-models.py cmd dest dir timeout v rc=0 why
    case $MODELS_NOW in *" $b-$id "*) return 0 ;; esac
    case $MODELS_TRIED in *" $b-$id "*) return 1 ;; esac
    MODELS_TRIED="$MODELS_TRIED$b-$id "
    if [ ! -f "$fetch" ]; then
        note "$(label "$id"): the $b model list is not retrieved now: this team folder has no acp-models.py (add it with the skill: agent-team.sh upgrade <team>)"
        return 1
    fi
    if [ "$py" = none ] || ! command -v -- "$py" >/dev/null 2>&1; then
        note "$(label "$id"): the $b model list is not retrieved now: python3 is not on PATH"
        return 1
    fi
    if own_runtime "$id"; then cmd=$(ahome "$id")/runtime/$(backend_command "$b")
    else cmd=$(command -v -- "$(backend_command "$b")" 2>/dev/null) || cmd=''; fi
    if [ -z "$cmd" ] || [ ! -x "$cmd" ]; then
        note "$(label "$id"): the $b model list is not retrieved now: $(backend_command "$b") is not here to ask"
        return 1
    fi
    timeout=${AGENT_TEAM_MODELS_TIMEOUT:-30}
    case $timeout in '' | *[!0-9]*) timeout=30 ;; esac
    [ "$timeout" -ge 1 ] && [ "$timeout" -le 30 ] || timeout=30
    dest=$(models_store "$b" "$id")
    dir=${dest%/*}
    if [ ! -d "$dir" ]; then mkdir -p -- "$dir" 2>/dev/null && chmod 700 "$dir"; fi
    LIST_TMP=$(mktemp "$dir/.new-list.XXXXXX" 2>/dev/null) || LIST_TMP=''
    if [ -z "$LIST_TMP" ]; then
        note "$(label "$id"): the $b model list is not retrieved now: cannot write in $dir"
        return 1
    fi
    note "$(label "$id"): asking $b which models it offers now (at most $timeout s) ..."
    {
        printf '# retrieved %s from %s\n' "$(now_utc)" "$cmd"
        (
            scrub_env
            for v in $(compgen -e); do if credential_name "$v"; then unset "$v"; fi; done
            unset CLAUDE_CODE_EXECUTABLE
            export CLAUDE_AGENT_ACP_PROTOCOL=v1
            exec "$py" -I "$fetch" --lines --timeout "$timeout" -- "$cmd" < /dev/null
        )
    } > "$LIST_TMP" 2> "$LIST_TMP.err" || rc=$?
    if [ "$rc" = 0 ] && [ "$(grep -vc '^#' "$LIST_TMP")" -ge 1 ]; then
        chmod 600 "$LIST_TMP"
        mv -f -- "$LIST_TMP" "$dest"
        rm -f -- "$LIST_TMP.err"
        LIST_TMP=''
        MODELS_NOW="$MODELS_NOW$b-$id "
        return 0
    fi
    why=$(tail -n 1 "$LIST_TMP.err" 2>/dev/null | cut -c1-300)
    rm -f -- "$LIST_TMP" "$LIST_TMP.err"
    LIST_TMP=''
    note "  not retrieved: ${why:-the adapter gave no answer}"
    if dest=$(models_file "$b" "$id"); then note "  the list kept from $(sed -n '1s/^# retrieved //p' "$dest" | cut -d' ' -f1) is used instead"; fi
    return 1
}
claude_label() { # claude-opus-5-5 -> "Opus 5.5" (how the adapter names that model in its list)
    local f
    [[ $1 =~ ^claude-(opus|sonnet|haiku|fable)-([0-9]+)(-([0-9]+))?$ ]] || return 0
    f=${BASH_REMATCH[1]}
    printf '%s%s %s%s' "$(printf '%s' "${f:0:1}" | LC_ALL=C tr 'a-z' 'A-Z')" "${f:1}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:+.${BASH_REMATCH[4]}}"
}
valid_model() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,63}(\[[A-Za-z0-9]{1,12}\])?$ ]] || return 1
    case $1 in sk-* | SK-*) return 1 ;; esac
}
# 0: the provider offers MODEL for that role; 1: it does not; 2: there is no list here to tell.
model_offered() { # BACKEND ROLE MODEL
    local list label
    if list=$(models_file "$1" "$2"); then
        if grep -v '^#' "$list" | cut -f1 | grep -Fxq -- "$3"; then return 0; fi
        # A full Claude name that the list offers under its alias, e.g. claude-opus-5-5 as "opus: Opus 5.5".
        if [ "$1" = claude ] && claude_documented_model "$3"; then
            label=$(claude_label "$3")
            if [ -n "$label" ] && grep -v '^#' "$list" | cut -f2 | grep -Fq -- "$label"; then return 0; fi
        fi
        return 1
    fi
    if [ "$1" = claude ]; then claude_documented_model "$3"; return; fi
    return 2
}
require_model() { # BACKEND ROLE MODEL
    local list rc=0
    valid_model "$3" || die "not a model id: $3"
    if claude_default_model "$1" "$3"; then
        die "\"default\" names no model: Claude Code would take it as a model name and refuse every turn of $(label "$2"). Keep the saved model (Enter, or no model option), or name one such as claude-opus-5-5; nothing was started"
    fi
    model_offered "$1" "$2" "$3" || rc=$?
    # The kept list may be older than the model: the provider is asked again, once, before a refusal.
    if [ "$rc" = 1 ] && refresh_models "$1" "$2"; then rc=0; model_offered "$1" "$2" "$3" || rc=$?; fi
    case $rc in
        0) ;;
        2) note "note: no retrieved model list for $1 here; $3 is passed to $(label "$2") as given" ;;
        *)
            if list=$(models_file "$1" "$2"); then
                die "$3 is not a $1 model offered for $(label "$2"). The list retrieved $(sed -n '1s/^# retrieved //p' "$list" | cut -d' ' -f1) offers: $(grep -v '^#' "$list" | cut -f1 | tr '\n' ' ')"
            fi
            die "$3 is not a Claude model: use an alias (opus, sonnet, haiku, fable) or a full name such as claude-opus-5-5" ;;
    esac
}

# ---------------------------------------------------------------- questions
ASK=no
ask() { # PROMPT -> REPLY, trimmed
    printf '%s' "$1" >&2
    IFS= read -r REPLY || die 'cancelled; nothing was started'
    REPLY=$(trim "$REPLY")
}

choose_agents() { # -> SELECTED, space-separated
    local all n=1 id tok out='' state
    all=$(team_agents | tr '\n' ' ')
    all=$(trim "$all")
    # shellcheck disable=SC2086
    set -- $all
    if [ "$#" -le 1 ] || [ "$ASK" = no ]; then SELECTED=$all; return 0; fi
    note 'Start which agents?'
    note '  [Enter] all'
    for id in "$@"; do
        state=''
        if ours_alive "$(ahome "$id")"; then state="   running on ${PF_BACKEND:-an unrecorded provider}"; fi
        note "  [$n] $(label "$id")$state"
        n=$((n + 1))
    done
    ask '> '
    if [ -z "$REPLY" ]; then SELECTED=$all; return 0; fi
    case $REPLY in *[!A-Za-z0-9._,\ -]*) die 'answer with numbers or agent names; nothing was started' ;; esac
    for tok in ${REPLY//,/ }; do
        case $tok in
            a | all | All | ALL) SELECTED=$all; return 0 ;;
            *[!0-9]*) id=$(role_of "$tok") || die "$(unknown_agent "$tok"); nothing was started" ;;
            *)
                [ "$tok" -ge 1 ] && [ "$tok" -le "$#" ] || die "choose a number from 1 to $#; nothing was started"
                eval "id=\${$tok}" ;;
        esac
        case " $all " in *" $id "*) ;; *) die "$(unknown_agent "$tok"); nothing was started" ;; esac
        case " $out " in *" $id "*) ;; *) out="$out $id" ;; esac
    done
    SELECTED=$(trim "$out")
}

# Options given on the command line; a per-agent option wins over the general one.
OPT_BACKEND='' OPT_MODEL='' OPT_EFFORT=''
OPT_EFFORT_agent='' OPT_EFFORT_supervisor='' OPT_EFFORT_reviewer=''
OPT_BACKEND_agent='' OPT_BACKEND_supervisor='' OPT_BACKEND_reviewer=''
OPT_MODEL_agent='' OPT_MODEL_supervisor='' OPT_MODEL_reviewer=''

choose_backend() { # ID -> RUN_BACKEND_<id>, RUN_EXPLICIT_<id>
    local id=$1 saved b='' explicit=no
    saved=$(saved_backend "$id")
    check_backend "$saved"
    eval "b=\$OPT_BACKEND_$id"
    [ -n "$b" ] || b=$OPT_BACKEND
    if [ -n "$b" ]; then
        explicit=yes
    elif [ "$ASK" = yes ]; then
        note "$(label "$id"): provider?"
        if [ "$saved" = claude ]; then note '  [Enter] keep claude (saved)   [2] codex'
        else note '  [Enter] keep codex (saved)   [1] claude'; fi
        ask '> '
        case $REPLY in
            '') ;;
            1 | [Cc]laude) b=claude; explicit=yes ;;
            2 | [Cc]odex) b=codex; explicit=yes ;;
            *) die 'choose claude or codex; nothing was started' ;;
        esac
    fi
    b=${b:-$saved}
    eval "RUN_BACKEND_$id=\$b; RUN_EXPLICIT_$id=\$explicit"
}

choose_model() { # ID -> RUN_MODEL_<id>; empty keeps the model saved for that provider
    local id=$1 b m='' saved list rows ids count line n mid mname
    eval "b=\$RUN_BACKEND_$id; m=\$OPT_MODEL_$id"
    [ -n "$m" ] || m=$OPT_MODEL
    saved=$(saved_model "$id" "$b")
    if [ -z "$m" ] && [ "$ASK" = yes ]; then
        refresh_models "$b" "$id" || true
        note "$(label "$id"): model on $b?"
        note "  [Enter] keep ${saved:-the runtime default} (saved)"
        ids=''
        if list=$(models_file "$b" "$id") && rows=$(menu_models "$b" "$list") && [ -n "$rows" ]; then
            ids=$(printf '%s\n' "$rows" | cut -f1)
            count=$(printf '%s\n' "$ids" | grep -c .)
            if [ "$count" -le 16 ]; then
                n=1
                while IFS=$'\t' read -r mid mname; do
                    printf '  [%d] %-28s %s\n' "$n" "$mid" "${mname:0:70}" >&2
                    n=$((n + 1))
                done <<EOF
$rows
EOF
            else
                # A long list (Codex lists each model once per reasoning level): the ids only, in columns.
                printf '%s\n' "$ids" | awk '
                    { a[NR] = $0; if (length($0) > w) w = length($0) }
                    END {
                        cols = int(100 / (w + 8)); if (cols < 1) cols = 1
                        fmt = "  [%2d] %-" w "s"
                        for (i = 1; i <= NR; i++) { printf fmt, i, a[i]; if (i % cols == 0 || i == NR) printf "\n" }
                    }' >&2
            fi
            note "  a number, or a model id (list retrieved $(sed -n '1s/^# retrieved //p' "$list" | cut -d' ' -f1))"
        else
            note "  or a model id (no retrieved list for $b here)"
        fi
        ask '> '
        case $REPLY in
            '') ;;
            *[!0-9]*) m=$REPLY ;;
            *)
                m=$(printf '%s\n' "$ids" | sed -n "${REPLY}p")
                [ -n "$m" ] || die "no model number $REPLY in that list; nothing was started" ;;
        esac
    fi
    if [ -n "$m" ]; then
        require_model "$b" "$id" "$m"
    elif claude_default_model "$b" "$saved"; then
        die "the saved model of $(label "$id") is \"default\", which names no model: Claude Code would refuse every turn. Start it with a named model (--$id-model ID), and change the saved one with the skill (agent-team.sh upgrade <team> --$id-model ID); nothing was started"
    fi
    eval "RUN_MODEL_$id=\$m"
}

# ---------------------------------------------------------------- reasoning effort
# One level per agent and provider, saved in agent.conf (effort_claude=, effort_codex=) by the skill.
# Claude takes it as CLAUDE_CODE_EFFORT_LEVEL. Codex takes it in the model name, model[level], which
# the adapter sends as the model and its reasoning effort; so on Codex a level needs a model.
CLAUDE_EFFORTS='low medium high xhigh max'
CODEX_EFFORTS='low medium high xhigh max ultra'
saved_effort() { afield "$1" "effort_$2"; } # ID BACKEND
model_base() { printf '%s' "${1%\[*\]}"; }
model_level() { local s; case $1 in *\[*\]) s=${1##*\[}; printf '%s' "${s%\]}" ;; esac; return 0; }
# The levels on offer: Claude's five; for Codex the levels the retrieved list has for that model
# (its model[level] entries), or the usual six when there is no list here.
effort_levels() { # BACKEND ROLE MODEL
    local list base
    if [ "$1" = claude ]; then printf '%s' "$CLAUDE_EFFORTS"; return 0; fi
    base=$(model_base "$3")
    [ -n "$base" ] || return 0
    if list=$(models_file codex "$2"); then
        grep -v '^#' "$list" | cut -f1 | awk -v b="$base" 'index($0, b "[") == 1 { s = substr($0, length(b) + 2); sub(/\]$/, "", s); printf "%s ", s }'
    else
        printf '%s' "$CODEX_EFFORTS"
    fi
    return 0
}

choose_effort() { # ID -> RUN_EFFORT_<id>; on Codex the level also goes into RUN_MODEL_<id>
    local id=$1 b m e='' saved model levels n lv row newm
    eval "b=\$RUN_BACKEND_$id; m=\$RUN_MODEL_$id; e=\$OPT_EFFORT_$id"
    [ -n "$e" ] || e=$OPT_EFFORT
    saved=$(saved_effort "$id" "$b")
    model=$m
    [ -n "$model" ] || model=$(saved_model "$id" "$b")
    # A level written into a Codex model name chosen for this run is the choice.
    if [ -z "$e" ] && [ "$b" = codex ] && [ -n "$m" ]; then e=$(model_level "$m"); fi
    levels=$(trim "$(effort_levels "$b" "$id" "$model")")
    if [ -z "$e" ] && [ "$ASK" = yes ] && [ -n "$levels" ]; then
        note "$(label "$id"): reasoning effort on $b?"
        if [ -n "$saved" ]; then note "  [Enter] keep $saved (saved)"
        elif [ "$b" = claude ]; then note '  [Enter] set none here: Claude Code uses your own level for this model'
        else note '  [Enter] set none here: Codex uses the default of your configuration'; fi
        n=1 row=''
        for lv in $levels; do row="$row[$n] $lv   "; n=$((n + 1)); done
        note "  $row"
        [ -z "$saved" ] || note '  or type default, to set none for this run'
        ask '> '
        case $REPLY in
            '') ;;
            *[!0-9]*) e=$REPLY ;;
            *)
                [ "$REPLY" -ge 1 ] && [ "$REPLY" -lt "$n" ] || die "choose a number from 1 to $((n - 1)); nothing was started"
                # shellcheck disable=SC2086
                set -- $levels
                eval "e=\${$REPLY}" ;;
        esac
    fi
    [ -n "$e" ] || e=$saved
    case $e in default | none) e='' ;; esac
    if [ -n "$e" ]; then
        if [ "$b" = codex ] && [ -z "$model" ]; then
            die "on Codex the reasoning effort is part of the model name, so $(label "$id") needs a model too (--$id-model ID); nothing was started"
        fi
        case " $levels " in
            *" $e "*) ;;
            *) die "$e is not a reasoning effort offered for $(label "$id") on $b${model:+ with $(model_base "$model")} (offered: ${levels:-none}; default sets none); nothing was started" ;;
        esac
        if [ "$b" = codex ]; then
            newm="$(model_base "$model")[$e]"
            eval "RUN_MODEL_$id=\$newm"
        fi
    fi
    eval "RUN_EFFORT_$id=\$e"
}

# ---------------------------------------------------------------- what holds an agent to the project folder
# How an agent is held for this run:
#   runtime   its restricted runtime (the channel supervisor, the reviewer): reads inside the project
#             folder only, no edits, no commands
#   settings  the stock Claude adapter with the sandbox settings in the project folder,
#             PROJECT/.claude/settings.json (workspace-settings.py in this folder writes and checks them)
#   codex     the stock Codex adapter, which runs every turn in Codex's workspace-write sandbox
#   none      the stock Claude adapter in a project folder without those settings (--no-wall)
# Beside these, the workspace agent's prompt carries the rule to stay inside the project folder.
NO_WALL=no
WS_APPLY_ERROR=''   # why a start could not put the settings into the project folder
own_runtime() { # ID: its settings name a runtime of its own folder
    local v
    v=$(env_get "$(ahome "$1")/$ENV_NAME" BUZZ_ACP_AGENT_COMMAND) || v=''
    case $v in */runtime/claude-agent-acp | */runtime/codex-acp) return 0 ;; esac
    return 1
}
# workspace_settings apply|check DIR: prints the helper's one line. Status: the helper's (0 written or
# in place; 3 absent; 4 incomplete; 2 the file cannot be used), 5 without python3, 6 without the helper.
workspace_settings() {
    local py=${AGENT_TEAM_PYTHON:-python3}
    [ "$py" != none ] || py=python3
    if [ ! -f "$T_DIR/workspace-settings.py" ]; then
        printf 'this team folder has no workspace-settings.py; add it with the skill: agent-team.sh upgrade <team>'
        return 6
    fi
    if ! command -v "$py" >/dev/null 2>&1; then
        printf 'python3 is needed to write the settings file, and it is not on PATH'
        return 5
    fi
    "$py" -I "$T_DIR/workspace-settings.py" "$1" "$2" 2>&1
}
hold_kind() { # ID BACKEND
    if own_runtime "$1"; then printf 'runtime'
    elif [ "$2" = codex ]; then printf 'codex'
    elif [ "$NO_WALL" = yes ] && ! workspace_settings check "$RUN_WORKSPACE" >/dev/null 2>&1; then printf 'none'
    else printf 'settings'; fi
}

# ---------------------------------------------------------------- what an agent is started with
# Exported BUZZ_* and RUN_BUZZ_ACP_* settings of the calling shell would override the agent's own files.
scrub_env() {
    local v
    for v in $(compgen -e); do
        case $v in BUZZ_* | RUN_BUZZ_ACP_*) unset "$v" ;; esac
    done
}
# The launcher takes exported values over the settings file. The paths are exported from where this
# folder is now, so the paths written into the settings file at creation do not have to match.
agent_env() { # ID
    local home v b e
    home=$(ahome "$1")
    # The chosen reasoning effort of a Claude agent. With none chosen, the variable is left as the
    # calling shell has it, as the user's own Claude Code settings are.
    eval "b=\$RUN_BACKEND_$1; e=\$RUN_EFFORT_$1"
    if [ "$b" = claude ] && [ -n "$e" ]; then export CLAUDE_CODE_EFFORT_LEVEL=$e; fi
    # On the stock Codex adapter: its workspace-write mode, whatever the calling shell exports. The
    # adapter sends that mode's sandbox with every turn, over what a Codex config file says.
    if [ "$(hold_kind "$1" "$b")" = codex ]; then export INITIAL_AGENT_MODE=agent; fi
    export RUN_BUZZ_ACP_KEY_FILE=$home/identity.key
    export BUZZ_ACP_SYSTEM_PROMPT_FILE=$home/prompt.md
    export RUN_BUZZ_ACP_WORKDIR=$RUN_WORKSPACE
    v=$(env_get "$home/$ENV_NAME" BUZZ_ACP_AGENT_COMMAND) || v=''
    case $v in */runtime/claude-agent-acp | */runtime/codex-acp) export BUZZ_ACP_AGENT_COMMAND=$home/runtime/${v##*/} ;; esac
    v=$(env_get "$home/$ENV_NAME" BUZZ_ACP_CONFIG) || v=''
    case $v in */*) export BUZZ_ACP_CONFIG=$home/${v##*/} ;; esac
    return 0
}
launcher_path() {
    local want=${AGENT_TEAM_LAUNCHER:-run-buzz-acp.sh}
    case $want in
        */*) if [ -f "$want" ] && [ -x "$want" ]; then printf '%s\n' "$want"; fi ;;
        *) command -v -- "$want" 2>/dev/null || true ;;
    esac
}

# ---------------------------------------------------------------- check
PROBLEMS=0 VERBOSE=no
line() { # STATUS NAME DETAIL [FIX]
    printf '  %-8s %-17s %s\n' "$1" "$2" "$3"
    if [ -n "${4:-}" ]; then printf '  %-8s %-17s fix: %s\n' '' '' "$4"; fi
    case $1 in MISSING | PROBLEM) PROBLEMS=$((PROBLEMS + 1)) ;; esac
}
need_cmd() { # NAME
    local p
    p=$(command -v -- "$1" 2>/dev/null) || p=''
    if [ -n "$p" ]; then line ok "$1" "$p"
    else line MISSING "$1" 'not on PATH' "install it, or add its folder to PATH in your shell profile"; fi
}
indent() { sed 's/^/             /'; }

run_checks() { # AGENT...: 0 when everything a start needs is in place
    local id home b m e shown runtime out rc f missing perm old launcher reason rules own
    PROBLEMS=0
    say "Check of team \"$T_NAME\" in $T_DIR (starts nothing):"
    launcher=$(launcher_path)
    if [ -n "$launcher" ]; then line ok launcher "$launcher"
    else line MISSING launcher 'run-buzz-acp.sh is not on PATH' 'add its folder to PATH, or set AGENT_TEAM_LAUNCHER=/path/to/run-buzz-acp.sh'; fi
    need_cmd buzz-acp
    need_cmd buzz
    if [ -d "$RUN_WORKSPACE" ] && reason=$(unsafe_workspace "$RUN_WORKSPACE"); then
        # The folder saved in team.conf is held to the same rule as the current folder and --workspace.
        line PROBLEM 'project folder' "$RUN_WORKSPACE cannot be used: $reason ($WORKSPACE_SOURCE)" 'keep the team folder outside the project folder; then run this command from the project folder, or pass --workspace DIR'
    elif [ -d "$RUN_WORKSPACE" ]; then
        line ok 'project folder' "$RUN_WORKSPACE ($WORKSPACE_SOURCE)"
        if [ "$RUN_WORKSPACE" != "$T_WORKSPACE" ]; then line note 'project folder' "this team was created for $T_WORKSPACE"; fi
        if [ ! -f "$RUN_WORKSPACE/PROJECT.md" ]; then line note 'project record' 'that folder has no PROJECT.md, the record both agents consult'; fi
        if conf_get "$T_DIR/team.conf" wall_read >/dev/null; then line note 'team.conf' 'wall_read is no longer used: the sandbox settings are in the project folder, and you can edit them there'; fi
    else
        line PROBLEM 'project folder' "$RUN_WORKSPACE is not a folder on this machine ($WORKSPACE_SOURCE)" 'go to the project folder and run this command from there, or pass --workspace DIR'
    fi
    if upgrade_interrupted; then line PROBLEM 'team folder' 'an upgrade was interrupted' 'finish it with the skill: agent-team.sh upgrade <team>'; fi
    for id in "$@"; do
        home=$(ahome "$id")
        eval "b=\$RUN_BACKEND_$id; m=\$RUN_MODEL_$id; e=\$RUN_EFFORT_$id"
        shown=$m
        [ -n "$shown" ] || shown=$(saved_model "$id" "$b")
        say "$(label "$id"): $b, model ${shown:-the runtime default}, reasoning effort ${e:-none set here}"
        if [ "$b" = claude ] && [ -z "$e" ] && [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
            line note 'reasoning effort' "this shell exports CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL, which this agent will use"
        fi
        f=$(agent_format "$id")
        if [ "$f" != "$FORMAT" ]; then
            line PROBLEM record "made by an earlier version of the skill (format $f)" 'upgrade it with the skill: agent-team.sh upgrade <team>'
            continue
        fi
        missing=''
        for f in identity.key "$ENV_NAME" prompt.md; do [ -s "$home/$f" ] || missing="$missing $f"; done
        # An agent whose settings file names subscription rules (the channel supervisor) needs that file.
        rules=$(env_get "$home/$ENV_NAME" BUZZ_ACP_CONFIG) || rules=''
        if [ -n "$rules" ] && [ ! -s "$home/${rules##*/}" ]; then missing="$missing ${rules##*/}"; fi
        if [ -n "$missing" ]; then
            line MISSING files "missing or empty:$missing" 'copy them from the original team folder, or rebuild them with the skill: agent-team.sh upgrade <team>'
            continue
        fi
        line ok files 'key, settings file and prompt are here'
        perm=$(mode_of "$home/identity.key")
        case $perm in 600 | 400) ;; *) line PROBLEM 'key file' "identity.key has mode $perm; other users may read it" "chmod 600 $home/identity.key" ;; esac
        if [ -n "$(env_get "$home/$ENV_NAME" BUZZ_AUTH_TAG || true)" ]; then line ok proof 'ownership proof stored'
        else line MISSING proof 'no ownership proof stored' 'store one with the skill: agent-team.sh proof <team> '"$id"; fi
        if out=$(answers "$id"); then line ok answers "$out"
        else line PROBLEM answers "$out, which the harness refuses to start" 'rebuild its settings with the skill: agent-team.sh upgrade <team>'; fi
        old=$(env_get "$home/$ENV_NAME" RUN_BUZZ_ACP_KEY_FILE) || old=''
        if [ -n "$old" ] && [ "$old" != "$home/identity.key" ]; then
            line note 'moved folder' "the settings file names ${old%/identity.key}; this folder's own paths are used instead"
        fi
        case $(hold_kind "$id" "$b") in
            runtime) line ok sandbox 'its runtime reads only the project folder; no edits, no commands' ;;
            codex) line ok sandbox "Codex's workspace-write: its commands write only inside $RUN_WORKSPACE and temporary folders" ;;
            *)
                rc=0
                out=$(workspace_settings check "$RUN_WORKSPACE") || rc=$?
                if [ "$rc" = 0 ]; then
                    line ok sandbox "the settings in $RUN_WORKSPACE/.claude/settings.json hold its file tools and shell to that folder"
                elif [ "$NO_WALL" = yes ]; then
                    line note sandbox 'NONE (--no-wall): the project folder has no sandbox settings; only the rule in its prompt holds this agent'
                elif [ -n "$WS_APPLY_ERROR" ]; then
                    line PROBLEM sandbox 'its sandbox settings could not be put into the project folder:' 'fix what the lines below name, or pass --no-wall to start it with only the rule in its prompt'
                    printf '%s\n' "$WS_APPLY_ERROR" | tail -n 4 | indent
                elif [ "$rc" = 3 ] || [ "$rc" = 4 ]; then
                    line note sandbox "its settings are not in the project folder yet; a start puts them into $RUN_WORKSPACE/.claude/settings.json first"
                else
                    line PROBLEM sandbox 'its sandbox settings cannot be put into the project folder:' 'fix what the lines below name, or pass --no-wall to start it with only the rule in its prompt'
                    printf '%s\n' "$out" | tail -n 4 | indent
                fi ;;
        esac
        own=$(env_get "$home/$ENV_NAME" BUZZ_ACP_AGENT_COMMAND) || own=''
        if case $own in */runtime/claude-agent-acp | */runtime/codex-acp) true ;; *) false ;; esac; then
            # The channel supervisor and the reviewer run their own restricted runtime; that copy is checked.
            runtime=$home/runtime/$(backend_command "$b")
            if [ ! -x "$runtime" ]; then
                line MISSING runtime "runtime/$(backend_command "$b") is not here" 'rebuild it with the skill: agent-team.sh upgrade <team>'
                continue
            fi
            rc=0
            out=$("$runtime" --check-runtime 2>&1 < /dev/null) || rc=$?
            if [ "$rc" = 0 ]; then line ok runtime "runtime/$(backend_command "$b") (restricted tools)"
            else line PROBLEM runtime "the $b restricted runtime check failed:"; printf '%s\n' "$out" | tail -n 12 | indent; fi
        else
            need_cmd "$(backend_command "$b")"
        fi
        [ -n "$launcher" ] || continue
        rc=0
        out=$( (scrub_env; agent_env "$id"; cd -- "$home" && "$launcher" --check --backend "$b" ${m:+--model "$m"}) 2>&1 < /dev/null) || rc=$?
        if [ "$rc" = 0 ]; then
            line ok 'launcher check' 'settings, key, harness and subscription sign-in accepted'
            if [ "$VERBOSE" = yes ]; then printf '%s\n' "$out" | indent; fi
        else
            line PROBLEM 'launcher check' "run-buzz-acp.sh --check refused this agent on $b:"
            printf '%s\n' "$out" | tail -n 14 | indent
        fi
    done
    if [ "$PROBLEMS" = 0 ]; then say 'Check passed.'; return 0; fi
    say "Check failed: $PROBLEMS problem(s). Fix the lines marked MISSING or PROBLEM, then run team.sh check again."
    return 1
}

# ---------------------------------------------------------------- start and check
cmd_start() { # MODE(start|check) ARGS...
    local mode=$1 ids='' all=no yes=no id b m e w home log pid protocol wait_s max_bytes size i alive started='' todo='' explicit rc out
    shift
    while [ "$#" -gt 0 ]; do
        case $1 in
            --all) all=yes ;;
            --yes | -y) yes=yes ;;
            --no-wall) NO_WALL=yes ;;
            --check) mode=check ;;
            --verbose | -v) VERBOSE=yes ;;
            --backend) need_value "$@"; check_backend "$2"; OPT_BACKEND=$2; shift ;;
            --model) need_value "$@"; OPT_MODEL=$2; shift ;;
            --workspace) need_value "$@"; OPT_WORKSPACE=$2; shift ;;
            --assistant-*) die "$1 is no longer an option: since 4.0.0 it is --agent-${1#--assistant-}" ;;
            --agent-backend | --supervisor-backend | --reviewer-backend)
                need_value "$@"; check_backend "$2"
                id=${1#--}; id=${id%-backend}
                eval "OPT_BACKEND_$id=\$2"; shift ;;
            --agent-model | --supervisor-model | --reviewer-model)
                need_value "$@"
                id=${1#--}; id=${id%-model}
                eval "OPT_MODEL_$id=\$2"; shift ;;
            --effort) need_value "$@"; OPT_EFFORT=$2; shift ;;
            --agent-effort | --supervisor-effort | --reviewer-effort)
                need_value "$@"
                id=${1#--}; id=${id%-effort}
                eval "OPT_EFFORT_$id=\$2"; shift ;;
            -h | --help) usage; exit 0 ;;
            -*) die "$mode: unknown option: $1 (see team.sh help)" ;;
            *)
                id=$(role_of "$1") || die "$(unknown_agent "$1")"
                [ -f "$(ahome "$id")/agent.conf" ] || die "this team has no agent \"$1\""
                case " $ids " in *" $id "*) ;; *) ids="$ids $id" ;; esac ;;
        esac
        shift
    done
    load_team
    [ -n "$(team_agents)" ] || die "$T_DIR has no agent folders"
    resolve_workspace
    # Questions are asked in a terminal, for a start only. TEAM_SH_ASK=1 reads them from standard input.
    if [ "$mode" = start ] && [ "$yes" = no ] && { [ -t 0 ] || [ "${TEAM_SH_ASK:-}" = 1 ]; }; then ASK=yes; fi
    ids=$(trim "$ids")
    if [ -n "$ids" ]; then SELECTED=$ids
    elif [ "$all" = yes ]; then SELECTED=$(trim "$(team_agents | tr '\n' ' ')")
    else choose_agents; fi
    [ -n "$SELECTED" ] || die 'no agent selected; nothing was started'
    for id in $SELECTED; do
        choose_backend "$id"
        choose_model "$id"
        choose_effort "$id"
    done
    # A choice that would switch an agent that is already running stops here, before anything starts.
    for id in $SELECTED; do
        eval "b=\$RUN_BACKEND_$id; explicit=\$RUN_EXPLICIT_$id"
        if [ "$mode" = start ] && ours_alive "$(ahome "$id")"; then
            if [ "$explicit" = yes ] && [ "${PF_BACKEND:-unrecorded}" != "$b" ]; then
                die "$(adir "$id") is running as PID $PF_PID on ${PF_BACKEND:-an unrecorded provider}, not $b; nothing was started. Stop it first (team.sh stop $(adir "$id")), then start it again."
            fi
        else
            todo="$todo $id"
        fi
    done
    todo=$(trim "$todo")
    if [ "$mode" = check ]; then
        # shellcheck disable=SC2086
        run_checks $SELECTED || exit 1
        return 0
    fi
    if [ -z "$todo" ]; then
        for id in $SELECTED; do ours_alive "$(ahome "$id")" && say "$(adir "$id"): already running as PID $PF_PID on ${PF_BACKEND:-an unrecorded provider}${PF_WORKSPACE:+ in $PF_WORKSPACE}; not started again"; done
        return 0
    fi
    # A team works in one project folder at a time: both agents consult the same project record.
    for id in $(team_agents); do
        if ours_alive "$(ahome "$id")" && [ -n "$PF_WORKSPACE" ] && [ "$PF_WORKSPACE" != "$RUN_WORKSPACE" ]; then
            die "$(adir "$id") is running in $PF_WORKSPACE, not in $RUN_WORKSPACE; nothing was started. Stop it first (team.sh stop), or start the others there (--workspace $PF_WORKSPACE)."
        fi
    done
    protocol=${CLAUDE_AGENT_ACP_PROTOCOL:-v1}
    wait_s=${AGENT_TEAM_START_WAIT:-3}
    max_bytes=${AGENT_TEAM_LOG_MAX_BYTES:-10485760}
    case $wait_s in '' | *[!0-9]*) die 'AGENT_TEAM_START_WAIT must be whole seconds' ;; esac
    case $max_bytes in '' | *[!0-9]*) die 'AGENT_TEAM_LOG_MAX_BYTES must be a number of bytes' ;; esac
    [ "$wait_s" -le 60 ] || die 'AGENT_TEAM_START_WAIT is capped at 60 seconds'
    # First, the sandbox settings of an agent on the stock Claude adapter go into the project folder.
    # When that fails, the check below says why and nothing starts.
    if [ "$NO_WALL" = no ] && [ -d "$RUN_WORKSPACE" ] && ! unsafe_workspace "$RUN_WORKSPACE" >/dev/null 2>&1; then
        for id in $todo; do
            eval "b=\$RUN_BACKEND_$id"
            [ "$(hold_kind "$id" "$b")" = settings ] || continue
            rc=0
            out=$(workspace_settings apply "$RUN_WORKSPACE") || rc=$?
            if [ "$rc" != 0 ]; then WS_APPLY_ERROR=$out
            else case $out in 'in place:'*) ;; *) say "Project folder settings: $out" ;; esac; fi
            break
        done
    fi
    # The whole selection is checked, sign-in included, before the first agent starts.
    # shellcheck disable=SC2086
    run_checks $todo || die 'the check failed; nothing was started'
    LAUNCHER=$(launcher_path)
    take_lock
    say "Launcher: $LAUNCHER"
    say "Project folder: $RUN_WORKSPACE ($WORKSPACE_SOURCE)"
    for id in $SELECTED; do
        home=$(ahome "$id") log=$home/agent.log
        if ours_alive "$home"; then say "$(adir "$id"): already running as PID $PF_PID on ${PF_BACKEND:-an unrecorded provider}${PF_WORKSPACE:+ in $PF_WORKSPACE}; not started again"; continue; fi
        eval "b=\$RUN_BACKEND_$id; m=\$RUN_MODEL_$id; e=\$RUN_EFFORT_$id"
        if [ -f "$log" ]; then
            size=$(wc -c < "$log" | tr -d ' ')
            if [ "$size" -gt "$max_bytes" ]; then mv -f -- "$log" "$log.1"; fi
        fi
        printf '\n=== %s: team.sh start (%s, provider %s, model %s, reasoning effort %s, project folder %s) ===\n' "$(now_utc)" "$LAUNCHER" "$b" "${m:-saved}" "${e:-none set here}" "$RUN_WORKSPACE" >> "$log"
        (
            scrub_env
            agent_env "$id"
            export CLAUDE_AGENT_ACP_PROTOCOL=$protocol
            trap '' HUP
            cd -- "$home" && exec "$LAUNCHER" --run --backend "$b" ${m:+--model "$m"}
        ) >> "$log" 2>&1 < /dev/null &
        pid=$!
        [ -n "$m" ] || m=$(saved_model "$id" "$b")
        w=$(hold_kind "$id" "$b")
        printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$pid" "$(proc_start "$pid")" "$b" "$m" "$RUN_WORKSPACE" "$e" "$w" > "$home/.new-pid"
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
            note "$PROG: $id exited right after starting. Last lines of $log:"
            tail -n 20 "$log" >&2 || true
            [ -z "$started" ] || note "Still running: $started"
            die "$(adir "$id") did not start"
        fi
        say "$(adir "$id"): started as PID $pid on $b, model ${m:-the runtime default}${e:+, reasoning effort $e} (log $log)"
        if [ "$w" = none ]; then say "$(adir "$id"): WARNING: started WITHOUT sandbox settings in its project folder; only the rule in its prompt holds it"; fi
        started="$started${started:+, }$id"
    done
    say "Stop them with: $T_DIR/team.sh stop      See them with: $T_DIR/team.sh status"
}

# ---------------------------------------------------------------- stop and status
stop_one() { # ID FORCE GRACE -> 0 stopped or not running, 1 still running
    local id=$1 home i
    home=$(ahome "$1")
    if ! read_pidfile "$home"; then say "$(adir "$id"): not started by this command; nothing to stop"; return 0; fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then say "$(adir "$id"): not running"; rm -f -- "$home/agent.pid"; return 0; fi
    if [ "$(proc_start "$PF_PID")" != "$PF_START" ]; then
        say "$(adir "$id"): PID $PF_PID now belongs to another process; it was not touched"
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
        note "$(adir "$id"): still running as PID $PF_PID after ${3}s; run stop again, or stop --force"
        return 1
    fi
    rm -f -- "$home/agent.pid"
    say "$(adir "$id"): stopped (PID $PF_PID)"
}

cmd_stop() {
    local force=no grace ids='' id failed=0
    while [ "$#" -gt 0 ]; do
        case $1 in
            --force) force=yes ;;
            --all) ;;
            -h | --help) usage; exit 0 ;;
            -*) die "stop: unknown option: $1" ;;
            *)
                id=$(role_of "$1") || die "$(unknown_agent "$1")"
                [ -f "$(ahome "$id")/agent.conf" ] || die "this team has no agent \"$1\""
                ids="$ids $id" ;;
        esac
        shift
    done
    grace=${AGENT_TEAM_STOP_GRACE:-30}
    case $grace in '' | *[!0-9]*) die 'AGENT_TEAM_STOP_GRACE must be whole seconds' ;; esac
    [ "$grace" -le 600 ] || die 'AGENT_TEAM_STOP_GRACE is capped at 600 seconds'
    load_team
    [ -n "$ids" ] || ids=$(team_agents | tr '\n' ' ')
    for id in $ids; do stop_one "$id" "$force" "$grace" || failed=1; done
    [ "$failed" = 0 ] || die 'some agents are still running (see above)'
}

cmd_status() {
    local id home b m run size launcher se
    load_team
    say "Team \"$T_NAME\" in $T_DIR"
    say '  project folder: the folder a start is run from, or --workspace DIR'
    say "    saved in team.conf, used for a start from the team folder: $T_WORKSPACE$( [ -d "$T_WORKSPACE" ] || printf ' (not a folder on this machine)')"
    say "  channel $T_CHANNEL on $T_COMMUNITY"
    launcher=$(launcher_path)
    say "  launcher ${launcher:-NOT FOUND: put run-buzz-acp.sh on PATH}"
    say "  team files $(version_line)"
    if upgrade_interrupted; then say '  An upgrade was interrupted: finish it with the skill (agent-team.sh upgrade <team>).'; fi
    for id in $(team_agents); do
        home=$(ahome "$id")
        b=$(saved_backend "$id")
        m=$(saved_model "$id" "$b")
        se=$(saved_effort "$id" "$b")
        if ours_alive "$home"; then run="running on ${PF_BACKEND:-an unrecorded provider}${PF_MODEL:+, model $PF_MODEL}${PF_EFFORT:+, reasoning effort $PF_EFFORT}${PF_WORKSPACE:+, in $PF_WORKSPACE}; PID $PF_PID since $PF_START"
            case $PF_WALL in
                settings) run="$run; held by the sandbox settings in its project folder" ;;
                codex) run="$run; in Codex's workspace-write sandbox" ;;
                wall) run="$run; behind the workspace wall of a start before 2.0.0" ;;
                runtime) run="$run; held to the project folder by its runtime" ;;
                none) run="$run; NO sandbox settings, only the rule in its prompt" ;;
            esac
        elif read_pidfile "$home"; then run='not running (it exited; see the log)'
        else run='not running'; fi
        size=0
        if [ -f "$home/agent.log" ]; then size=$(wc -c < "$home/agent.log" | tr -d ' '); fi
        say "  $(adir "$id"): $(label "$id"), $(job_words "$id")"
        if [ "$(agent_format "$id")" = "$FORMAT" ]; then
            say "    saved: $b, model ${m:-the runtime default}, reasoning effort ${se:-none set here}"
            say "    answers $(answers "$id" || true)"
        else say "    made by an earlier version of the skill (format $(agent_format "$id")): upgrade it with the skill (agent-team.sh upgrade <team>) before starting"; fi
        say "    $run"
        say "    log $home/agent.log ($size bytes)"
        if [ -x "$home/start.sh" ]; then say "    start it alone: $home/start.sh"; fi
    done
}

# ---------------------------------------------------------------- workspace
cmd_workspace() {
    local dir stamp tmp line id reason
    [ "$#" -eq 1 ] || die 'usage: team.sh workspace DIR   (saved in team.conf as the team'"'"'s project folder)'
    load_team
    dir=$1
    case $dir in *[[:cntrl:]]*) die 'the folder name contains control characters' ;; esac
    case $dir in /*) ;; *) dir=$PWD/$dir ;; esac
    [ -d "$dir" ] || die "not a folder: $dir"
    dir=$(CDPATH='' cd -P -- "$dir" && pwd) || die "cannot open $dir"
    if reason=$(unsafe_workspace "$dir"); then die "$dir cannot be the project folder: $reason. Nothing was changed."; fi
    for id in $(team_agents); do
        if ours_alive "$(ahome "$id")"; then die "$(adir "$id") is running; stop it first (team.sh stop). Nothing was changed."; fi
    done
    if [ "$dir" = "$T_WORKSPACE" ]; then say "The project folder is already $dir; nothing was changed."; return 0; fi
    take_lock
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    cp -p -- "$T_DIR/team.conf" "$T_DIR/team.conf.bak-$stamp" || die 'could not keep a copy of team.conf; nothing was changed'
    tmp=$(mktemp "$T_DIR/.new-team.XXXXXX") || die 'could not write in the team folder; nothing was changed'
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in workspace=*) printf 'workspace=%s\n' "$dir" ;; *) printf '%s\n' "$line" ;; esac
    done < "$T_DIR/team.conf" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$T_DIR/team.conf" || { rm -f -- "$tmp"; die 'could not replace team.conf; nothing was changed'; }
    say "Saved project folder: $T_WORKSPACE -> $dir (earlier record: team.conf.bak-$stamp)"
    say 'It is used when this command is started from the team folder. Started from any other folder,'
    say 'the agents work in that folder, or in the one --workspace names.'
}

# ---------------------------------------------------------------- version
cmd_version() {
    [ "$#" -eq 0 ] || die 'usage: team.sh version'
    load_team
    say "Team \"$T_NAME\": team files $(version_line)"
}

# ---------------------------------------------------------------- main
AGENT_DIR=$(agent_dir)
cmd=${1:-start}
if [ "$#" -eq 0 ]; then set -- start; fi
case $cmd in
    start) shift; cmd_start start "$@" ;;
    check) shift; cmd_start check "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    status) shift; cmd_status ;;
    workspace) shift; cmd_workspace "$@" ;;
    version | --version) shift; cmd_version "$@" ;;
    help | -h | --help) usage ;;
    -*) cmd_start start "$@" ;;
    *)
        # An agent's folder name (or agent) first: start those agents.
        if role_of "$cmd" >/dev/null || [ "$cmd" = assistant ]; then cmd_start start "$@"; exit 0; fi
        die "unknown command: $cmd (see team.sh help)" ;;
esac
