#!/bin/bash
# test-team-sh.sh: offline scenario tests for the team's own command, templates/team.sh, and for how
# agent-team.sh create and upgrade put it into a team folder. Bash 3.2+.
#
#   AGENT_TEAM_TEST_DIR=/abs/scratch/dir AGENT_TEAM_KEYGEN=/path/to/buzz-admin /bin/bash test-team-sh.sh
#
# Everything is written under AGENT_TEAM_TEST_DIR (its "team-sh" folder is replaced on each run). HOME
# and the agents' root point into it. Keys are throwaway keys from the key generator. Nothing contacts
# a relay, a provider or a sign-in: the launcher, buzz, the harness and the adapters are stand-ins
# written into the test folder. The stand-in launcher records what it was started with (paths and
# option values, never a key). No secret key is printed.

set -uo pipefail
umask 077

HERE=$(cd -P -- "$(dirname -- "$0")" && pwd)
SKILL_DIR=$HERE/buzz-agent-team
SCRIPT=$SKILL_DIR/scripts/agent-team.sh
TEMPLATE=$SKILL_DIR/templates/team.sh
START_TEMPLATE=$SKILL_DIR/templates/agent-start.sh
: "${AGENT_TEAM_TEST_DIR:?set AGENT_TEAM_TEST_DIR to an absolute scratch folder}"
: "${AGENT_TEAM_KEYGEN:?set AGENT_TEAM_KEYGEN to the buzz-admin binary (it runs generate-key only)}"
case $AGENT_TEAM_TEST_DIR in /*) ;; *) echo 'AGENT_TEAM_TEST_DIR must be absolute' >&2; exit 2 ;; esac
KEYGEN=$AGENT_TEAM_KEYGEN

mkdir -p -- "$AGENT_TEAM_TEST_DIR"
TOP=$(cd -P -- "$AGENT_TEAM_TEST_DIR" && pwd)
TD=$TOP/team-sh
rm -rf -- "$TD"
mkdir -p -- "$TD"/{bin,out,home,ws/shop,ws/moved-shop,elsewhere}
OUT=$TD/out BIN=$TD/bin ROOT=$TD/root
export GIT_CEILING_DIRECTORIES=$TOP
export HOME=$TD/home
unset CODEX_HOME CLAUDE_CONFIG_DIR AGENT_TEAM_TEMPLATES AGENT_TEAM_PYTHON CLAUDE_AGENT_ACP_PROTOCOL BUZZ_AUTH_TAG AGENT_TEAM_LAUNCHER TEAM_SH_ASK CLAUDE_CODE_EFFORT_LEVEL
export AGENT_TEAM_ROOT=$ROOT AGENT_TEAM_KEYGEN=$KEYGEN AGENT_TEAM_BUZZ=$BIN/buzz
export BUZZ_CLAUDE_MANAGED_DIR=$TD/managed-none
export AGENT_TEAM_START_WAIT=1 AGENT_TEAM_STOP_GRACE=5
# A model list that does not arrive is given up after 3 s here (30 s for a user).
export AGENT_TEAM_MODELS_TIMEOUT=3
# The stand-ins are found on PATH, the way team.sh finds the real commands.
export PATH=$BIN:$PATH
# Stray exported settings in the caller's shell must never reach an agent.
export BUZZ_PRIVATE_KEY=0000000000000000000000000000000000000000000000000000000000000001
export RUN_BUZZ_ACP_WORKDIR=/stray/workdir BUZZ_ACP_SYSTEM_PROMPT_FILE=/stray/prompt.md
CHANNEL=0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0
COMMUNITY=wss://community.example.org
OWNER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

PASS=0 FAIL=0 SCEN=0
scenario() { SCEN=$((SCEN + 1)); printf '\n[S%d] %s\n' "$SCEN" "$1"; }
pass() { PASS=$((PASS + 1)); printf '  pass  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
pid_of() { sed -n '1p' "$1/agent.pid" 2>/dev/null; }
alive() { local p; p=$(pid_of "$1"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# run_skill NAME -- ARGS...: agent-team.sh; output in $OUT/NAME.out, status in RC.
run_skill() { local name=$1; shift 2; RC=0; /bin/bash "$SCRIPT" "$@" > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?; }
# The folder the team command is run from: the project folder, unless a scenario sets another.
RUN_CWD=$TD/ws/shop
# run_team NAME DIR [VAR=value ...] -- ARGS...: DIR/team.sh with no terminal, run from RUN_CWD.
run_team() {
    local name=$1 dir=$2 assigns=()
    shift 2
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    (cd -- "$RUN_CWD" && env ${assigns[@]+"${assigns[@]}"} /bin/bash "$dir/team.sh" "$@") > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?
}
# ask_team NAME DIR ANSWERS -- ARGS...: the questions, answered from standard input.
ask_team() {
    local name=$1 dir=$2 answers=$3
    shift 4
    RC=0
    printf '%b' "$answers" | (cd -- "$RUN_CWD" && env TEAM_SH_ASK=1 /bin/bash "$dir/team.sh" "$@") > "$OUT/$name.out" 2>&1 || RC=$?
}
# run_agent NAME DIR AGENT [VAR=value ...] -- ARGS...: DIR/AGENT/start.sh with no terminal, run from RUN_CWD.
run_agent() {
    local name=$1 dir=$2 agent=$3 assigns=()
    shift 3
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    (cd -- "$RUN_CWD" && env ${assigns[@]+"${assigns[@]}"} /bin/bash "$dir/$agent/start.sh" "$@") > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?
}
# ask_agent NAME DIR AGENT ANSWERS [VAR=value ...] -- ARGS...: the same, with the questions answered.
ask_agent() {
    local name=$1 dir=$2 agent=$3 answers=$4 assigns=()
    shift 4
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    printf '%b' "$answers" | (cd -- "$RUN_CWD" && env TEAM_SH_ASK=1 ${assigns[@]+"${assigns[@]}"} /bin/bash "$dir/$agent/start.sh" "$@") > "$OUT/$name.out" 2>&1 || RC=$?
}
stop_all() { local d; for d in "$@"; do [ -f "$d/team.sh" ] && /bin/bash "$d/team.sh" stop --force > /dev/null 2>&1; done; return 0; }
trap 'stop_all "$ROOT/shop" "$TD/elsewhere/shop" "$ROOT/shop-reviewer"' EXIT

# ---------------------------------------------------------------- stand-ins
cat > "$BIN/buzz" <<'EOF'
#!/bin/bash
echo '{"accepted":true,"stand_in":true}'
EOF
cat > "$BIN/buzz-acp" <<'EOF'
#!/bin/bash
echo "stand-in harness: pid $$"
trap 'echo "stand-in harness: stopping"; exit 0' TERM INT
i=0
while [ "$i" -lt 600 ]; do sleep 1 & wait $!; i=$((i + 1)); done
EOF
cat > "$BIN/claude-agent-acp" <<'EOF'
#!/bin/bash
case "$*" in
    "--cli --help") echo '--restricted --tools --strict-mcp-config --disable-slash-commands --settings --setting-sources --permission-mode'; exit 0 ;;
    "--cli auth status"*) echo '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}'; exit 0 ;;
esac
# Started with no arguments, the adapter speaks ACP: the stand-in answers a model list request.
[ "$#" -gt 0 ] || exec python3 -I "$(dirname "$0")/acp-models-stub.py" claude
exit 0
EOF
# An ACP stand-in that answers initialize and session/new the way the adapters report models.
# $HOME/.fake-acp-mode selects: off (the default: it stops at once, as an adapter that cannot be
# asked), list, error, hang. Each call is recorded in $HOME/.fake-acp-calls, with whether a
# credential or an agent key reached it (never a value).
cat > "$BIN/acp-models-stub.py" <<'EOF'
import json, os, sys, time
backend = sys.argv[1]
home = os.environ["HOME"]
try:
    mode = open(os.path.join(home, ".fake-acp-mode")).read().strip()
except OSError:
    mode = "off"
with open(os.path.join(home, ".fake-acp-calls"), "a") as rec:
    rec.write("call %s mode=%s credential=%s key=%s exe=%s\n" % (
        backend, mode,
        "yes" if any(k.startswith(("ANTHROPIC_", "OPENAI_")) for k in os.environ) else "no",
        "yes" if "BUZZ_PRIVATE_KEY" in os.environ else "no",
        os.environ.get("CLAUDE_CODE_EXECUTABLE", "unset")))
if mode == "off":
    sys.exit(0)
lists = {"claude": [("default", "Default (recommended)"), ("opus", "Opus 5.5"), ("sonnet", "Sonnet 5.5"),
                    ("claude-fable-5-2", "Fable 5.2 - new today"), ("bad id", "an ID with a space"), ("tab\tname", "x")],
         "codex": [("gpt-example-sol", "Example Sol"), ("gpt-example-nova", "Example Nova")]}
for line in sys.stdin:
    m = json.loads(line)
    if m.get("method") == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}}), flush=True)
    elif m.get("method") == "session/new":
        if mode == "hang":
            time.sleep(120)
        if mode == "error":
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32000, "message": "Authentication required"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s", "models": {
            "currentModelId": "default",
            "availableModels": [{"modelId": i, "name": n} for i, n in lists[backend]]}}}), flush=True)
EOF
ACP_MODE=$HOME/.fake-acp-mode ACP_CALLS=$HOME/.fake-acp-calls
cat > "$BIN/codex" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
    "login status") echo 'Logged in using ChatGPT' ;;
    "--version "*) echo 'codex-cli 0.171.0' ;;
    *) exit 2 ;;
esac
EOF
cat > "$BIN/codex-acp" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo '@agentclientprotocol/codex-acp 1.13.1'; exit 0; }
# The stock adapter's own Codex CLI answers the launcher's sign-in check for a supervisor on Codex.
[ "${1:-} ${2:-} ${3:-}" = 'cli login status' ] && { echo 'Logged in using ChatGPT'; exit 0; }
[ "$#" -gt 0 ] || exec python3 -I "$(dirname "$0")/acp-models-stub.py" codex
exit 0
EOF
# The partner runtime's own check loads its tool server with node.
mkdir -p "$BIN/node_modules/@modelcontextprotocol/sdk/server" "$BIN/node_modules/zod"
printf 'class McpServer {}\nmodule.exports = { McpServer };\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/server/mcp.js"
printf 'class StdioServerTransport {}\nmodule.exports = { StdioServerTransport };\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/server/stdio.js"
printf '{"name": "@modelcontextprotocol/sdk", "version": "0.0.0-stand-in"}\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/package.json"
printf 'module.exports = { z: {} };\n' > "$BIN/node_modules/zod/index.js"
printf '{"name": "zod", "version": "0.0.0-stand-in", "main": "index.js"}\n' > "$BIN/node_modules/zod/package.json"
NODE=$(command -v node 2>/dev/null || true)
[ -n "$NODE" ] || { echo 'node is needed for these tests (the discussion partner runtime runs on it)' >&2; exit 2; }
ln -s "$NODE" "$BIN/node"
# The launcher stand-in, named as the real one so team.sh finds it on PATH. It records, for each call,
# its arguments, its folder and the settings team.sh passes. A key is reported only as present or absent.
cat > "$BIN/run-buzz-acp.sh" <<'EOF'
#!/bin/bash
rec=${STANDIN_RECORD:-/dev/null}
{
    printf 'call: %s\n' "$*"
    printf 'cwd: %s\n' "$(pwd -P)"
    for v in RUN_BUZZ_ACP_KEY_FILE BUZZ_ACP_SYSTEM_PROMPT_FILE RUN_BUZZ_ACP_WORKDIR BUZZ_ACP_AGENT_COMMAND BUZZ_ACP_CONFIG CLAUDE_AGENT_ACP_PROTOCOL CLAUDE_CODE_EFFORT_LEVEL BUZZ_WALL_PROJECT BUZZ_WALL_READ BUZZ_ACP_PERMISSION_MODE; do
        printf '%s=%s\n' "$v" "${!v-unset}"
    done
    if [ -n "${BUZZ_PRIVATE_KEY+x}" ]; then printf 'inherited-key: yes\n'; else printf 'inherited-key: no\n'; fi
} >> "$rec"
echo "stand-in launcher: args $*"
[ -f ./.env.buzz-acp.local ] || { echo "stand-in launcher: no env file in $(pwd)" >&2; exit 2; }
# The skill's own start passes no paths (the real launcher reads them from the settings file).
if [ "${STANDIN_SKIP_PATHS:-}" != yes ]; then
[ -r "${RUN_BUZZ_ACP_KEY_FILE:-/nonexistent}" ] || { echo 'stand-in launcher: the key file it was given cannot be read' >&2; exit 2; }
[ -r "${BUZZ_ACP_SYSTEM_PROMPT_FILE:-/nonexistent}" ] || { echo 'stand-in launcher: the prompt file it was given cannot be read' >&2; exit 2; }
[ -d "${RUN_BUZZ_ACP_WORKDIR:-/nonexistent}" ] || { echo 'stand-in launcher: the project folder it was given is missing' >&2; exit 2; }
fi
case ${1:-} in
    --check) [ "${STANDIN_CHECK_FAIL:-}" != yes ] || { echo 'stand-in launcher: not signed in by subscription' >&2; exit 1; }; echo 'stand-in launcher: check passed'; exit 0 ;;
    --run) exec buzz-acp ;;
    *) echo "stand-in launcher: unexpected arguments: $*" >&2; exit 2 ;;
esac
EOF
chmod 700 "$BIN"/buzz "$BIN"/buzz-acp "$BIN"/claude-agent-acp "$BIN"/codex "$BIN"/codex-acp "$BIN"/run-buzz-acp.sh
export STANDIN_RECORD=$OUT/launcher.rec
: > "$STANDIN_RECORD"
call_for() { awk -v want="cwd: $1" 'BEGIN { RS = "call: " } index($0, want) { last = $0 } END { printf "%s", last }' "$STANDIN_RECORD"; } # the last recorded call made in folder $1
last_call() { awk -v want="$1" '/^call: / { keep = (index($0, want) > 0); if (keep) buf = "" } keep { buf = buf $0 "\n" } END { printf "%s", buf }' "$STANDIN_RECORD"; } # the last recorded call whose arguments contain WANT

# A proof the setup script accepts without a signature check; its content is not a real authorization.
store_proof() { # TEAM AGENT
    printf '["auth","%s","","%s"]\n' "$OWNER" "$(printf 'ab%.0s' $(seq 1 64))" |
        /bin/bash "$SCRIPT" proof "$1" "$2" - --no-signature-check > "$OUT/proof-$1-$2.out" 2>&1
}

# ---------------------------------------------------------------- scenarios
scenario 'create puts the team command into the team folder'
run_skill create -- settings --keygen "$KEYGEN" --community "$COMMUNITY" --owner "$OWNER"
run_skill create -- create --workspace "$TD/ws/shop" --channel "$CHANNEL"
T=$ROOT/shop
check 'create succeeded' rc_is 0
check 'team.sh is in the team folder' test -f "$T/team.sh"
check 'it is the template, byte for byte' cmp -s "$TEMPLATE" "$T/team.sh"
check 'its mode is 700' test "$(mode_of "$T/team.sh")" = 700
check 'create names it' has "$OUT/create.out" "Team command: $T/team.sh"
check 'the next steps start with it' has "$OUT/create.out" "$T/team.sh check, then $T/team.sh"
hasnt "$TEMPLATE" 'skills/' && hasnt "$TEMPLATE" '.cc-switch' && hasnt "$TEMPLATE" 'CLAUDE_SKILL_DIR'
check 'the command names no skill folder' test $? = 0
run_skill create2 -- create --workspace "$TD/ws/shop" --channel "$CHANNEL"
check 'a second create keeps it' has "$OUT/create2.out" "Team command: $T/team.sh"
check 'and leaves it unchanged' cmp -s "$TEMPLATE" "$T/team.sh"
check 'the model list helper is in the team folder, the skill'"'"'s byte for byte, mode 700' test "$(cmp -s "$SKILL_DIR/scripts/acp-models.py" "$T/acp-models.py"; echo $?)$(mode_of "$T/acp-models.py")" = 0700
check 'each agent folder has its own start command, the template byte for byte' test "$(cmp -s "$START_TEMPLATE" "$T/assistant/start.sh"; echo $?)$(cmp -s "$START_TEMPLATE" "$T/supervisor/start.sh"; echo $?)" = 00
check 'its mode is 700' test "$(mode_of "$T/assistant/start.sh")$(mode_of "$T/supervisor/start.sh")" = 700700
check 'create names it' has "$OUT/create.out" "$T/<agent>/start.sh starts that agent only."
hasnt "$START_TEMPLATE" 'skills/' && hasnt "$START_TEMPLATE" '.cc-switch' && hasnt "$START_TEMPLATE" 'CLAUDE_SKILL_DIR'
check 'it names no skill folder' test $? = 0

scenario 'start refuses an agent without a proof, and names the fix'
run_team noproof "$T" -- start --all
check 'it fails' rc_is 1
check 'the check names the missing proof' has "$OUT/noproof.out" 'no ownership proof stored'
check 'nothing was started' has "$OUT/noproof.out" 'nothing was started'
check 'no pid file was written' test ! -e "$T/assistant/agent.pid"
store_proof shop assistant; store_proof shop supervisor

scenario 'check passes and starts nothing'
: > "$STANDIN_RECORD"
run_team check "$T" -- check
check 'it passes' rc_is 0
check 'it says so' has "$OUT/check.out" 'Check passed.'
check 'it found the launcher on PATH' has "$OUT/check.out" "$BIN/run-buzz-acp.sh"
check 'it lists buzz-acp and buzz' test "$(grep -c -E '^  ok +(buzz-acp|buzz) ' "$OUT/check.out")" = 2
check 'it names the project folder and why' has "$OUT/check.out" "$TD/ws/shop (the current folder)"
check 'it checks the partner runtime' has "$OUT/check.out" 'runtime/claude-agent-acp (restricted tools)'
check 'it checks the supervisor adapter' has "$OUT/check.out" "$BIN/claude-agent-acp"
check 'the launcher checked both agents' test "$(grep -c '^call: --check --backend claude$' "$STANDIN_RECORD")" = 2
check 'no agent runs' test ! -e "$T/assistant/agent.pid" -a ! -e "$T/supervisor/agent.pid"
run_team check-v "$T" -- check --verbose
check '--verbose shows the launcher output' has "$OUT/check-v.out" 'stand-in launcher: check passed'

scenario 'check names what is missing'
mkdir -p "$TD/nobin"
for c in buzz buzz-acp node; do ln -s "$BIN/$c" "$TD/nobin/$c"; done
RC=0; (cd -- "$RUN_CWD" && env PATH="$TD/nobin:/usr/bin:/bin" /bin/bash "$T/team.sh" check) > "$OUT/check-nobin.out" 2>&1 < /dev/null || RC=$?
check 'it fails without the launcher and the adapter' rc_is 1
check 'the launcher is marked MISSING' has "$OUT/check-nobin.out" 'run-buzz-acp.sh is not on PATH'
check 'the adapter is marked MISSING' test "$(grep -c -E '^  MISSING +claude-agent-acp' "$OUT/check-nobin.out")" = 1
check 'it counts the problems' has "$OUT/check-nobin.out" 'Check failed:'
run_team check-signin "$T" STANDIN_CHECK_FAIL=yes -- check
check 'a launcher refusal fails the check' rc_is 1
check 'and its reason is shown' has "$OUT/check-signin.out" 'not signed in by subscription'
run_team start-signin "$T" STANDIN_CHECK_FAIL=yes -- start --all
check 'start stops on a failed check' has "$OUT/start-signin.out" 'the check failed; nothing was started'
check 'and starts nothing' test ! -e "$T/assistant/agent.pid"

scenario 'start without a terminal starts every agent on its saved provider and model'
: > "$STANDIN_RECORD"
run_team start "$T" -- start
check 'it succeeds' rc_is 0
check 'the partner runs' alive "$T/assistant"
check 'the supervisor runs' alive "$T/supervisor"
check 'both were started on claude' test "$(grep -c '^call: --run --backend claude$' "$STANDIN_RECORD")" = 2
last_call '--run' > "$OUT/run-sup.rec"
check 'the launcher ran in the agent folder' has "$OUT/run-sup.rec" "cwd: $T/supervisor"
check 'it was given the key file of this folder' has "$OUT/run-sup.rec" "RUN_BUZZ_ACP_KEY_FILE=$T/supervisor/identity.key"
check 'and the prompt of this folder' has "$OUT/run-sup.rec" "BUZZ_ACP_SYSTEM_PROMPT_FILE=$T/supervisor/prompt.md"
check 'and the folder it was run from as the project folder' has "$OUT/run-sup.rec" "RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop"
check 'a stray exported key did not reach it' has "$OUT/run-sup.rec" 'inherited-key: no'
check 'the partner got its own runtime and rules' grep -q "BUZZ_ACP_AGENT_COMMAND=$T/assistant/runtime/claude-agent-acp" "$STANDIN_RECORD"
check 'and its subscription rules' grep -q "BUZZ_ACP_CONFIG=$T/assistant/subscriptions.toml" "$STANDIN_RECORD"
check 'the protocol default is passed' has "$OUT/run-sup.rec" 'CLAUDE_AGENT_ACP_PROTOCOL=v1'
check 'the pid file records the provider' test "$(sed -n '3p' "$T/supervisor/agent.pid")" = claude
run_team status "$T" -- status
check 'status shows both running' test "$(grep -c 'running on claude' "$OUT/status.out")" = 2
run_skill skill-status -- status shop
check 'the skill sees the same agents running' test "$(grep -c 'running on claude, PID' "$OUT/skill-status.out")" = 2
run_team start-again "$T" -- start
check 'a second start starts nothing new' test "$(grep -c 'already running' "$OUT/start-again.out")" = 2
run_team switch-running "$T" -- start supervisor --backend codex
check 'switching a running agent is refused' has "$OUT/switch-running.out" 'not codex; nothing was started'
P_SUP=$(pid_of "$T/supervisor")
run_team stop-one "$T" -- stop supervisor
check 'stop of one agent stops it' has "$OUT/stop-one.out" "supervisor: stopped (PID $P_SUP)"
check 'the other keeps running' alive "$T/assistant"
run_team stop "$T" -- stop
check 'stop stops the rest' has "$OUT/stop.out" 'assistant: stopped'
check 'nothing runs' test ! -e "$T/assistant/agent.pid" -a ! -e "$T/supervisor/agent.pid"

scenario 'provider and model per agent, by option'
: > "$STANDIN_RECORD"
run_team opts "$T" -- start --assistant-backend codex --supervisor-model claude-opus-5-5
check 'it succeeds' rc_is 0
check 'the partner was started on codex' grep -q '^call: --run --backend codex$' "$STANDIN_RECORD"
check 'the supervisor on claude with the chosen model' grep -q '^call: --run --backend claude --model claude-opus-5-5$' "$STANDIN_RECORD"
check 'the pid file records the model' test "$(sed -n '4p' "$T/supervisor/agent.pid")" = claude-opus-5-5
run_team opts-status "$T" -- status
check 'status shows the run provider' has "$OUT/opts-status.out" 'running on codex'
check 'and the run model' has "$OUT/opts-status.out" 'model claude-opus-5-5'
check 'beside the saved choice' has "$OUT/opts-status.out" 'saved: claude'
stop_all "$T"
run_team bad-model "$T" -- start supervisor --model not-a-claude-model
check 'a model the provider does not offer is refused' has "$OUT/bad-model.out" 'is not a Claude model'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
run_team bad-agent "$T" -- start auditor
check 'an unknown agent is refused' has "$OUT/bad-agent.out" 'unknown agent: auditor'
run_team absent-agent "$T" -- start reviewer
check 'an agent this team does not have is refused' has "$OUT/absent-agent.out" 'this team has no agent "reviewer"'

scenario 'in a terminal: which agents, then provider and model of each'
mkdir -p "$ROOT/models"
printf '# retrieved 2026-11-21T00:00:00Z stand-in\ndefault\tDefault (recommended)\nopus\tOpus 5.5\nsonnet\tSonnet 5.5\n' > "$ROOT/models/claude-supervisor.list"
printf '# retrieved 2026-11-21T00:00:00Z stand-in\ngpt-example-sol\tExample Sol\ngpt-example-astra\tExample Astra\n' > "$ROOT/models/codex-assistant.list"
: > "$STANDIN_RECORD"
# all agents; partner: codex, model number 2; supervisor: keep claude, model number 1 (opus: the
# list's first entry, default, is not offered)
ask_team ask-all "$T" '\n2\n2\n\n1\n\n' -- start
check 'it succeeds' rc_is 0
check 'the Claude menu leaves out default, which Claude Code refuses as a model name' hasnt "$OUT/ask-all.out" 'Default (recommended)'
check 'it asked which agents' has "$OUT/ask-all.out" 'Start which agents?'
check 'it asked each provider' test "$(grep -c ': provider?' "$OUT/ask-all.out")" = 2
check 'it asked each model' test "$(grep -c ': model on ' "$OUT/ask-all.out")" = 2
check 'it asked the effort of the Claude agent, and not where the list offers no level' test "$(grep -c ': reasoning effort on ' "$OUT/ask-all.out")" = 1
check 'it offered the retrieved list' has "$OUT/ask-all.out" 'gpt-example-astra'
check 'the partner started on codex with model 2' grep -q '^call: --run --backend codex --model gpt-example-astra$' "$STANDIN_RECORD"
check 'the supervisor started on claude with the first model offered' grep -q '^call: --run --backend claude --model opus$' "$STANDIN_RECORD"
stop_all "$T"
: > "$STANDIN_RECORD"
# only agent 2 (the supervisor); Enter keeps its provider and its model
ask_team ask-one "$T" '2\n\n\n\n' -- start
check 'choosing one agent starts only that one' test -e "$T/supervisor/agent.pid" -a ! -e "$T/assistant/agent.pid"
check 'Enter keeps the saved provider and model' grep -q '^call: --run --backend claude$' "$STANDIN_RECORD"
stop_all "$T"
ask_team ask-bad "$T" '2\n\n9\n' -- start
check 'a model number outside the list is refused' has "$OUT/ask-bad.out" 'no model number 9'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
ask_team ask-notlisted "$T" '2\n\nhaiku\n' -- start
check 'a model the retrieved list does not offer is refused' has "$OUT/ask-notlisted.out" 'is not a claude model offered for the supervisor'
: > "$STANDIN_RECORD"
run_team yes "$T" TEAM_SH_ASK=1 -- start --yes
check '--yes asks nothing' hasnt "$OUT/yes.out" 'provider?'
check 'and starts both on the saved choices' test "$(grep -c '^call: --run --backend claude$' "$STANDIN_RECORD")" = 2
stop_all "$T"

scenario 'each agent has its own start command: that agent only'
: > "$STANDIN_RECORD"
run_agent own-sup "$T" supervisor TEAM_SH_ASK=1 -- --yes
check 'it succeeds' rc_is 0
check '--yes asks nothing, in a terminal too' test "$(grep -c -e 'provider?' -e 'model on ' -e 'reasoning effort on ' -e 'Start which agents?' "$OUT/own-sup.out")" = 0
check 'the supervisor runs' alive "$T/supervisor"
check 'the partner was not started' test ! -e "$T/assistant/agent.pid"
check 'one agent was started, on its saved provider and model' test "$(grep -c '^call: --run' "$STANDIN_RECORD")$(grep -c '^call: --run --backend claude$' "$STANDIN_RECORD")" = 11
last_call '--run' > "$OUT/own-sup.rec"
check 'in the folder the command was run from' has "$OUT/own-sup.rec" "RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop"
check 'behind the wall, as a start by the team command is' has "$OUT/own-sup.rec" "BUZZ_ACP_AGENT_COMMAND=$T/wall/claude-agent-acp"
P_SUP=$(pid_of "$T/supervisor")
run_agent own-partner "$T" assistant --
check 'without a terminal it asks nothing either' test "$RC$(grep -c -e 'provider?' -e 'model on ' "$OUT/own-partner.out")" = 00
check 'the partner starts from its own folder' alive "$T/assistant"
check 'and the supervisor was left running, not started again' test "$(pid_of "$T/supervisor")" = "$P_SUP"
run_team own-status "$T" -- status
check 'status names each start command' test "$(grep -c "start it alone: $T/.*/start.sh" "$OUT/own-status.out")" = 2
stop_all "$T"
: > "$STANDIN_RECORD"
# in a terminal: this agent's provider (Enter), model (2: sonnet, of opus and sonnet) and effort (Enter)
ask_agent own-ask "$T" supervisor '\n2\n\n' --
check 'in a terminal it asks this agent'"'"'s provider, model and effort' test "$RC$(grep -c -e 'Supervisor (supervisor): provider?' -e 'Supervisor (supervisor): model on claude?' -e 'Supervisor (supervisor): reasoning effort on claude?' "$OUT/own-ask.out")" = 03
check 'and neither which agents nor another agent' test "$(grep -c -e 'Start which agents?' -e '(assistant):' "$OUT/own-ask.out")" = 0
check 'the chosen model starts that agent only' test "$(grep -c '^call: --run' "$STANDIN_RECORD")$(grep -c '^call: --run --backend claude --model sonnet$' "$STANDIN_RECORD")" = 11
stop_all "$T"
: > "$STANDIN_RECORD"
run_agent own-model "$T" supervisor -- --model claude-opus-5-5 --effort high
check 'a model and an effort for one run reach the launcher' grep -q '^call: --run --backend claude --model claude-opus-5-5$' "$STANDIN_RECORD"
check 'the effort too' test "$(sed -n '6p' "$T/supervisor/agent.pid")" = high
stop_all "$T"
: > "$STANDIN_RECORD"
run_agent own-check "$T" supervisor -- --check
check '--check checks that agent and starts nothing' test "$RC$(grep -c 'Check passed.' "$OUT/own-check.out")$(grep -c '^call: --run' "$STANDIN_RECORD")" = 010
check 'only that agent was checked' test "$(grep -c '^call: --check' "$STANDIN_RECORD")" = 1
for extra in assistant --all '--assistant-model opus' stop; do
    # shellcheck disable=SC2086
    run_agent own-extra "$T" supervisor -- $extra
    check "it takes no other agent or team option: $extra" test "$RC$(grep -c 'This command starts the supervisor only' "$OUT/own-extra.out")" = 11
done
check 'and nothing was started' test ! -e "$T/supervisor/agent.pid" -a ! -e "$T/assistant/agent.pid"
run_agent own-help "$T" supervisor -- --help
check 'help names the agent and how to stop it' test "$(grep -c -e 'start the supervisor of this folder' -e "$T/team.sh stop supervisor" "$OUT/own-help.out")" = 2
cp "$T/supervisor/start.sh" "$TD/elsewhere/start.sh"
RC=0; (cd -- "$RUN_CWD" && /bin/bash "$TD/elsewhere/start.sh") > "$OUT/own-moved.out" 2>&1 < /dev/null || RC=$?
check 'a copy outside an agent folder starts nothing' test "$RC$(grep -c 'must stay in its agent folder' "$OUT/own-moved.out")" = 11
rm -f "$TD/elsewhere/start.sh"

scenario 'the model menu shows what the provider offers now'
rm -f "$ACP_CALLS"
fn_body() { awk -v f="$2" '$0 ~ "^" f "\\(\\)" { on = 1 } on { print } on && /^}/ { exit }' "$1"; }
check 'the credential names removed first are the setup script'"'"'s, line for line' test -n "$(fn_body "$TEMPLATE" credential_name)" -a "$(fn_body "$TEMPLATE" credential_name)" = "$(fn_body "$SCRIPT" credential_name)"
LAUNCHER_SRC=$HERE/../../buzz-acp/run-buzz-acp.sh
if [ -f "$LAUNCHER_SRC" ]; then
    check 'and the launcher'"'"'s' test "$(fn_body "$TEMPLATE" credential_name | sed 1d)" = "$(fn_body "$LAUNCHER_SRC" credential_name | sed 1d)"
fi
KEPT=$ROOT/models/claude-supervisor.list
cp -p "$KEPT" "$TD/kept.list"
echo list > "$ACP_MODE"
: > "$STANDIN_RECORD"
# the supervisor: provider Enter; model 3 of the list retrieved now (opus, sonnet, claude-fable-5-2); effort Enter
ask_agent now-list "$T" supervisor '\n3\n\n' ANTHROPIC_API_KEY=example-not-a-key OPENAI_API_KEY=example-not-a-key CLAUDE_CODE_EXECUTABLE=/stray/claude --
check 'it succeeds' rc_is 0
check 'it says it asks the provider, with the bound' has "$OUT/now-list.out" 'asking claude which models it offers now (at most 3 s)'
check 'the menu offers a model the kept list did not have' has "$OUT/now-list.out" '[3] claude-fable-5-2'
check 'and still leaves out default' hasnt "$OUT/now-list.out" 'Default (recommended)'
check 'an ID with a space or a tab is left out' test "$(grep -c -e 'bad id' -e 'an ID with a space' "$OUT/now-list.out")" = 0
check 'the agent starts on the model chosen from it' grep -q '^call: --run --backend claude --model claude-fable-5-2$' "$STANDIN_RECORD"
check 'the list is kept where the earlier one was, mode 600' test "$(grep -c 'claude-fable-5-2' "$KEPT")$(mode_of "$KEPT")" = 1600
check 'with where it came from' test "$(sed -n '1p' "$KEPT" | grep -c "^# retrieved 20.*Z from $BIN/claude-agent-acp$")" = 1
check 'nothing is left beside it' test -z "$(ls -A "$ROOT/models" | grep -v -e '^claude-supervisor.list$' -e '^codex-assistant.list$')"
check 'the adapter was asked once, with no credential, agent key or stray executable' test "$(cat "$ACP_CALLS")" = 'call claude mode=list credential=no key=no exe=unset'
check 'no adapter is left running' test -z "$(pgrep -f "$BIN/acp-models-stub.py")"
stop_all "$T"
rm -f "$ACP_CALLS"
# the partner is asked through its own runtime
ask_agent now-partner "$T" assistant '\n1\n\n' --
check 'the partner'"'"'s list comes from its own runtime' test "$RC$(sed -n '1p' "$ROOT/models/claude-assistant.list" | grep -c "from $T/assistant/runtime/claude-agent-acp$")" = 01
check 'which runs the adapter with its restricted executable' has "$ACP_CALLS" "exe=$T/assistant/runtime/restricted-claude"
stop_all "$T"
rm -f "$ACP_CALLS"
: > "$STANDIN_RECORD"
run_agent now-yes "$T" supervisor TEAM_SH_ASK=1 -- --yes
run_team now-noterm "$T" -- start assistant
check 'a start that asks nothing retrieves nothing' test "$RC$(grep -c '^call: --run' "$STANDIN_RECORD")$(test -e "$ACP_CALLS"; echo $?)" = 021
stop_all "$T"
# a model given by option that the kept list does not offer: the provider is asked before a refusal
cp -p "$TD/kept.list" "$KEPT"
: > "$STANDIN_RECORD"
run_agent now-miss "$T" supervisor -- --model claude-fable-5-2
check 'a newer model than the kept list is looked up, then started' test "$RC$(grep -c '^call: --run --backend claude --model claude-fable-5-2$' "$STANDIN_RECORD")$(grep -c 'asking claude which models' "$OUT/now-miss.out")" = 011
stop_all "$T"
run_agent now-miss2 "$T" supervisor -- --model claude-haiku-5-5
check 'a model the provider does not offer now is still refused' test "$RC$(grep -c 'is not a claude model offered for the supervisor' "$OUT/now-miss2.out")" = 11
# the list cannot be retrieved: the reason, then the kept list
cp -p "$TD/kept.list" "$KEPT"
echo error > "$ACP_MODE"
: > "$STANDIN_RECORD"
ask_agent now-error "$T" supervisor '\n2\n\n' --
check 'a sign-in error is named' has "$OUT/now-error.out" 'not retrieved: the adapter could not open a session: not signed in'
check 'the kept list is offered, with its date' test "$(grep -c -e 'the list kept from 2026-11-21T00:00:00Z is used instead' -e '\[2\] sonnet' "$OUT/now-error.out")" = 2
check 'and the agent starts on the choice' test "$RC$(grep -c '^call: --run --backend claude --model sonnet$' "$STANDIN_RECORD")" = 01
check 'the kept list is unchanged' cmp -s "$TD/kept.list" "$KEPT"
stop_all "$T"
echo hang > "$ACP_MODE"
T0=$(date +%s); ask_agent now-hang "$T" supervisor '\n\n\n' --; T1=$(date +%s)
check 'an adapter that does not answer is given up at the bound' test "$RC$(grep -c 'not retrieved: the adapter did not answer within 3 s' "$OUT/now-hang.out")" = 01
check 'within a few seconds, and it is stopped' test $((T1 - T0)) -le 20 -a -z "$(pgrep -f "$BIN/acp-models-stub.py")"
check 'no half-written list is left' test -z "$(ls -A "$ROOT/models" | grep -e '^\.new-list')"
stop_all "$T"
echo list > "$ACP_MODE"
mv "$T/acp-models.py" "$TD/acp-models.py.keep"
ask_agent now-nohelper "$T" supervisor '\n\n\n' --
check 'a team folder without the helper says how to add it, and starts on the kept choices' test "$RC$(grep -c 'has no acp-models.py (add it with the skill' "$OUT/now-nohelper.out")" = 01
stop_all "$T"
mv "$TD/acp-models.py.keep" "$T/acp-models.py"
ask_agent now-nopython "$T" supervisor '\n\n\n' AGENT_TEAM_PYTHON=none --
check 'without python3 the kept list is used' test "$RC$(grep -c 'python3 is not on PATH' "$OUT/now-nopython.out")" = 01
stop_all "$T"
rm -f "$ACP_MODE" "$ACP_CALLS"
cp -p "$TD/kept.list" "$KEPT"

scenario 'a Claude agent is never started with the model "default"'
: > "$STANDIN_RECORD"
run_team default-opt "$T" -- start supervisor --model default
check 'default by option is refused' test "$RC$(grep -c '"default" names no model' "$OUT/default-opt.out")" = 11
run_agent default-own "$T" supervisor -- --model default
check 'and from the agent own start command' test "$RC$(grep -c '"default" names no model' "$OUT/default-own.out")" = 11
ask_team default-typed "$T" '2\n\ndefault\n' -- start
check 'and typed at the model question' test "$RC$(grep -c '"default" names no model' "$OUT/default-typed.out")" = 11
cp -p "$T/supervisor/agent.conf" "$TD/agent.conf.keep"
sed 's/^model_claude=.*/model_claude=default/' "$TD/agent.conf.keep" > "$T/supervisor/agent.conf"
run_agent default-saved "$T" supervisor --
check 'a saved default is refused, naming the fix' test "$RC$(grep -c 'the saved model of the supervisor is "default"' "$OUT/default-saved.out")$(grep -c 'agent-team.sh upgrade <team> --supervisor-model ID' "$OUT/default-saved.out")" = 111
run_team default-saved-check "$T" -- check supervisor
check 'and check says so too' test "$RC$(grep -c 'the saved model of the supervisor is "default"' "$OUT/default-saved-check.out")" = 11
run_agent default-saved-named "$T" supervisor -- --model claude-opus-5-5
check 'a named model for the run starts it all the same' test "$RC$(grep -c '^call: --run --backend claude --model claude-opus-5-5$' "$STANDIN_RECORD")" = 01
stop_all "$T"
cp -p "$TD/agent.conf.keep" "$T/supervisor/agent.conf"
check 'the launcher was never handed default' test "$(grep -c -e '--model default' "$STANDIN_RECORD")" = 0
run_skill default-upgrade -- upgrade shop --supervisor-model default --dry-run
check 'the skill does not save default for an agent' test "$RC$(grep -c '"default" names no model' "$OUT/default-upgrade.out")" = 11
run_skill default-settings -- settings --model default
check 'nor as the default model for new Claude agents' test "$RC$(grep -c '"default" names no model' "$OUT/default-settings.out")" = 11

scenario 'the project folder: the folder the command is run from, or --workspace'
: > "$STANDIN_RECORD"
RUN_CWD=$TD/ws/moved-shop
run_team ws-cwd "$T" -- check supervisor
check 'run from another folder, the check passes' rc_is 0
check 'that folder is the project folder' has "$OUT/ws-cwd.out" "$TD/ws/moved-shop (the current folder)"
check 'the launcher is given it' grep -q "^RUN_BUZZ_ACP_WORKDIR=$TD/ws/moved-shop\$" "$STANDIN_RECORD"
check 'it says which folder the team was created for' has "$OUT/ws-cwd.out" "this team was created for $TD/ws/shop"
check 'it notes a folder without a project record' has "$OUT/ws-cwd.out" 'has no PROJECT.md'
RUN_CWD=$TD/ws/shop
run_team ws-home "$T" -- check supervisor
check 'no such note in the folder that has one' hasnt "$OUT/ws-home.out" 'has no PROJECT.md'
: > "$STANDIN_RECORD"
RUN_CWD=$TD/ws/moved-shop
run_team ws-opt "$T" -- check supervisor --workspace "$TD/ws/shop"
check '--workspace wins over the current folder' has "$OUT/ws-opt.out" "$TD/ws/shop (--workspace)"
check 'and reaches the launcher' grep -q "^RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop\$" "$STANDIN_RECORD"
RUN_CWD=$TD/ws
run_team ws-rel "$T" -- check supervisor --workspace shop
check 'a relative --workspace is taken from the current folder' has "$OUT/ws-rel.out" "$TD/ws/shop (--workspace)"
: > "$STANDIN_RECORD"
for from in "$T" "$T/supervisor" "$ROOT"; do
    RUN_CWD=$from
    run_team ws-team "$T" -- check supervisor
    check "run from ${from#"$TD"/}: the saved folder is used, not that one" has "$OUT/ws-team.out" "$TD/ws/shop (saved in team.conf"
done
check 'the launcher never got a folder around the keys' test "$(grep -c "^RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop\$" "$STANDIN_RECORD")" = 3
RUN_CWD=$TD/ws/shop
for bad in "$T" "$T/assistant" "$ROOT" "$TD"; do
    run_team ws-bad "$T" -- start supervisor --workspace "$bad"
    check "--workspace ${bad#"$TOP"/} is refused" has "$OUT/ws-bad.out" 'cannot be the project folder'
done
check 'and nothing started' test ! -e "$T/supervisor/agent.pid"
run_team ws-none "$T" -- start supervisor --workspace "$TD/ws/nowhere"
check 'a --workspace that is not a folder is refused' has "$OUT/ws-none.out" 'not a folder'
: > "$STANDIN_RECORD"
run_team ws-a "$T" -- start assistant
check 'the partner starts in the current folder' rc_is 0
check 'its pid file records the folder' test "$(sed -n '5p' "$T/assistant/agent.pid")" = "$TD/ws/shop"
RUN_CWD=$TD/ws/moved-shop
run_team ws-split "$T" -- start supervisor
check 'the other agent cannot start in another folder' has "$OUT/ws-split.out" "assistant is running in $TD/ws/shop, not in $TD/ws/moved-shop"
check 'and is not started' test ! -e "$T/supervisor/agent.pid"
run_team ws-join "$T" -- start supervisor --workspace "$TD/ws/shop"
check 'it starts when given the same folder' rc_is 0
run_team ws-status "$T" -- status
check 'status shows the folder of both' test "$(grep -c "in $TD/ws/shop; PID" "$OUT/ws-status.out")" = 2
RUN_CWD=$TD/ws/shop
stop_all "$T"

scenario 'a moved team folder runs from its new place'
M=$TD/elsewhere/shop
cp -Rp "$T" "$M"
: > "$STANDIN_RECORD"
RUN_CWD=$TD/ws/moved-shop
run_team moved-check "$M" -- check
check 'the check passes in the new place' rc_is 0
check 'it notes that the settings file names the old place' has "$OUT/moved-check.out" "the settings file names $T/supervisor"
run_team moved-start "$M" -- start supervisor
check 'start succeeds there' rc_is 0
last_call '--run' > "$OUT/moved-run.rec"
check 'the launcher ran in the new folder' has "$OUT/moved-run.rec" "cwd: $M/supervisor"
check 'with the key file of the new folder' has "$OUT/moved-run.rec" "RUN_BUZZ_ACP_KEY_FILE=$M/supervisor/identity.key"
check 'and the prompt of the new folder' has "$OUT/moved-run.rec" "BUZZ_ACP_SYSTEM_PROMPT_FILE=$M/supervisor/prompt.md"
check 'and the folder it was run from as the project folder' has "$OUT/moved-run.rec" "RUN_BUZZ_ACP_WORKDIR=$TD/ws/moved-shop"
check 'the original folder was not started' test ! -e "$T/supervisor/agent.pid"
run_team moved-ws-running "$M" -- workspace "$TD/ws/moved-shop"
check 'the saved project folder cannot change while an agent runs' has "$OUT/moved-ws-running.out" 'is running; stop it first'
stop_all "$M"
# The folder saved at creation is gone on the "new machine": it matters only for a start from the team folder.
mv "$TD/ws/shop" "$TD/ws/shop-gone"
run_team moved-elsewhere "$M" -- check
check 'run from the project folder, a missing saved folder does not matter' rc_is 0
RUN_CWD=$M
run_team moved-nows "$M" -- check
check 'run from the team folder, the missing saved folder fails the check' rc_is 1
check 'with what to do' has "$OUT/moved-nows.out" 'go to the project folder and run this command from there, or pass --workspace DIR'
run_team moved-ws-bad "$M" -- workspace "$M/supervisor"
check 'an agent folder cannot be saved as the project folder' has "$OUT/moved-ws-bad.out" 'cannot be the project folder'
run_team moved-ws "$M" -- workspace "$TD/ws/moved-shop"
check 'workspace saves a new project folder' rc_is 0
check 'team.conf names it' grep -qx "workspace=$TD/ws/moved-shop" "$M/team.conf"
check 'the earlier record is kept' test "$(ls "$M" | grep -c '^team.conf.bak-')" = 1
check 'team.conf stays private' test "$(mode_of "$M/team.conf")" = 600
: > "$STANDIN_RECORD"
run_team moved-ws-check "$M" -- check
check 'the check from the team folder passes again' rc_is 0
check 'the launcher is given the saved folder' grep -q "RUN_BUZZ_ACP_WORKDIR=$TD/ws/moved-shop" "$STANDIN_RECORD"
# A team folder that was copied into its own project folder: the saved folder would hold the keys.
cp -p "$M/team.conf" "$TD/team.conf.keep"
sed "s|^workspace=.*|workspace=$TD/elsewhere|" "$TD/team.conf.keep" > "$M/team.conf"
run_team moved-around "$M" -- start supervisor
check 'a saved project folder around the team folder is refused too' has "$OUT/moved-around.out" 'cannot be used: it contains the team folder'
check 'and nothing starts' test ! -e "$M/supervisor/agent.pid"
cp -p "$TD/team.conf.keep" "$M/team.conf"
mv "$TD/ws/shop-gone" "$TD/ws/shop"
RUN_CWD=$TD/ws/moved-shop

scenario 'the real launcher takes the paths of the folder the team is in now'
REAL=${AGENT_TEAM_REAL_LAUNCHER:-}
if [ -z "$REAL" ]; then
    printf '  skip  set AGENT_TEAM_REAL_LAUNCHER=/path/to/run-buzz-acp.sh (it runs with --check only)\n'
else
    run_team real-check "$M" AGENT_TEAM_LAUNCHER="$REAL" -- check --verbose
    check 'the real launcher accepts the moved team' rc_is 0
    check 'it is the launcher that was checked with' has "$OUT/real-check.out" "$REAL"
    check 'it read the key file of the new folder' has "$OUT/real-check.out" "key file $M/supervisor/identity.key"
    check 'and the prompt of the new folder' has "$OUT/real-check.out" "file $M/supervisor/prompt.md"
    check 'and the saved project folder' has "$OUT/real-check.out" "$TD/ws/moved-shop"
    check 'the partner runs the runtime of the new folder' has "$OUT/real-check.out" "$M/assistant/runtime/claude-agent-acp"
    grep -E '(Agent key|Prompt|Runtime|Workspace):' "$OUT/real-check.out" | grep -qF "$T/"
    check 'no launcher line names the old folder' test $? != 0
    run_team real-model "$M" AGENT_TEAM_LAUNCHER="$REAL" -- check supervisor --model claude-opus-5-5 --verbose
    check 'a chosen model reaches the real launcher' has "$OUT/real-model.out" 'claude-opus-5-5 (ANTHROPIC_MODEL'
    run_team real-codex "$M" AGENT_TEAM_LAUNCHER="$REAL" -- check assistant --backend codex --verbose
    check 'a chosen provider switches the partner to its codex runtime' has "$OUT/real-codex.out" "$M/assistant/runtime/codex-acp"
fi

scenario 'an independent reviewer: a one-agent team of its own, in the same project folder and channel'
RUN_CWD=$TD/ws/shop
R=$ROOT/shop-reviewer
printf '# retrieved 2026-11-21T00:00:00Z stand-in\ngpt-example-sol\tExample Sol\ngpt-example-astra\tExample Astra\n' > "$ROOT/models/codex-reviewer.list"
run_skill rv-bad -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --name shop-reviewer --roles reviewer --reviewer-backend codex --reviewer-model gpt-not-offered
check 'a model the list does not offer is refused' has "$OUT/rv-bad.out" 'gpt-not-offered is not a codex model offered for the reviewer'
check 'and no reviewer folder is left' test ! -e "$R/reviewer"
run_skill rv -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --name shop-reviewer --roles reviewer --reviewer-name 'Shop Reviewer' --reviewer-backend codex --reviewer-model gpt-example-astra
check 'create succeeds' rc_is 0
check 'the team has one agent folder, reviewer' test "$(ls "$R" | tr '\n' ' ')" = 'acp-models.py reviewer team.conf team.sh wall '
check 'it has a key, a settings file and a prompt' test -s "$R/reviewer/identity.key" -a -s "$R/reviewer/.env.buzz-acp.local" -a -s "$R/reviewer/prompt.md"
check 'the key is private' test "$(mode_of "$R/reviewer/identity.key")" = 600
check 'its record names the role, backend and model' test "$(grep -c -x -e 'role=reviewer' -e 'backend=codex' -e 'model_codex=gpt-example-astra' -e 'name=Shop Reviewer' "$R/reviewer/agent.conf")" = 4
check 'it has the restricted runtime of its own' test -x "$R/reviewer/runtime/codex-acp" -a -x "$R/reviewer/runtime/claude-agent-acp" -a -x "$R/reviewer/runtime/buzz-tools" -a -x "$R/reviewer/runtime/restricted-claude"
check 'the runtime is the skill copy' cmp -s "$SKILL_DIR/runtime/codex-acp" "$R/reviewer/runtime/codex-acp"
E=$R/reviewer/.env.buzz-acp.local
check 'it runs that runtime, not the stock adapter' grep -qx "BUZZ_ACP_AGENT_COMMAND=$R/reviewer/runtime/codex-acp" "$E"
check 'it answers anyone' grep -qx 'BUZZ_ACP_RESPOND_TO=anyone' "$E"
check 'the harness adds no permission of its own' grep -qx 'BUZZ_ACP_PERMISSION_MODE=default' "$E"
grep -q -e 'bypass-permissions' -e 'BUZZ_ACP_SUBSCRIBE' -e 'BUZZ_ACP_CONFIG' -e 'owner-only' "$E"
check 'no supervisor rights and no every-message rules in its settings' test $? != 0
check 'it signs in by subscription only' grep -qx 'BUZZ_SIGN_IN=subscription' "$E"
check 'it has no subscription rules file' test ! -e "$R/reviewer/subscriptions.toml"
check 'its prompt is the reviewer prompt, with its name' test "$(sed -n '1p' "$R/reviewer/prompt.md")" = '# Shop Reviewer' -a "$(grep -c 'independent reviewer' "$R/reviewer/prompt.md")" -ge 1
check 'the prompt has no unfilled placeholder' hasnt "$R/reviewer/prompt.md" '{{'
check 'the team has its own command' cmp -s "$TEMPLATE" "$R/team.sh"
check 'create says which partner to refresh' has "$OUT/rv.out" 'the partner of workspace "shop" in this channel takes turns for these new agents until'
RV_KEY=$(sed -n 's/^pubkey=//p' "$R/reviewer/agent.conf")
check 'before that, the partner does not know the reviewer' hasnt "$T/assistant/subscriptions.toml" "$RV_KEY"
run_skill rv-refresh -- upgrade shop
check 'upgrading the first team refreshes the partner rules' has "$OUT/rv-refresh.out" 'subscriptions.toml'
check 'now the partner takes no turn for the reviewer' has "$T/assistant/subscriptions.toml" "$RV_KEY"
check 'the first team got no reviewer folder' test ! -e "$T/reviewer"
run_skill rv-status -- status shop-reviewer
check 'status lists the reviewer' has "$OUT/rv-status.out" 'reviewer: Shop Reviewer'
run_skill rv-again -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --name shop-reviewer --roles reviewer
check 'a second create keeps the reviewer and its key' has "$OUT/rv-again.out" 'reviewer: exists, kept identity.key agent.conf'
run_skill rv-up -- upgrade shop-reviewer
check 'upgrade finds the reviewer team up to date' has "$OUT/rv-up.out" 'up to date; nothing was changed'
run_team rv-noproof "$R" -- start
check 'the reviewer does not start without a proof' has "$OUT/rv-noproof.out" 'no ownership proof stored'
store_proof shop-reviewer reviewer
: > "$STANDIN_RECORD"
run_team rv-check "$R" -- check
check 'its check passes' rc_is 0
check 'the check covers its restricted runtime' has "$OUT/rv-check.out" 'runtime/codex-acp (restricted tools)'
check 'and names it' has "$OUT/rv-check.out" 'Shop Reviewer (reviewer): codex, model gpt-example-astra'
run_team rv-start "$R" -- start
check 'it starts' rc_is 0
check 'on codex, with the saved model left to the launcher' grep -q '^call: --run --backend codex$' "$STANDIN_RECORD"
check 'with its own runtime' grep -q "^BUZZ_ACP_AGENT_COMMAND=$R/reviewer/runtime/codex-acp\$" "$STANDIN_RECORD"
check 'in the folder it was run from' grep -q "^RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop\$" "$STANDIN_RECORD"
run_team rv-opt "$R" -- start reviewer --reviewer-backend claude
check 'a running reviewer is not switched to another provider' has "$OUT/rv-opt.out" 'not claude; nothing was started'
run_team rv-stop "$R" -- stop
check 'it stops' has "$OUT/rv-stop.out" 'reviewer: stopped'
if [ -n "${AGENT_TEAM_REAL_LAUNCHER:-}" ]; then
    run_team rv-real "$R" AGENT_TEAM_LAUNCHER="$AGENT_TEAM_REAL_LAUNCHER" -- check --verbose
    check 'the real launcher accepts the reviewer' rc_is 0
    check 'it reports the access and permission the reviewer runs with' test "$(grep -c -e 'BUZZ_ACP_RESPOND_TO=anyone' -e 'BUZZ_ACP_PERMISSION_MODE=default' "$OUT/rv-real.out")" = 2
    check 'and its own runtime' has "$OUT/rv-real.out" "$R/reviewer/runtime/codex-acp"
fi
stop_all "$R"

scenario 'reasoning effort: by option, asked, and saved'
RUN_CWD=$TD/ws/shop
printf '# retrieved 2026-11-21T00:00:00Z stand-in\ngpt-example-sol\tExample Sol\ngpt-example-astra\tExample Astra\ngpt-example-sol[low]\tExample Sol (low)\ngpt-example-sol[high]\tExample Sol (high)\n' > "$ROOT/models/codex-supervisor.list"
: > "$STANDIN_RECORD"
run_team ef-none "$T" -- start supervisor
last_call '--run' > "$OUT/ef-none.rec"
check 'with none set, the agent gets no effort variable' has "$OUT/ef-none.rec" 'CLAUDE_CODE_EFFORT_LEVEL=unset'
check 'and the check says none is set here' has "$OUT/ef-none.out" 'reasoning effort none set here'
stop_all "$T"
: > "$STANDIN_RECORD"
run_team ef-shell "$T" CLAUDE_CODE_EFFORT_LEVEL=low -- start supervisor
last_call '--run' > "$OUT/ef-shell.rec"
check 'with none set, a level exported by the shell is left as it is' has "$OUT/ef-shell.rec" 'CLAUDE_CODE_EFFORT_LEVEL=low'
check 'and the check says so' has "$OUT/ef-shell.out" 'this shell exports CLAUDE_CODE_EFFORT_LEVEL=low'
stop_all "$T"
: > "$STANDIN_RECORD"
run_team ef-opt "$T" CLAUDE_CODE_EFFORT_LEVEL=low -- start supervisor --effort high
check 'start with --effort succeeds' rc_is 0
last_call '--run' > "$OUT/ef-opt.rec"
check 'the chosen level reaches a Claude agent, over the shell one' has "$OUT/ef-opt.rec" 'CLAUDE_CODE_EFFORT_LEVEL=high'
check 'the model option is not touched on Claude' has "$OUT/ef-opt.rec" 'call: --run --backend claude'
check 'the pid file records the level' test "$(sed -n '6p' "$T/supervisor/agent.pid")" = high
check 'the start line names it' has "$OUT/ef-opt.out" 'reasoning effort high'
run_team ef-status "$T" -- status
check 'status shows the level of the run' has "$OUT/ef-status.out" 'reasoning effort high'
stop_all "$T"
run_team ef-bad "$T" -- start supervisor --effort ultra
check 'a level Claude does not offer is refused' has "$OUT/ef-bad.out" 'ultra is not a reasoning effort offered for the supervisor on claude'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
: > "$STANDIN_RECORD"
run_team ef-codex "$T" -- start supervisor --backend codex --model gpt-example-sol --effort high --no-wall
check 'on Codex the level goes into the model name' grep -q '^call: --run --backend codex --model gpt-example-sol\[high\]$' "$STANDIN_RECORD"
check 'and no Claude variable is set' has "$STANDIN_RECORD" 'CLAUDE_CODE_EFFORT_LEVEL=unset'
check 'the pid file records model and level' test "$(sed -n '4p' "$T/supervisor/agent.pid")" = 'gpt-example-sol[high]' -a "$(sed -n '6p' "$T/supervisor/agent.pid")" = high
stop_all "$T"
: > "$STANDIN_RECORD"
run_team ef-codex-name "$T" -- start supervisor --backend codex --model 'gpt-example-sol[low]' --no-wall
check 'a level written in the model name is kept' grep -q '^call: --run --backend codex --model gpt-example-sol\[low\]$' "$STANDIN_RECORD"
check 'and recorded as the level of the run' test "$(sed -n '6p' "$T/supervisor/agent.pid")" = low
stop_all "$T"
: > "$STANDIN_RECORD"
run_team ef-codex-both "$T" -- start supervisor --backend codex --model 'gpt-example-sol[low]' --effort high --no-wall
check '--effort wins over the level in the model name' grep -q '^call: --run --backend codex --model gpt-example-sol\[high\]$' "$STANDIN_RECORD"
stop_all "$T"
run_team ef-codex-nolevel "$T" -- start supervisor --backend codex --model gpt-example-astra --effort high --no-wall
check 'a level the list does not offer for that model is refused' has "$OUT/ef-codex-nolevel.out" 'high is not a reasoning effort offered for the supervisor on codex with gpt-example-astra'
run_team ef-codex-nomodel "$T" -- start supervisor --backend codex --effort high --no-wall
check 'on Codex a level without a model is refused' has "$OUT/ef-codex-nomodel.out" 'the supervisor needs a model too'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
: > "$STANDIN_RECORD"
# only the supervisor; keep its provider and model; effort number 3 (high)
ask_team ef-ask "$T" '2\n\n\n3\n' -- start
check 'in a terminal the effort is the third question' has "$OUT/ef-ask.out" 'Shop Supervisor (supervisor): reasoning effort on claude?'
check 'the picked level is used' grep -q '^CLAUDE_CODE_EFFORT_LEVEL=high$' "$STANDIN_RECORD"
stop_all "$T"
if [ -n "${AGENT_TEAM_REAL_LAUNCHER:-}" ]; then
    run_team ef-real "$T" AGENT_TEAM_LAUNCHER="$AGENT_TEAM_REAL_LAUNCHER" -- check supervisor --effort high --verbose
    check 'the real launcher accepts a Claude agent with a chosen effort' rc_is 0
    check 'and does not remove the effort variable' has "$OUT/ef-real.out" 'Removed:      none'
    run_team ef-real-codex "$T" AGENT_TEAM_LAUNCHER="$AGENT_TEAM_REAL_LAUNCHER" -- check supervisor --backend codex --model gpt-example-sol --effort high --verbose --no-wall
    check 'the real launcher accepts a Codex model name with a level' rc_is 0
    check 'and reports that name as the model it will run' grep -q 'Model: *gpt-example-sol\[high\]' "$OUT/ef-real-codex.out"
fi
# saved in the agent's record by the skill
run_skill ef-up-bad -- upgrade shop --supervisor-effort bogus
check 'the skill refuses a level that does not exist' has "$OUT/ef-up-bad.out" 'bogus is not a Claude reasoning effort'
run_skill ef-up-dry -- upgrade shop --dry-run --supervisor-effort xhigh
check 'the plan names the change' has "$OUT/ef-up-dry.out" 'reasoning effort (claude): none set here -> xhigh'
check 'a dry run saves nothing' hasnt "$T/supervisor/agent.conf" 'effort_'
run_skill ef-up -- upgrade shop --supervisor-effort xhigh
check 'upgrade saves it in the agent record' grep -qx 'effort_claude=xhigh' "$T/supervisor/agent.conf"
check 'the other agent has none' hasnt "$T/assistant/agent.conf" 'effort_'
run_skill ef-up2 -- upgrade shop
check 'a second upgrade keeps it and changes nothing' test "$(grep -c 'up to date; nothing was changed' "$OUT/ef-up2.out")" = 1 -a "$(grep -cx 'effort_claude=xhigh' "$T/supervisor/agent.conf")" = 1
run_skill ef-skill-status -- status shop
check 'the skill status shows it' has "$OUT/ef-skill-status.out" 'reasoning effort xhigh'
run_team ef-saved-status "$T" -- status
check 'the team status shows the saved level' has "$OUT/ef-saved-status.out" 'reasoning effort xhigh'
: > "$STANDIN_RECORD"
run_team ef-saved "$T" -- start supervisor
check 'a start without an option uses the saved level' grep -q '^CLAUDE_CODE_EFFORT_LEVEL=xhigh$' "$STANDIN_RECORD"
stop_all "$T"
: > "$STANDIN_RECORD"
ask_team ef-saved-ask "$T" '2\n\n\n\n' -- start
check 'in a terminal, Enter keeps the saved level' has "$OUT/ef-saved-ask.out" '[Enter] keep xhigh (saved)'
check 'and uses it' grep -q '^CLAUDE_CODE_EFFORT_LEVEL=xhigh$' "$STANDIN_RECORD"
stop_all "$T"
: > "$STANDIN_RECORD"
run_team ef-default "$T" -- start supervisor --supervisor-effort default
last_call '--run' > "$OUT/ef-default.rec"
check 'default sets none for one run, whatever is saved' has "$OUT/ef-default.rec" 'CLAUDE_CODE_EFFORT_LEVEL=unset'
stop_all "$T"
: > "$STANDIN_RECORD"
RC=0; env STANDIN_SKIP_PATHS=yes /bin/bash "$SCRIPT" start shop supervisor > "$OUT/ef-skill-start.out" 2>&1 < /dev/null || RC=$?
check 'the skill start applies the saved level too' grep -q '^CLAUDE_CODE_EFFORT_LEVEL=xhigh$' "$STANDIN_RECORD"
stop_all "$T"
run_skill ef-clear -- upgrade shop --supervisor-effort default
check 'default clears the saved level' hasnt "$T/supervisor/agent.conf" 'effort_'
# Codex: the reviewer team keeps its level in its record; both starts put it into the model name
printf 'gpt-example-astra[high]\tExample Astra (high)\n' >> "$ROOT/models/codex-reviewer.list"
run_skill ef-rv -- upgrade shop-reviewer --reviewer-effort high
check 'a Codex level is saved for the reviewer' grep -qx 'effort_codex=high' "$R/reviewer/agent.conf"
check 'its saved model stays the plain name' grep -qx 'model_codex=gpt-example-astra' "$R/reviewer/agent.conf"
: > "$STANDIN_RECORD"
run_team ef-rv-start "$R" -- start
check 'the team start puts the saved level into the model name' grep -q '^call: --run --backend codex --model gpt-example-astra\[high\]$' "$STANDIN_RECORD"
stop_all "$R"
: > "$STANDIN_RECORD"
RC=0; env STANDIN_SKIP_PATHS=yes /bin/bash "$SCRIPT" start shop-reviewer > "$OUT/ef-rv-skill.out" 2>&1 < /dev/null || RC=$?
check 'and so does the skill start' grep -q '^call: --run --backend codex --model gpt-example-astra\[high\]$' "$STANDIN_RECORD"
stop_all "$R"
run_skill ef-create -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --name shop-reviewer-two --roles reviewer --reviewer-name 'Shop Second Reviewer' --reviewer-backend codex --reviewer-model gpt-example-astra --reviewer-effort high
check 'create saves a level given at creation' grep -qx 'effort_codex=high' "$ROOT/shop-reviewer-two/reviewer/agent.conf"
run_skill ef-create-bad -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --name shop-reviewer-three --roles reviewer --reviewer-name 'Shop Third Reviewer' --reviewer-backend codex --reviewer-effort high
check 'create refuses a Codex level without a model' has "$OUT/ef-create-bad.out" 'needs a model too'
check 'and leaves no agent behind' test ! -e "$ROOT/shop-reviewer-three/reviewer"

scenario 'the workspace wall: every agent is held to the project folder'
RUN_CWD=$TD/ws/shop
check 'create put the wall files into the team folder' test -x "$T/wall/claude-agent-acp" -a -x "$T/wall/walled-claude" -a -x "$T/wall/bin/buzz"
cmp -s "$SKILL_DIR/wall/claude-agent-acp" "$T/wall/claude-agent-acp" && cmp -s "$SKILL_DIR/wall/walled-claude" "$T/wall/walled-claude" && cmp -s "$SKILL_DIR/wall/bin/buzz" "$T/wall/bin/buzz"
check 'they are the skill copies' test $? = 0
check 'the supervisor prompt tells it about the wall' has "$T/supervisor/prompt.md" 'your workspace is walled'
: > "$STANDIN_RECORD"
run_team wl-start "$T" -- start
check 'start succeeds' rc_is 0
call_for "$T/supervisor" > "$OUT/wl-sup.rec"; call_for "$T/assistant" > "$OUT/wl-ast.rec"
check 'the supervisor is started through the wall' has "$OUT/wl-sup.rec" "BUZZ_ACP_AGENT_COMMAND=$T/wall/claude-agent-acp"
check 'with the project folder as the wall' has "$OUT/wl-sup.rec" "BUZZ_WALL_PROJECT=$TD/ws/shop"
check 'and no permission mode from the harness' has "$OUT/wl-sup.rec" 'BUZZ_ACP_PERMISSION_MODE=default'
check 'the partner keeps its restricted runtime' has "$OUT/wl-ast.rec" "BUZZ_ACP_AGENT_COMMAND=$T/assistant/runtime/claude-agent-acp"
check 'and gets no wall settings' has "$OUT/wl-ast.rec" 'BUZZ_WALL_PROJECT=unset'
check 'the pid files record how each is held' test "$(sed -n '7p' "$T/supervisor/agent.pid")" = wall -a "$(sed -n '7p' "$T/assistant/agent.pid")" = runtime
check 'the check names the wall' has "$OUT/wl-start.out" "file tools and shell stop at $TD/ws/shop"
check 'and the partner runtime as its wall' has "$OUT/wl-start.out" 'its runtime reads only the project folder'
run_team wl-status "$T" -- status
check 'status shows the wall' test "$(grep -c 'behind the workspace wall' "$OUT/wl-status.out")" = 1 -a "$(grep -c 'held to the project folder by its runtime' "$OUT/wl-status.out")" = 1
stop_all "$T"
: > "$STANDIN_RECORD"
run_team wl-off "$T" -- start supervisor --no-wall
call_for "$T/supervisor" > "$OUT/wl-off.rec"
check '--no-wall starts the supervisor on the plain adapter' has "$OUT/wl-off.rec" 'BUZZ_ACP_AGENT_COMMAND=unset'
check 'and says so twice: in the check and after the start' test "$(grep -c -e 'NONE (--no-wall)' -e 'WITHOUT the workspace wall' "$OUT/wl-off.out")" = 2
check 'the pid file records it' test "$(sed -n '7p' "$T/supervisor/agent.pid")" = none
run_team wl-off-status "$T" -- status
check 'status shows it is not walled' has "$OUT/wl-off-status.out" 'NOT walled'
stop_all "$T"
run_team wl-codex "$T" -- start supervisor --backend codex --model gpt-example-sol
check 'a supervisor on Codex is refused, since it has no wall' has "$OUT/wl-codex.out" 'on codex this agent has no workspace wall'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
mkdir -p "$TD/ws/shop/.claude"
printf '{"permissions": {"additionalDirectories": ["/"]}}\n' > "$TD/ws/shop/.claude/settings.json"
run_team wl-widen "$T" -- start supervisor
check 'project settings that name more folders stop the start' has "$OUT/wl-widen.out" 'names more folders'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
rm -rf "$TD/ws/shop/.claude"
printf 'wall_read=/usr/local\n' >> "$T/team.conf"
: > "$STANDIN_RECORD"
run_team wl-read "$T" -- start supervisor
call_for "$T/supervisor" > "$OUT/wl-read.rec"
check 'more readable folders from team.conf reach the wall' has "$OUT/wl-read.rec" 'BUZZ_WALL_READ=/usr/local'
stop_all "$T"
grep -v '^wall_read=' "$T/team.conf" > "$TD/team.conf.tmp" && cat "$TD/team.conf.tmp" > "$T/team.conf"
: > "$STANDIN_RECORD"
RC=0; env STANDIN_SKIP_PATHS=yes /bin/bash "$SCRIPT" start shop supervisor > "$OUT/wl-skill-start.out" 2>&1 < /dev/null || RC=$?
call_for "$T/supervisor" > "$OUT/wl-skill.rec"
check 'the skill start puts the supervisor behind the wall too' test "$(grep -c -e "BUZZ_ACP_AGENT_COMMAND=$T/wall/claude-agent-acp" -e "BUZZ_WALL_PROJECT=$TD/ws/shop" -e 'BUZZ_ACP_PERMISSION_MODE=default' "$OUT/wl-skill.rec")" = 3
stop_all "$T"
mv "$T/wall" "$TD/wall-aside"
run_team wl-missing "$T" -- start supervisor
check 'without the wall files the supervisor does not start' has "$OUT/wl-missing.out" 'this team folder has no wall files'
check 'and nothing starts' test ! -e "$T/supervisor/agent.pid"
run_skill wl-up-dry -- upgrade shop --dry-run
check 'the upgrade plan names the missing wall files' test "$(grep -c -e 'wall/claude-agent-acp: add' -e 'wall/walled-claude: add' -e 'wall/bin/buzz: add' "$OUT/wl-up-dry.out")" = 3
run_skill wl-up -- upgrade shop
check 'upgrade puts them back' test -x "$T/wall/claude-agent-acp" -a -x "$T/wall/walled-claude" -a -x "$T/wall/bin/buzz"
printf '\n# edited\n' >> "$T/wall/walled-claude"
run_skill wl-up2 -- upgrade shop
check 'an edited wall file is replaced, the edited one kept beside it' test "$(cmp -s "$SKILL_DIR/wall/walled-claude" "$T/wall/walled-claude"; echo $?)" = 0 -a "$(ls "$T/wall" | grep -c '^walled-claude.bak-')" = 1
if [ -n "${AGENT_TEAM_REAL_LAUNCHER:-}" ]; then
    run_team wl-real "$T" AGENT_TEAM_LAUNCHER="$AGENT_TEAM_REAL_LAUNCHER" -- check supervisor --verbose
    check 'the real launcher accepts the walled supervisor' rc_is 0
    check 'it will run the wall as the runtime' grep -q "Runtime: *$T/wall/claude-agent-acp" "$OUT/wl-real.out"
    check 'and set no permission mode' has "$OUT/wl-real.out" 'BUZZ_ACP_PERMISSION_MODE=default'
fi

scenario 'upgrade adds or refreshes the team command'
rm -f "$T/team.sh"
run_skill up-dry -- upgrade shop --dry-run
check 'the plan names the missing command' has "$OUT/up-dry.out" 'team.sh: add'
check 'a dry run adds nothing' test ! -e "$T/team.sh"
run_skill up -- upgrade shop
check 'upgrade adds it' has "$OUT/up.out" 'team.sh: added'
check 'as the template, mode 700' test "$(mode_of "$T/team.sh")" = 700 -a "$(cmp -s "$TEMPLATE" "$T/team.sh"; echo $?)" = 0
run_skill up2 -- upgrade shop
check 'a second upgrade changes nothing' has "$OUT/up2.out" 'up to date; nothing was changed'
printf '\n# edited by hand\n' >> "$T/team.sh"
run_skill up3 -- upgrade shop
check 'an edited command is replaced' has "$OUT/up3.out" 'team.sh: replaced'
check 'and the edited one is kept beside it' test "$(ls "$T" | grep -c '^team.sh.bak-')" = 1
check 'the template is back' cmp -s "$TEMPLATE" "$T/team.sh"
rm -f "$T/supervisor/start.sh" "$T/acp-models.py"
printf '\n# edited by hand\n' >> "$T/assistant/start.sh"
run_skill up-start-dry -- upgrade shop --dry-run
check 'the plan names a missing and an edited start command' test "$(grep -c -e 'supervisor/start.sh: add' -e 'assistant/start.sh: replace' "$OUT/up-start-dry.out")" = 2
check 'and the missing model list helper' has "$OUT/up-start-dry.out" 'acp-models.py: add'
check 'a dry run adds nothing' test ! -e "$T/supervisor/start.sh"
run_skill up-start -- upgrade shop
check 'upgrade adds the one and replaces the other' test "$(grep -c -e 'supervisor/start.sh: added' -e 'assistant/start.sh: replaced' "$OUT/up-start.out")" = 2
check 'the model list helper is back' cmp -s "$SKILL_DIR/scripts/acp-models.py" "$T/acp-models.py"
check 'both are the template again, mode 700' test "$(cmp -s "$START_TEMPLATE" "$T/supervisor/start.sh"; echo $?)$(cmp -s "$START_TEMPLATE" "$T/assistant/start.sh"; echo $?)$(mode_of "$T/supervisor/start.sh")" = 00700
check 'the edited one is kept beside it' test "$(ls "$T/assistant" | grep -c '^start.sh.bak-')" = 1
run_skill up-start2 -- upgrade shop
check 'a second upgrade changes nothing' has "$OUT/up-start2.out" 'up to date; nothing was changed'

scenario 'help and unknown commands'
run_team help "$T" -- help
check 'help lists the commands' has "$OUT/help.out" 'team.sh check [AGENT...]'
run_team unknown "$T" -- restart
check 'an unknown command is refused' has "$OUT/unknown.out" 'unknown command: restart'

printf '\n%d scenarios, %d passed, %d failed\n' "$SCEN" "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
