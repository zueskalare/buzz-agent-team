#!/bin/bash
# test-agent-team.sh: offline scenario tests for the buzz-agent-team skill: its script
# (buzz-agent-team/scripts/agent-team.sh), its SKILL.md and the installer (install.sh). Bash 3.2+.
#
#   AGENT_TEAM_TEST_DIR=/abs/scratch/dir AGENT_TEAM_KEYGEN=/path/to/buzz-admin \
#   [AGENT_TEAM_REAL_LAUNCHER=/path/to/run-buzz-acp.sh] [AGENT_TEAM_REAL_BUZZ=/path/to/buzz] \
#     /bin/bash test-agent-team.sh
#
# Everything is written under AGENT_TEAM_TEST_DIR (its "run" folder is replaced on each run).
# HOME and the agents' root both point into it, so the installer and the script never see the
# real home folder.
# Keys are throwaway keys from the key generator. Nothing contacts a relay or community:
# finish and start use stand-ins for buzz and the launcher, written into the test folder.
# The real launcher, when given, runs only with --check; the real buzz, when given, only with --help.
# No secret key is printed: every comparison prints only pass or fail.

set -uo pipefail
umask 077

HERE=$(cd -P -- "$(dirname -- "$0")" && pwd)
SKILL_DIR=$HERE/buzz-agent-team
SCRIPT=$SKILL_DIR/scripts/agent-team.sh
INSTALLER=$HERE/install.sh
: "${AGENT_TEAM_TEST_DIR:?set AGENT_TEAM_TEST_DIR to an absolute scratch folder}"
: "${AGENT_TEAM_KEYGEN:?set AGENT_TEAM_KEYGEN to the buzz-admin binary (it runs generate-key only)}"
case $AGENT_TEAM_TEST_DIR in /*) ;; *) echo 'AGENT_TEAM_TEST_DIR must be absolute' >&2; exit 2 ;; esac
REAL_LAUNCHER=${AGENT_TEAM_REAL_LAUNCHER:-}
REAL_BUZZ=${AGENT_TEAM_REAL_BUZZ:-}
KEYGEN=$AGENT_TEAM_KEYGEN

mkdir -p -- "$AGENT_TEAM_TEST_DIR"
TOP=$(cd -P -- "$AGENT_TEAM_TEST_DIR" && pwd)
TD=$TOP/run
rm -rf -- "$TD"
mkdir -p -- "$TD"/{bin,out,keys,home,ws/shop,ws/api,ws/web,ws/docs,other/shop,inrepo}
OUT=$TD/out BIN=$TD/bin ROOT=$TD/root
# Git must not find a repository above the run folder, so roots here count as outside any work tree.
# Git never steps up into a ceiling directory, so the ceiling is the run folder's parent.
export GIT_CEILING_DIRECTORIES=$TOP
export HOME=$TD/home
unset CODEX_HOME CLAUDE_CONFIG_DIR AGENT_TEAM_INSTALL_FAULT
export AGENT_TEAM_ROOT=$ROOT AGENT_TEAM_KEYGEN=$KEYGEN
export AGENT_TEAM_BUZZ=$BIN/buzz AGENT_TEAM_LAUNCHER=$BIN/standin-launcher.sh
export FAKE_BUZZ_LOG=$OUT/buzz-calls.log
# Claude's managed settings: an empty folder, so the machine's own are never read by these tests.
export BUZZ_CLAUDE_MANAGED_DIR=$TD/managed-none
export PATH=$BIN:$PATH
# A stray exported agent key in the caller's shell must never reach an agent.
export BUZZ_PRIVATE_KEY=0000000000000000000000000000000000000000000000000000000000000001
unset AGENT_TEAM_TEMPLATES AGENT_TEAM_PYTHON CLAUDE_AGENT_ACP_PROTOCOL BUZZ_AUTH_TAG
CHANNEL=0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0
CHANNEL2=1c2d3e4f-5061-7283-94a5-b6c7d8e9f0a1
COMMUNITY=wss://community.example.org

PASS=0 FAIL=0 SKIP=0 SCEN=0 BG_PIDS=''
scenario() { SCEN=$((SCEN + 1)); printf '\n[S%d] %s\n' "$SCEN" "$1"; }
pass() { PASS=$((PASS + 1)); printf '  pass  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
sha() { shasum -a 256 "$@" | cut -c1-64; }
tree_sha() { (cd "$1" && find . -type f ! -name 'agent.log*' ! -name 'agent.pid' | LC_ALL=C sort | xargs shasum -a 256) | shasum -a 256 | cut -c1-64; }
alive() { kill -0 "$1" 2>/dev/null; }
key_is_hex() { local v r=0; IFS= read -r v < "$1" || true; [[ $v =~ ^[0-9a-f]{64}$ ]] || r=1; v=''; return "$r"; }

# run_tool NAME [VAR=value ...] -- ARGS...: output in $OUT/NAME.out, status in RC.
run_tool() {
    local name=$1 assigns=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    env ${assigns[@]+"${assigns[@]}"} /bin/bash "$SCRIPT" "$@" > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?
}
# run_stdin NAME INPUT [VAR=value ...] -- ARGS...
run_stdin() {
    local name=$1 input=$2 assigns=()
    shift 2
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    printf '%s\n' "$input" | env ${assigns[@]+"${assigns[@]}"} /bin/bash "$SCRIPT" "$@" > "$OUT/$name.out" 2>&1 || RC=$?
}
rc_is() { [ "$RC" = "$1" ]; }

# A throwaway key pair: the generator's output goes to a file, the secret to KEYFILE. Prints the public key.
new_keypair() { # KEYFILE
    local line raw=$1.gen pub=''
    "$KEYGEN" generate-key > "$raw" 2>/dev/null || return 1
    while IFS= read -r line; do
        case $line in
            'Secret key:'*) line=${line#Secret key:}; printf '%s\n' "${line//[[:space:]]/}" > "$1" ;;
            'Public key:'*) pub=${line#Public key:}; pub=${pub//[[:space:]]/} ;;
        esac
    done < "$raw"
    rm -f -- "$raw"
    printf '%s' "$pub"
}

# BIP-340 signer for test proofs (owner side). The owner's secret is read from a file, never an argument.
PYSIGN=$TD/sign.py
cat > "$PYSIGN" <<'PY'
import hashlib, os, sys
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
def xb(P): return P[0].to_bytes(32, "big")
mode = sys.argv[1]
d0 = int(open(sys.argv[2]).read().strip(), 16)
P = mul(G, d0)
if mode == "pub":
    print(xb(P).hex()); sys.exit(0)
agent_hex, cond = sys.argv[3], sys.argv[4]
msg = hashlib.sha256(("nostr:agent-auth:" + agent_hex + ":" + cond).encode()).digest()
d = d0 if P[1] % 2 == 0 else n - d0
t = (d ^ int.from_bytes(tagged("BIP0340/aux", os.urandom(32)), "big")).to_bytes(32, "big")
k0 = int.from_bytes(tagged("BIP0340/nonce", t + xb(P) + msg), "big") % n
R = mul(G, k0)
k = k0 if R[1] % 2 == 0 else n - k0
e = int.from_bytes(tagged("BIP0340/challenge", xb(R) + xb(P) + msg), "big") % n
sig = xb(R) + ((k + e * d) % n).to_bytes(32, "big")
print('["auth","%s","%s","%s"]' % (xb(P).hex(), cond, sig.hex()))
PY
sign() { python3 -I "$PYSIGN" sign "$1" "$2" "$3"; } # OWNER_KEYFILE AGENT_HEX CONDITIONS

# Stand-ins. buzz records its arguments and a hash of any agent key it was given; it contacts nothing.
cat > "$BIN/buzz" <<'EOF'
#!/bin/bash
{
    printf 'argv:'; printf ' [%s]' "$@"; printf '\n'
    if [ -n "${BUZZ_PRIVATE_KEY:-}" ]; then
        printf 'key-sha256: %s\n' "$(printf '%s' "$BUZZ_PRIVATE_KEY" | shasum -a 256 | cut -c1-64)"
    else printf 'key-sha256: none\n'; fi
    printf 'auth-tag: %s\n' "${BUZZ_AUTH_TAG:-none}"
} >> "$FAKE_BUZZ_LOG"
case " $* " in *" ${FAKE_BUZZ_FAIL:-no-such-subcommand} "*) echo '{"error":"auth_error","message":"stand-in failure"}' >&2; exit 3 ;; esac
echo '{"accepted":true,"stand_in":true}'
EOF
cat > "$BIN/buzz-acp" <<'EOF'
#!/bin/bash
mode=${FAKE_HARNESS_MODE:-normal}
echo "stand-in harness: pid $$ mode $mode"
[ "$mode" != fail-fast ] || { echo 'stand-in harness: failing on purpose' >&2; exit 4; }
if [ "$mode" = ignore-term ]; then trap '' TERM; else trap 'echo "stand-in harness: stopping"; exit 0' TERM INT; fi
i=0
while [ "$i" -lt 600 ]; do sleep 1 & wait $!; i=$((i + 1)); done
EOF
# Stand-ins for the two ACP adapters and the Codex CLI. Their sign-in state lives in files under the
# test HOME, as the real CLIs keep theirs under HOME / CLAUDE_CONFIG_DIR / CODEX_HOME. No model, no network.
cat > "$BIN/claude-agent-acp" <<'EOF'
#!/bin/bash
[ "$#" -gt 0 ] || exec python3 -I "$(dirname "$0")/acp-models-stub.py" claude
case "$*" in
    "--cli --help") echo '--restricted --tools --strict-mcp-config --disable-slash-commands'; exit 0 ;;
    "--cli env-check"*)   # which agent secrets reach the adapter's CLI (none may)
        for v in BUZZ_PRIVATE_KEY BUZZ_AUTH_TAG RUN_BUZZ_ACP_KEY_FILE; do [ -z "${!v+x}" ] || echo "leaked $v"; done
        echo 'env-check done'; exit 0 ;;
    "--cli auth status"*)
        m=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/fake-auth" 2>/dev/null || echo none)
        # As the real CLI reports it: an exported key or token outranks the subscription sign-in.
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then m=api_key; elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then m=oauth_token; fi
        if [ "$m" = none ]; then echo '{"loggedIn": false, "authMethod": "none"}'; exit 1; fi
        printf '{"loggedIn": true, "authMethod": "%s", "subscriptionType": "max"}\n' "$m"; exit 0 ;;
esac
exit 0
EOF
cat > "$BIN/codex" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
    "login status")
        if [ "$(cat "${CODEX_HOME:-$HOME/.codex}/fake-login" 2>/dev/null)" = chatgpt ]; then echo 'Logged in using ChatGPT'; else echo 'Not logged in'; exit 1; fi ;;
    "--version "*) echo 'codex-cli 0.171.0' ;;
    "debug models") echo '{"models": [{"slug": "gpt-example-sol", "visibility": "list"}, {"slug": "gpt-example-hidden", "visibility": "hide"}]}' ;;
    *) exit 2 ;;
esac
EOF
# The stock adapter as installed: a link into its package, which bundles an older Codex CLI.
CODEX_PKG=$TD/codex-acp-pkg
mkdir -p "$CODEX_PKG/dist" "$CODEX_PKG/node_modules/.bin"
cat > "$CODEX_PKG/dist/index.js" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo '@agentclientprotocol/codex-acp 1.13.1'; exit 0; }
if [ "${1:-}" = cli ]; then   # like the real adapter: its bundled Codex CLI
    shift; p=$0; while [ -L "$p" ]; do p=$(readlink "$p"); done
    exec "$(dirname "$(dirname "$p")")/node_modules/.bin/codex" "$@"
fi
[ "$#" -gt 0 ] || exec python3 -I "$(dirname "$0")/acp-models-stub.py" codex
exit 0
EOF
cat > "$CODEX_PKG/node_modules/.bin/codex" <<'EOF'
#!/bin/bash
# The Codex CLI the stock adapter bundles: an older catalog, the same sign-in store.
case "$1 ${2:-}" in
    "debug models") echo '{"models": [{"slug": "gpt-example-old", "visibility": "list"}]}' ;;
    "login status")
        if [ "$(cat "${CODEX_HOME:-$HOME/.codex}/fake-login" 2>/dev/null)" = chatgpt ]; then echo 'Logged in using ChatGPT'; else echo 'Not logged in'; exit 1; fi ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$CODEX_PKG/dist/index.js" "$CODEX_PKG/node_modules/.bin/codex"
ln -s "$CODEX_PKG/dist/index.js" "$BIN/codex-acp"
# An ACP stand-in that answers initialize and session/new the way the adapters report models.
# $HOME/.fake-acp-mode selects: list (default), list-no-opus, empty, error, hang, nomodels.
cat > "$BIN/acp-models-stub.py" <<'EOF'
import json, os, sys, time
backend = sys.argv[1]
try:
    mode = open(os.path.join(os.environ["HOME"], ".fake-acp-mode")).read().strip()
except OSError:
    mode = "list"
lists = {"claude": [("default", "Default (recommended)"), ("opus", "Opus 5.5"), ("sonnet", "Sonnet 5.5"), ("claude-opus-5-5", "Opus 5.5")],
         "codex": [("gpt-example-sol", "Example Sol"), ("gpt-example-sol[high]", "Example Sol high")]}
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
        if mode == "nomodels":
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s"}}), flush=True)
            continue
        entries = [] if mode == "empty" else [e for e in lists[backend] if not (mode == "list-no-opus" and e[0] == "claude-opus-5-5")]
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s", "models": {
            "currentModelId": entries[0][0] if entries else "default",
            "availableModels": [{"modelId": i, "name": n} for i, n in entries]}}}), flush=True)
EOF
# A minimal stand-in for the MCP SDK and zod, so the partner's buzz-tools --check-runtime can load.
mkdir -p "$BIN/node_modules/@modelcontextprotocol/sdk/server" "$BIN/node_modules/zod"
printf 'class McpServer {}\nmodule.exports = { McpServer };\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/server/mcp.js"
printf 'class StdioServerTransport {}\nmodule.exports = { StdioServerTransport };\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/server/stdio.js"
printf '{"name": "@modelcontextprotocol/sdk", "version": "0.0.0-stand-in"}\n' > "$BIN/node_modules/@modelcontextprotocol/sdk/package.json"
printf 'module.exports = { z: {} };\n' > "$BIN/node_modules/zod/index.js"
printf '{"name": "zod", "version": "0.0.0-stand-in", "main": "index.js"}\n' > "$BIN/node_modules/zod/package.json"
# The partner runtime's own check runs buzz-tools with node; the tests need node, as a partner does.
NODE=$(command -v node 2>/dev/null || true)
[ -n "$NODE" ] || { echo 'node is needed for these tests (the discussion partner runtime runs on it)' >&2; exit 2; }
ln -s "$NODE" "$BIN/node"
mkdir -p "$HOME/.claude" "$HOME/.codex"
echo claude.ai > "$HOME/.claude/fake-auth"
echo chatgpt > "$HOME/.codex/fake-login"
cat > "$BIN/standin-launcher.sh" <<'EOF'
#!/bin/bash
# Stand-in for run-buzz-acp.sh: --check validates nothing; --run records its environment and execs the stand-in harness.
echo "stand-in launcher: args $*"
case ${1:-} in
    --check) echo "stand-in launcher: check in $(pwd)"; [ -f ./.env.buzz-acp.local ]; exit $? ;;
    --run) ;;
    *) echo "stand-in launcher: unexpected arguments: $*" >&2; exit 2 ;;
esac
[ -f ./.env.buzz-acp.local ] || { echo "stand-in launcher: no env file in $(pwd)" >&2; exit 2; }
echo "stand-in launcher: cwd $(pwd)"
echo "stand-in launcher: CLAUDE_AGENT_ACP_PROTOCOL=${CLAUDE_AGENT_ACP_PROTOCOL:-unset}"
if [ -n "${BUZZ_PRIVATE_KEY+x}" ]; then echo 'stand-in launcher: inherited BUZZ_PRIVATE_KEY=yes'; else echo 'stand-in launcher: inherited BUZZ_PRIVATE_KEY=no'; fi
exec buzz-acp
EOF
cat > "$BIN/slow-keygen" <<'EOF'
#!/bin/bash
echo 'Public key:  abababababababababababababababababababababababababababababababab'
exec sleep 30
EOF
printf '#!/bin/bash\necho "stand-in generator failure" >&2\nexit 7\n' > "$BIN/failing-keygen"
printf '#!/bin/bash\necho "no keys here"\n' > "$BIN/empty-keygen"
chmod 700 "$BIN"/buzz "$BIN"/buzz-acp "$BIN"/claude-agent-acp "$BIN"/codex "$BIN"/codex-acp "$BIN"/standin-launcher.sh "$BIN"/slow-keygen "$BIN"/failing-keygen "$BIN"/empty-keygen
: > "$FAKE_BUZZ_LOG"
LAUNCHER_SHA_BEFORE=''
[ -z "$REAL_LAUNCHER" ] || LAUNCHER_SHA_BEFORE=$(sha "$REAL_LAUNCHER")

KEYS_CHECKED=''
key_of() { printf '%s/%s/%s/identity.key' "$ROOT" "$1" "$2"; }
# yes when no secret key under ROOT appears in any of FILES
no_key_in() {
    local k v f
    for k in "$TD"/root*/*/*/identity.key "$TD"/keys/*.key; do
        [ -f "$k" ] || continue
        IFS= read -r v < "$k"
        for f in "$@"; do
            [ -f "$f" ] || continue
            if grep -qF -- "$v" "$f"; then v=''; return 1; fi
        done
    done
    v=''
}

echo "agent-team.sh offline tests"
echo "script:   $SCRIPT"
echo "test dir: $TD"
echo "bash:     $BASH_VERSION"

# --------------------------------------------------------------------------------------------
scenario 'Static checks: syntax of the script and this test (bash -n)'
check 'bash -n agent-team.sh' /bin/bash -n "$SCRIPT"
check 'bash -n test-agent-team.sh' /bin/bash -n "$0"
check 'bash -n install.sh' /bin/bash -n "$INSTALLER"
check 'agent-team.sh is delivered executable' test -x "$SCRIPT"
check 'install.sh is delivered executable' test -x "$INSTALLER"
RC=0
"$SCRIPT" help > "$OUT/direct-help.out" 2>&1 || RC=$?
check 'agent-team.sh runs when called directly (as README and the skill do)' eval 'rc_is 0 && grep -q "^Usage: agent-team.sh" "$OUT/direct-help.out"'
if command -v shellcheck >/dev/null 2>&1; then skip 'shellcheck is installed but not part of this run'; else skip 'shellcheck is not installed (not run)'; fi

scenario 'No here-document or here-string can carry a secret key (C3)'
# Bash keeps here-document and here-string text in short-lived files under $TMPDIR. Each use below was
# reviewed: none carries a key. A new use fails this test until it is reviewed and listed here.
# HD is built from two pieces so that this file's own checks are not counted as uses.
HD='<''<'
TEST_FILE=$HERE/$(basename "$0")
hd_uses() { grep -- "$HD" "$1" | sed 's/^[[:space:]]*//'; }
{
    printf '%s\n' "IFS=, read -r -a fields $HD< \"\$inner,\""        # proof fields (public)
    printf '%s\n' "IFS='&' read -r -a clauses $HD< \"\$c\""           # proof conditions (public)
    printf '%s\n' "\"\$py\" -I - \"\$@\" $HD'PY' || status=\$?"        # verifier source code (literal)
    printf '%s\n' "IFS='&' read -r -a clauses $HD< \"\$PROOF_COND\""  # proof conditions (public)
    printf '%s\n' "cat $HD'EOF'"                                       # usage text (literal)
    printf '%s\n' "done ${HD}EOF" "done ${HD}EOF"                      # peer names (public)
} > "$OUT/hd-expected-script.txt"
hd_uses "$SCRIPT" > "$OUT/hd-found-script.txt"
hd_expanding_bodies() { # the line after each expanding here-document start in agent-team.sh
    grep -A1 -- "^[[:space:]]*done ${HD}EOF\$" "$SCRIPT" | grep -v -- "$HD" | grep -v '^--$' | sed 's/^[[:space:]]*//' | sort -u
}
hd_script_keyless() { ! hd_uses "$SCRIPT" | grep -Eqi 'identity\.key|private_key|secret|keygen|\$\{?(k|v)([^a-z0-9_]|$)'; }
hd_test_no_herestrings() { ! grep -q -- "${HD}<" "$TEST_FILE"; }
hd_test_all_quoted() { [ -z "$(hd_uses "$TEST_FILE" | grep -v -- "${HD}'[A-Za-z]*'")" ]; }
check 'agent-team.sh: exactly the 7 reviewed uses (proof fields, conditions twice, verifier code, usage text, peer names twice)' \
    cmp -s "$OUT/hd-expected-script.txt" "$OUT/hd-found-script.txt"
check 'agent-team.sh: each expanding here-document carries only the peer names' eval '[ "$(hd_expanding_bodies)" = "\$peers" ]'
check 'agent-team.sh: no use mentions a key file, key variable or key generator' hd_script_keyless
check 'test script: no here-strings' hd_test_no_herestrings
check 'test script: every here-document is quoted (literal text, cannot carry a runtime key)' hd_test_all_quoted
check 'install.sh: no here-strings, and its one here-document is the quoted help text' \
    eval '! grep -q -- "${HD}<" "$INSTALLER" && [ "$(hd_uses "$INSTALLER")" = "cat ${HD}'"'"'EOF'"'"'" ]'

scenario 'Throwaway owner keys and the test signer'
OWNER=$(new_keypair "$TD/keys/owner.key")
OWNER2=$(new_keypair "$TD/keys/owner2.key")
check 'owner public key is 64 hex' eval '[[ $OWNER =~ ^[0-9a-f]{64}$ ]]'
check 'the signer derives the generator'"'"'s public key from its secret' eval '[ "$(python3 -I "$PYSIGN" pub "$TD/keys/owner.key")" = "$OWNER" ]'

scenario 'The default root is ~/.buzz-agents; nothing is created by status (C1)'
RC=0
env -u AGENT_TEAM_ROOT HOME="$TD/home" /bin/bash "$SCRIPT" status > "$OUT/default-root.out" 2>&1 || RC=$?
check 'status exits 0' rc_is 0
RC_ROOT=$(head -n 1 "$OUT/default-root.out")
check 'root resolves to $HOME/.buzz-agents' eval '[ "$RC_ROOT" = "Root: $TD/home/.buzz-agents" ]'
check 'status created no root folder' eval '[ ! -e "$TD/home/.buzz-agents" ]'

scenario 'A root inside a Git work tree is refused (C1)'
INREPO=$TD/inrepo
if (cd "$INREPO" && env -u GIT_CEILING_DIRECTORIES git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    REPO_NOTE='the work tree that contains the test folder'
else
    git init -q "$INREPO" && REPO_NOTE='a work tree made for this test'
fi
RC=0
env -u GIT_CEILING_DIRECTORIES AGENT_TEAM_ROOT="$INREPO/agents" /bin/bash "$SCRIPT" create --workspace "$TD/ws/shop" \
    --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" > "$OUT/root-in-git.out" 2>&1 || RC=$?
check "refused in $REPO_NOTE (exit 1)" rc_is 1
check 'message names the Git work tree' has "$OUT/root-in-git.out" 'inside the Git work tree'
check 'nothing was created' eval '[ ! -e "$INREPO/agents" ]'

scenario 'A root inside the workspace is refused (C1)'
run_tool root-in-ws AGENT_TEAM_ROOT="$TD/ws/shop/.agents" -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'refused (exit 1)' rc_is 1
check 'message says keys stay out of the workspace' has "$OUT/root-in-ws.out" 'keys must stay out of the workspace'
check 'nothing was written into the workspace' eval '[ -z "$(ls -A "$TD/ws/shop")" ]'

scenario 'Input checks: npub owner, bad channel, missing community'
run_tool bad-owner -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner npub1exampleexampleexample
check 'an npub owner is refused with the hex hint' eval 'rc_is 1 && has "$OUT/bad-owner.out" "an npub does not work"'
run_tool bad-channel -- create --workspace "$TD/ws/shop" --channel not-a-uuid --community "$COMMUNITY" --owner "$OWNER"
check 'a malformed channel ID is refused' eval 'rc_is 1 && has "$OUT/bad-channel.out" "channel UUID"'
run_tool no-community -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --owner "$OWNER"
check 'a missing community is refused' eval 'rc_is 1 && has "$OUT/no-community.out" "community address is required"'
check 'nothing was created by refused runs' eval '[ ! -e "$ROOT/shop" ]'

scenario 'A failing key generator leaves nothing behind (C2, rule 1)'
run_tool keygen-fails AGENT_TEAM_KEYGEN="$BIN/failing-keygen" -- create --workspace "$TD/ws/docs" --name kg-fail --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER"
check 'create exits 1' rc_is 1
check 'the generator failure is reported' has "$OUT/keygen-fails.out" 'the key generator failed (exit 7)'
check 'no agent folder exists' eval '[ ! -e "$ROOT/kg-fail/assistant" ] && [ ! -e "$ROOT/kg-fail/supervisor" ]'
check 'no temporary folder or lock is left' eval '[ -z "$(find "$ROOT/kg-fail" -name ".new-*" 2>/dev/null)" ] && [ ! -e "$ROOT/kg-fail/.lock" ]'
run_tool keygen-empty AGENT_TEAM_KEYGEN="$BIN/empty-keygen" -- create --workspace "$TD/ws/docs" --name kg-fail --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER"
check 'a generator that prints no key pair is refused' eval 'rc_is 1 && has "$OUT/keygen-empty.out" "printed no key pair"'

scenario 'create makes the default set (assistant and supervisor) (C1)'
run_tool create-shop -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'create exits 0' rc_is 0
for id in assistant supervisor; do
    h=$ROOT/shop/$id
    check "$id: folder mode 700" eval '[ "$(mode_of "$h")" = 700 ]'
    check "$id: identity.key mode 600" eval '[ "$(mode_of "$h/identity.key")" = 600 ]'
    check "$id: env file mode 600" eval '[ "$(mode_of "$h/.env.buzz-acp.local")" = 600 ]'
    check "$id: prompt.md present" test -s "$h/prompt.md"
    check "$id: secret key is 64 hex (compared in the shell)" key_is_hex "$h/identity.key"
    check "$id: public key printed" has "$OUT/create-shop.out" "$(grep '^pubkey=' "$h/agent.conf" | cut -d= -f2)"
done
check 'workspace and root folders mode 700' eval '[ "$(mode_of "$ROOT")" = 700 ] && [ "$(mode_of "$ROOT/shop")" = 700 ]'
check 'PROJECT.md is the only generated workspace file' eval '[ "$(ls -A "$TD/ws/shop")" = PROJECT.md ] && cmp "$TD/ws/shop/PROJECT.md" "$SKILL_DIR/templates/project.md"'
check 'next steps name the Buzz Desktop step' has "$OUT/create-shop.out" 'Authorize external identity'
check 'the two public keys differ' eval '[ "$(grep ^pubkey= "$ROOT/shop/assistant/agent.conf")" != "$(grep ^pubkey= "$ROOT/shop/supervisor/agent.conf")" ]'

scenario 'Secrets stay in identity.key only (C3)'
check 'no secret key in create output' no_key_in "$OUT/create-shop.out"
check 'no secret key in env files, prompts or records' no_key_in "$ROOT"/shop/*/.env.buzz-acp.local "$ROOT"/shop/*/prompt.md "$ROOT"/shop/*/agent.conf "$ROOT"/shop/team.conf
check 'env files do not set BUZZ_PRIVATE_KEY' eval '! grep -q "^BUZZ_PRIVATE_KEY=" "$ROOT"/shop/*/.env.buzz-acp.local'

scenario 'Env files hold only settings the launcher accepts (C4)'
for id in assistant supervisor; do
    f=$ROOT/shop/$id/.env.buzz-acp.local
    bad=$(grep -v '^#' "$f" | grep -v '^$' | cut -d= -f1 | grep -Ev '^(BUZZ_.*|ANTHROPIC_.*|OPENAI_.*|OPENROUTER_.*|GOOSE_.*|CODEX_.*|DATABRICKS_.*|RUN_BUZZ_ACP_KEY_FILE|RUN_BUZZ_ACP_WORKDIR|RUST_LOG)$' || true)
    check "$id: every key is launcher-accepted" eval '[ -z "$bad" ]'
    check "$id: no duplicate keys" eval '[ -z "$(grep -v "^#" "$f" | grep -v "^$" | cut -d= -f1 | sort | uniq -d)" ]'
    check "$id: workspace setting points at the workspace" has "$f" "RUN_BUZZ_ACP_WORKDIR=$TD/ws/shop"
done

scenario 'The accepted launcher checks each env file from the agent folder (C4, Q3)'
if [ -n "$REAL_LAUNCHER" ]; then
    for id in assistant supervisor; do
        h=$ROOT/shop/$id
        RC=0
        (cd "$h" && env -u BUZZ_PRIVATE_KEY "$REAL_LAUNCHER" --check) > "$OUT/check-$id.out" 2>&1 || RC=$?
        check "$id: launcher --check exits 0" rc_is 0
        check "$id: launcher sees the separate workspace" has "$OUT/check-$id.out" "Workspace:    $TD/ws/shop"
        check "$id: launcher uses the prompt file" has "$OUT/check-$id.out" "Prompt:       file $h/prompt.md"
        check "$id: launcher uses the key file, value hidden" has "$OUT/check-$id.out" "key file $h/identity.key (value hidden)"
    done
else
    skip 'AGENT_TEAM_REAL_LAUNCHER not set'
fi

scenario 'Generated roles, shared project knowledge and limited delivery permissions'
A=$ROOT/shop/assistant/prompt.md S=$ROOT/shop/supervisor/prompt.md
for f in "$A" "$S"; do
    check "role names resolved in $f" hasnt "$f" '{{'
    check 'prompt omits routing details' eval 'hasnt "$f" "$CHANNEL" && hasnt "$f" "$OWNER" && hasnt "$f" "$TD/ws/shop"'
    check 'prompt points to the shared record and personal memory' eval 'has "$f" PROJECT.md && has "$f" "own Buzz memory"'
done
check 'partner takes the project name' grep -qxF '# Shop' "$A"
check 'partner recognizes the supervisor' has "$A" "Shop Supervisor"
check 'supervisor recognizes the partner' has "$S" "Shop is the project’s discussion partner"
check 'partner decides when to speak' has "$A" "Stay silent"
check 'partner proposes todos in their Buzz thread' has "$A" "propose a todo in its Buzz thread"
check 'owner authorizes bounded work' has "$S" "Start workers only when the owner authorizes a bounded run"
check 'supervisor reviews worker evidence' has "$S" "review the returned report"
check 'supervisor owns tracker promotion' has "$S" "Promote an accepted proposal"
check 'supervisor checks the owner'"'"'s signature on an approval, relayed ones included' has "$S" "Verify the original message’s signed author against the configured owner before acting on an approval, including approvals relayed by the discussion partner."
for id in assistant supervisor; do
    check "$id uses its role prompt without conflicting built-in instructions" has "$ROOT/shop/$id/.env.buzz-acp.local" 'BUZZ_ACP_NO_BASE_PROMPT=true'
    check "$id loads its own Buzz memory" has "$ROOT/shop/$id/.env.buzz-acp.local" 'BUZZ_ACP_MEMORY=true'
done
ap=$ROOT/shop/assistant
check 'partner accepts events from all members' has "$ap/.env.buzz-acp.local" 'BUZZ_ACP_RESPOND_TO=anyone'
check 'partner uses its generated subscription rules' eval 'has "$ap/.env.buzz-acp.local" "BUZZ_ACP_SUBSCRIBE=config" && has "$ap/.env.buzz-acp.local" "BUZZ_ACP_CONFIG=$ap/subscriptions.toml"'
check 'partner starts through its restricted adapter, with no harness permission mode' eval 'has "$ap/.env.buzz-acp.local" "BUZZ_ACP_AGENT_COMMAND=$ap/runtime/claude-agent-acp" && has "$ap/.env.buzz-acp.local" "BUZZ_ACP_PERMISSION_MODE=default" && hasnt "$ap/.env.buzz-acp.local" "dont-ask"'
check 'supervisor responds to the owner' has "$ROOT/shop/supervisor/.env.buzz-acp.local" 'BUZZ_ACP_RESPOND_TO=owner-only'
# What the rules select, evaluated as the harness does (buzz-acp filter.rs match_event: rules in order,
# channel scope, kinds, a p tag naming the partner when require_mention, then the author filter).
SELECT=$TD/rules_select.py
cat > "$SELECT" <<'PY'
import re, sys
rules, cur = [], None
for raw in open(sys.argv[1]):
    line = raw.strip()
    if line == "[[rules]]":
        cur = {}; rules.append(cur); continue
    m = re.match(r'^(\w+)\s*=\s*(.*)$', line)
    if not m or cur is None:
        continue
    k, v = m.groups()
    if k == "name": cur[k] = v.strip('"')
    elif k == "channels": cur[k] = "all" if v == '"all"' else re.findall(r'"([^"]+)"', v)
    elif k == "kinds": cur[k] = [int(x) for x in re.findall(r"\d+", v)]
    elif k == "require_mention": cur[k] = v == "true"
    elif k == "filter": cur[k] = v[1:-1] if v.startswith("'") else v
def allowed(expr, author):
    if expr in (None, "true"):
        return True
    terms = expr.split(" && ")
    for t in terms:
        m = re.fullmatch(r'author != "([0-9a-f]{64})"', t)
        if not m:
            sys.exit("unsupported filter term: " + t)
        if author == m.group(1):
            return False
    return True
channel, kind, author, mentions, partner = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5].split(",") if sys.argv[5] else [], sys.argv[6]
for r in rules:
    if r["channels"] != "all" and channel not in r["channels"]: continue
    if r.get("kinds") and kind not in r["kinds"]: continue
    if r.get("require_mention") and partner not in mentions: continue
    if not allowed(r.get("filter"), author): continue
    print(r["name"]); sys.exit(0)
print("none")
PY
PK=$(grep '^pubkey=' "$ap/agent.conf" | cut -d= -f2) SK=$(grep '^pubkey=' "$ROOT/shop/supervisor/agent.conf" | cut -d= -f2)
STRANGER=1111111111111111111111111111111111111111111111111111111111111111 OTHERCH=9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a
sel() { python3 -I "$SELECT" "$ap/subscriptions.toml" "$@" "$PK"; }
check 'rules: a member'"'"'s ordinary message in the channel starts a turn' eval '[ "$(sel "$CHANNEL" 9 "$STRANGER" "")" = "Project discussion" ]'
check 'rules: an ordinary message in another channel does not' eval '[ "$(sel "$OTHERCH" 9 "$STRANGER" "")" = none ]'
check 'rules: a mention in another channel does' eval '[ "$(sel "$OTHERCH" 9 "$STRANGER" "$PK")" = "Direct mentions" ]'
check 'rules: a kind outside the channel rule needs a mention' eval '[ "$(sel "$CHANNEL" 40003 "$STRANGER" "")" = none ] && [ "$(sel "$CHANNEL" 40003 "$STRANGER" "$PK")" = "Direct mentions" ]'
check 'loop guard: the team'"'"'s supervisor posting in the channel starts no partner turn (T-9 R1)' eval '[ "$(sel "$CHANNEL" 9 "$SK" "")" = none ]'
check 'loop guard: nor does the supervisor mentioning the partner' eval '[ "$(sel "$CHANNEL" 9 "$SK" "$PK")" = none ] && [ "$(sel "$OTHERCH" 40002 "$SK" "$PK")" = none ]'
check 'rules: each filter names exactly the team'"'"'s other agent' eval '[ "$(grep -c "^filter = '"'"'author != \"$SK\"'"'"'$" "$ap/subscriptions.toml")" = 2 ]'

for tool in claude-agent-acp restricted-claude buzz-tools codex-acp; do
    check "installed runtime $tool is executable and matches the source" eval '[ "$(mode_of "$ap/runtime/$tool")" = 700 ] && cmp "$ap/runtime/$tool" "$SKILL_DIR/runtime/$tool"'
done
if [ -n "$REAL_BUZZ" ]; then
    for cmd in 'messages get' 'messages thread' 'messages search' 'messages send' 'canvas get' 'issues list' 'issues get' 'mem ls' 'mem get' 'mem set'; do
        check "Buzz CLI supports the partner operation: $cmd" "$REAL_BUZZ" $cmd --help >/dev/null
    done
fi

scenario 'Running create again changes nothing and reports what exists (C2)'
SHA_A=$(tree_sha "$ROOT/shop/assistant") SHA_S=$(tree_sha "$ROOT/shop/supervisor") SHA_T=$(sha "$ROOT/shop/team.conf")
printf '%s\n' 'An existing decision by the owner.' > "$TD/ws/shop/PROJECT.md"
run_tool create-again -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --model other-model
check 'second create exits 0' rc_is 0
check 'reports the kept files' has "$OUT/create-again.out" 'assistant: exists, kept identity.key agent.conf .env.buzz-acp.local prompt.md'
check 'assistant folder byte-identical' eval '[ "$(tree_sha "$ROOT/shop/assistant")" = "$SHA_A" ]'
check 'supervisor folder byte-identical' eval '[ "$(tree_sha "$ROOT/shop/supervisor")" = "$SHA_S" ]'
check 'team record byte-identical' eval '[ "$(sha "$ROOT/shop/team.conf")" = "$SHA_T" ]'
check 'no secret key in the output' no_key_in "$OUT/create-again.out"

check 'existing project record is preserved' grep -qxF 'An existing decision by the owner.' "$TD/ws/shop/PROJECT.md"
rm -- "$ap/runtime/buzz-tools"
run_tool restore-runtime -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'a missing partner tool is restored with the original identity' eval 'rc_is 0 && [ "$(tree_sha "$ap")" = "$SHA_A" ]'

scenario 'An existing legacy team keeps its identity, routing and role on repair'
legacy=$TD/legacy
mkdir -p "$legacy/shop"
cp -R "$ROOT/shop/." "$legacy/shop/"
for record in "$legacy/shop/team.conf" "$legacy/shop/"*/agent.conf; do
    sed 's/^format=2$/format=1/' "$record" > "$record.new" && mv "$record.new" "$record"
done
rm -r "$legacy/shop/assistant/runtime"
rm "$legacy/shop/assistant/subscriptions.toml" "$legacy/shop/assistant/.env.buzz-acp.local" "$legacy/shop/assistant/prompt.md"
SHA_LEG=$(tree_sha "$legacy/shop")
run_tool repair-legacy AGENT_TEAM_ROOT="$legacy" -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'create refuses a format-1 team, names upgrade, rebuilds no prompt (no T-7 prompt)' eval 'rc_is 1 && has "$OUT/repair-legacy.out" "upgrade shop" && [ ! -e "$legacy/shop/assistant/prompt.md" ] && [ "$(tree_sha "$legacy/shop")" = "$SHA_LEG" ]'
run_tool legacy-start AGENT_TEAM_ROOT="$legacy" -- start shop --check
check 'start refuses a format-1 team' eval 'rc_is 1 && has "$OUT/legacy-start.out" "format 1"'
cp "$ap/prompt.md" "$legacy/shop/assistant/prompt.md"
printf 'BUZZ_RELAY_URL=%s\nBUZZ_ACP_AGENT_OWNER=%s\nBUZZ_AUTH_TAG=["auth","%s","created_at<9999999999","%0128d"]\nANTHROPIC_BASE_URL=https://gateway.example.org\nBUZZ_ACP_MODEL=claude-sonnet-4-5\nBUZZ_ACP_AGENT_COMMAND=claude-agent-acp\n' "$COMMUNITY" "$OWNER" "$OWNER" 9 > "$legacy/shop/assistant/.env.buzz-acp.local"
LEG_TAG=$(grep '^BUZZ_AUTH_TAG=' "$legacy/shop/assistant/.env.buzz-acp.local")
/bin/sleep 60 & SLEEPER=$!
printf '%s\n%s\nclaude\n' "$SLEEPER" "$(ps -o lstart= -p "$SLEEPER" | sed 's/^ *//;s/ *$//')" > "$legacy/shop/supervisor/agent.pid"
SHA_LEG=$(tree_sha "$legacy/shop")
run_tool upgrade-running AGENT_TEAM_ROOT="$legacy" -- upgrade shop
check 'upgrade refuses while an agent runs and changes nothing' eval 'rc_is 1 && has "$OUT/upgrade-running.out" "supervisor is running" && [ "$(tree_sha "$legacy/shop")" = "$SHA_LEG" ]'
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; rm -f "$legacy/shop/supervisor/agent.pid"
SHA_LEG=$(tree_sha "$legacy/shop")
run_tool upgrade-dry AGENT_TEAM_ROOT="$legacy" -- upgrade shop --dry-run
check 'upgrade --dry-run prints the plan and changes nothing' eval 'rc_is 0 && has "$OUT/upgrade-dry.out" "format 1 -> 2" && has "$OUT/upgrade-dry.out" "ANTHROPIC_BASE_URL" && hasnt "$OUT/upgrade-dry.out" "gateway.example.org" && [ "$(tree_sha "$legacy/shop")" = "$SHA_LEG" ]'
run_tool upgrade-1 AGENT_TEAM_ROOT="$legacy" -- upgrade shop --supervisor-backend codex
LA=$legacy/shop/assistant
check 'upgrade: format 2, keys and proof byte-identical, no gateway, backups beside the files' eval 'rc_is 0 && grep -qx format=2 "$legacy/shop/team.conf" && grep -qx format=2 "$LA/agent.conf" && cmp "$LA/identity.key" "$ap/identity.key" && grep -qxF "$LEG_TAG" "$LA/.env.buzz-acp.local" && hasnt "$LA/.env.buzz-acp.local" ANTHROPIC_ && has "$LA/.env.buzz-acp.local" BUZZ_SIGN_IN=subscription && ls "$LA"/.env.buzz-acp.local.bak-* >/dev/null && [ -x "$LA/runtime/codex-acp" ]'
check 'upgrade: the chosen backend is saved for the supervisor' eval 'grep -qx backend=codex "$legacy/shop/supervisor/agent.conf" && has "$legacy/shop/supervisor/.env.buzz-acp.local" "BUZZ_ACP_AGENT_COMMAND=codex-acp"'
SHA_LEG=$(tree_sha "$legacy/shop")
run_tool upgrade-2 AGENT_TEAM_ROOT="$legacy" -- upgrade shop
check 'a second upgrade changes nothing' eval 'rc_is 0 && has "$OUT/upgrade-2.out" "up to date" && [ "$(tree_sha "$legacy/shop")" = "$SHA_LEG" ]'
run_tool upgrade-kill AGENT_TEAM_ROOT="$legacy" AGENT_TEAM_UPGRADE_FAULT=between-renames -- upgrade shop --assistant-backend codex
check 'an upgrade killed between its two renames leaves the old folder beside the new one' eval '[ ! -e "$LA" ] && ls -d "$legacy/shop"/.assistant.prev.* "$legacy/shop"/.assistant.upgrade.* >/dev/null'
run_tool upgrade-recover AGENT_TEAM_ROOT="$legacy" -- upgrade shop --assistant-backend codex
check 'the next upgrade finishes it: one consistent new folder' eval 'rc_is 0 && grep -qx backend=codex "$LA/agent.conf" && has "$LA/.env.buzz-acp.local" "runtime/codex-acp" && cmp "$LA/identity.key" "$ap/identity.key" && [ -z "$(ls -a "$legacy/shop" | grep "^\.assistant\.")" ]'
check 'it finishes the staged new folder rather than redoing it' has "$OUT/upgrade-recover.out" "assistant: finished an interrupted upgrade"
scenario 'A missing prompt is recreated; the key is never regenerated (C2)'
SHA_KEY=$(sha "$ROOT/shop/supervisor/identity.key") SHA_P=$(sha "$ROOT/shop/supervisor/prompt.md")
rm -f "$ROOT/shop/supervisor/prompt.md"
run_tool create-missing -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'create exits 0' rc_is 0
check 'reports the recreated prompt' has "$OUT/create-missing.out" 'supervisor: created the missing prompt.md'
check 'prompt recreated identical' eval '[ "$(sha "$ROOT/shop/supervisor/prompt.md")" = "$SHA_P" ]'
check 'key unchanged' eval '[ "$(sha "$ROOT/shop/supervisor/identity.key")" = "$SHA_KEY" ]'
mv "$ROOT/shop/supervisor/identity.key" "$TD/keys/moved.key"
run_tool create-nokey -- create --workspace "$TD/ws/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'a folder without its key is refused, not regenerated' eval 'rc_is 1 && has "$OUT/create-nokey.out" "is not trusted" && [ ! -e "$ROOT/shop/supervisor/identity.key" ]'
mv "$TD/keys/moved.key" "$ROOT/shop/supervisor/identity.key"

scenario 'An interrupted create leaves nothing a later run trusts (C2, rule 5)'
# A generator that hangs after its first line: wait until create is inside key generation, then kill it hard.
env AGENT_TEAM_KEYGEN="$BIN/slow-keygen" /bin/bash "$SCRIPT" create --workspace "$TD/ws/web" --channel "$CHANNEL2" \
    --community "$COMMUNITY" --owner "$OWNER" > "$OUT/interrupted.out" 2>&1 < /dev/null &
IPID=$!
i=0
while [ "$i" -lt 50 ] && [ -z "$(find "$ROOT/web" -maxdepth 1 -name '.new-assistant.*' 2>/dev/null)" ]; do sleep 0.2; i=$((i + 1)); done
pkill -9 -P "$IPID" 2>/dev/null; kill -9 "$IPID" 2>/dev/null; wait "$IPID" 2>/dev/null
check 'the killed create left a stale lock behind' test -d "$ROOT/web/.lock"
check 'the run was inside key generation when killed' eval '[ -n "$(find "$ROOT/web" -maxdepth 1 -name ".new-assistant.*")" ]'
check 'no agent folder exists after the kill' eval '[ ! -e "$ROOT/web/assistant" ] && [ ! -e "$ROOT/web/supervisor" ]'
run_tool create-after-kill -- create --workspace "$TD/ws/web" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER"
check 'the next create exits 0' rc_is 0
check 'it removed the unfinished folder' has "$OUT/create-after-kill.out" 'Removed an unfinished file from an interrupted run'
check 'no temporary names are left' eval '[ -z "$(find "$ROOT/web" -name ".new-*")" ] && [ ! -e "$ROOT/web/.lock" ]'
check 'both agents now have keys' eval '[ -s "$ROOT/web/assistant/identity.key" ] && [ -s "$ROOT/web/supervisor/identity.key" ]'

scenario 'create --brief: a note about the workspace ends both prompts; without one nothing is added'
# Its own root, so the agents made here are not channel peers of the scenarios around it.
BR=$TD/root-brief
mkdir -p -- "$TD/ws/notes"
BRIEF_L1='Study notes for the example course.'
BRIEF_L2='Keep summaries short; {{curly}} braces and "quotes" stay as written.'
brief_create() { # NAME [EXTRA ARGS...]: create for the notes workspace under the brief root
    local name=$1
    shift
    run_tool "$name" AGENT_TEAM_ROOT="$BR" -- create --workspace "$TD/ws/notes" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" "$@"
}
run_stdin brief-create "$(printf '\n  %s\r\n%s\n\n' "$BRIEF_L1" "$BRIEF_L2")" AGENT_TEAM_ROOT="$BR" -- \
    create --workspace "$TD/ws/notes" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --brief -
check 'create with a brief on standard input exits 0' rc_is 0
check 'the brief is stored trimmed, without carriage returns, mode 600' \
    eval '[ "$(mode_of "$BR/notes/brief.md")" = 600 ] && [ "$(cat "$BR/notes/brief.md")" = "$BRIEF_L1
$BRIEF_L2" ]'
for id in assistant supervisor; do
    p=$BR/notes/$id/prompt.md
    check "$id: the prompt ends with the brief, as written" \
        eval 'has "$p" "### About this workspace" && has "$p" "$BRIEF_L1" && [ "$(tail -n 1 "$p")" = "$BRIEF_L2" ]'
    check "$id: the brief is marked as background, not a task" has "$p" 'Use this as project background. The owner authorizes delivery work.'
    check "$id: the role rules come first and are complete" \
        eval '[ "$(grep -n "own Buzz memory" "$p" | cut -d: -f1)" -lt "$(grep -n "### About this workspace" "$p" | cut -d: -f1)" ]'
done
check 'the brief is kept outside the shared record' eval '[ "$(ls -A "$TD/ws/notes")" = PROJECT.md ] && hasnt "$TD/ws/notes/PROJECT.md" "$BRIEF_L1"'
check 'create names the stored brief' has "$OUT/brief-create.out" "Workspace brief: $BR/notes/brief.md"
check 'without --brief: no brief file and no brief section (the shop agents)' \
    eval '[ ! -e "$ROOT/shop/brief.md" ] && hasnt "$ROOT/shop/assistant/prompt.md" "About this workspace" && hasnt "$ROOT/shop/supervisor/prompt.md" "About this workspace" && has "$OUT/create-shop.out" "Workspace brief: none"'
SHA_BP=$(sha "$BR/notes/supervisor/prompt.md")
rm -f "$BR/notes/supervisor/prompt.md"
brief_create brief-rebuild
check 'a rebuilt prompt gets the stored brief again, without --brief' eval 'rc_is 0 && [ "$(sha "$BR/notes/supervisor/prompt.md")" = "$SHA_BP" ]'
brief_create brief-replace --brief 'A new note.'
check 'a new brief replaces the stored one' eval 'rc_is 0 && [ "$(cat "$BR/notes/brief.md")" = "A new note." ] && has "$OUT/brief-replace.out" "Brief: replaced"'
check 'existing prompts are kept, and create says how to rebuild them' \
    eval '[ "$(sha "$BR/notes/supervisor/prompt.md")" = "$SHA_BP" ] && has "$OUT/brief-replace.out" "supervisor: its prompt.md was written earlier and is unchanged" && has "$OUT/brief-replace.out" "assistant: its prompt.md was written earlier and is unchanged"'
brief_create brief-same --brief 'A new note.'
check 'the same brief again changes nothing' eval 'rc_is 0 && has "$OUT/brief-same.out" "Brief: unchanged" && hasnt "$OUT/brief-same.out" "written earlier"'
run_stdin brief-empty '   ' AGENT_TEAM_ROOT="$BR" -- create --workspace "$TD/ws/notes" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --brief -
check 'an empty brief on standard input adds nothing and keeps the stored one' \
    eval 'rc_is 0 && has "$OUT/brief-empty.out" "The brief is empty" && [ "$(cat "$BR/notes/brief.md")" = "A new note." ]'
SHA_BT=$(tree_sha "$BR/notes")
brief_create brief-long --brief "$(printf 'x%.0s' $(seq 1 4001))"
check 'a brief over 4000 characters is refused' eval 'rc_is 1 && has "$OUT/brief-long.out" "4001 characters"'
brief_create brief-max --brief "$(printf 'x%.0s' $(seq 1 4000))"
check 'a brief of exactly 4000 characters is accepted' rc_is 0
brief_create brief-restore --brief 'A new note.'
brief_create brief-nsec --brief "my key is nsec1$(printf 'q%.0s' $(seq 1 58)) keep it safe"
check 'a brief holding an nsec secret key is refused' eval 'rc_is 1 && has "$OUT/brief-nsec.out" "secret key (nsec)"'
brief_create brief-apikey --brief "the model key is sk-$(printf 'a%.0s' $(seq 1 24))"
check 'a brief holding what looks like an API key is refused' eval 'rc_is 1 && has "$OUT/brief-apikey.out" "looks like an API key"'
brief_create brief-ctl --brief "$(printf 'bell\007here')"
check 'a brief with control characters is refused' eval 'rc_is 1 && has "$OUT/brief-ctl.out" "control characters"'
brief_agent_key() { # the supervisor's own secret key inside a brief, given on standard input and never printed
    local k
    IFS= read -r k < "$BR/notes/supervisor/identity.key" || true
    run_stdin brief-agentkey "our key: $k" AGENT_TEAM_ROOT="$BR" -- create --workspace "$TD/ws/notes" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --brief -
    k=''
}
brief_agent_key
check 'a brief holding an agent secret key is refused, and the key is not printed' \
    eval 'rc_is 1 && has "$OUT/brief-agentkey.out" "secret key of one of your agents" && no_key_in "$OUT/brief-agentkey.out"'
check 'every refused brief left the workspace folder byte-identical' eval '[ "$(tree_sha "$BR/notes")" = "$SHA_BT" ]'
check 'no unfinished file is left behind' eval '[ -z "$(find "$BR/notes" -name ".new-*")" ]'

scenario 'Two workspaces with the same folder name (C1)'
run_tool same-name -- create --workspace "$TD/other/shop" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER"
check 'refused with a clear message' eval 'rc_is 1 && has "$OUT/same-name.out" "is already used for the workspace $TD/ws/shop" && has "$OUT/same-name.out" "--name"'
run_tool same-name-2 -- create --workspace "$TD/other/shop" --name shop-2 --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" \
    --assistant-name 'Shop' --roles supervisor --supervisor-name 'shop SUPERVISOR'
check 'a name that collides (case-insensitive) with another workspace in the channel is refused (Q5)' eval 'rc_is 1 && has "$OUT/same-name-2.out" "is already the supervisor of workspace \"shop\""'
run_tool same-name-3 -- create --workspace "$TD/other/shop" --name shop-2 --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" \
    --assistant-name 'Twin' --supervisor-name 'twin'
check 'assistant and supervisor with the same name are refused (Q5)' eval 'rc_is 1 && has "$OUT/same-name-3.out" "cannot both be named"'
run_tool same-name-4 -- create --workspace "$TD/other/shop" --name shop-2 --roles supervisor --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" \
    --supervisor-name 'Shop Two Supervisor'
check 'with --name and a distinct name it works' rc_is 0
check 'supervisor-only finds the channel assistant from the other workspace' has "$OUT/same-name-4.out" 'Using the assistant "Shop"'
check 'only a supervisor folder was made' eval '[ -d "$ROOT/shop-2/supervisor" ] && [ ! -e "$ROOT/shop-2/assistant" ]'
check 'its prompt names the existing assistant' has "$ROOT/shop-2/supervisor/prompt.md" 'Shop is the project’s discussion partner'

scenario 'Supervisor only: the channel assistant is found locally or must be named (decision 3)'
run_tool sup-only-found -- create --workspace "$TD/ws/api" --roles supervisor --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER" --name api-x
check 'in a channel with a local assistant, it is found' eval 'rc_is 0 && has "$OUT/sup-only-found.out" "Using the assistant \"Web\""'
# A third channel has no local assistant, so the name is required there.
run_tool sup-only-refused -- create --workspace "$TD/ws/api" --roles supervisor --channel 2d3e4f50-6172-8394-a5b6-c7d8e9f0a1b2 --community "$COMMUNITY" --owner "$OWNER" --name api-y
check 'refused without --assistant-name when no assistant is known' eval 'rc_is 1 && has "$OUT/sup-only-refused.out" "--assistant-name"'
run_tool sup-only -- create --workspace "$TD/ws/api" --roles supervisor --channel 2d3e4f50-6172-8394-a5b6-c7d8e9f0a1b2 --community "$COMMUNITY" --owner "$OWNER" --name api-y --assistant-name 'Team Assistant'
check 'works with --assistant-name' rc_is 0
check 'records the channel assistant' has "$ROOT/api-y/team.conf" 'external_assistant=Team Assistant'
check 'its prompt mentions that assistant' has "$ROOT/api-y/supervisor/prompt.md" 'Team Assistant is the project’s discussion partner'

scenario 'Copying settings from a working env file never copies a secret'
FIX=$TD/fixture.env
FAKE_SECRET=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
{
    echo '# made-up fixture'
    echo 'BUZZ_RELAY_URL=wss://other-community.example.org'
    echo "BUZZ_ACP_AGENT_OWNER=$OWNER2"
    echo "BUZZ_PRIVATE_KEY=$FAKE_SECRET"
    echo 'BUZZ_AUTH_TAG=["auth","made-up"]'
    echo 'ANTHROPIC_API_KEY=example-made-up-api-key'
    echo 'ANTHROPIC_BASE_URL="https://gateway.example.org"'
    echo 'BUZZ_ACP_MODEL=claude-sonnet-5-5'
} > "$FIX"
run_tool from-env -- create --workspace "$TD/ws/docs" --name docs --channel "$CHANNEL2" --from-env "$FIX" --model claude-opus-5-5 \
    --assistant-name 'Docs Helper' --supervisor-name 'Docs Lead'
check 'create --from-env exits 0' rc_is 0
E=$ROOT/docs/assistant/.env.buzz-acp.local
check 'copied the community' has "$E" 'BUZZ_RELAY_URL=wss://other-community.example.org'
check 'copied the owner' has "$E" "BUZZ_ACP_AGENT_OWNER=$OWNER2"
check 'the gateway is not copied (subscription only), and create says so' eval 'hasnt "$E" ANTHROPIC_BASE_URL && has "$OUT/from-env.out" "Not copied from"'
check 'the --model option won over the file, saved for the Claude backend' eval 'grep -qx BUZZ_MODEL_CLAUDE=claude-opus-5-5 "$E" && grep -qx model_claude=claude-opus-5-5 "$ROOT/docs/assistant/agent.conf"'
check 'the fixture secret key was not copied' eval '! grep -rqF -- "$FAKE_SECRET" "$ROOT/docs" "$OUT/from-env.out"'
check 'the model API key was not copied' eval '! grep -rqF -- example-made-up-api-key "$ROOT/docs" "$OUT/from-env.out"'
check 'the fixture proof was not copied' eval 'grep -q "^BUZZ_AUTH_TAG=$" "$E"'

scenario 'proof: a valid proof is stored; checks refuse the rest without changing the file (C6, Q1)'
APUB=$(grep '^pubkey=' "$ROOT/shop/assistant/agent.conf" | cut -d= -f2)
SPUB=$(grep '^pubkey=' "$ROOT/shop/supervisor/agent.conf" | cut -d= -f2)
AE=$ROOT/shop/assistant/.env.buzz-acp.local SE=$ROOT/shop/supervisor/.env.buzz-acp.local
SE_REST=$(grep -v '^BUZZ_AUTH_TAG=' "$SE" | shasum -a 256)
PROOF_A=$(sign "$TD/keys/owner.key" "$APUB" '')
PROOF_S=$(sign "$TD/keys/owner.key" "$SPUB" '')
PROOF_S2=$(sign "$TD/keys/owner.key" "$SPUB" "created_at<$(( $(date +%s) + 86400 * 365 ))")
PROOF_WRONG_OWNER=$(sign "$TD/keys/owner2.key" "$SPUB" '')
PROOF_EXPIRED=$(sign "$TD/keys/owner.key" "$SPUB" 'created_at<1700000000')
PROOF_FUTURE=$(sign "$TD/keys/owner.key" "$SPUB" "created_at>$(( $(date +%s) + 86400 ))")
SIG_A=${PROOF_A##*,\"}; SIG_A=${SIG_A%\"\]}
run_tool proof-a -- proof shop assistant "$PROOF_A"
check 'valid proof stored (exit 0)' rc_is 0
check 'the env file holds the canonical proof' grep -qxF "BUZZ_AUTH_TAG=$PROOF_A" "$AE"
check 'the signature was checked offline' has "$OUT/proof-a.out" 'signature:  valid for agent'
check 'env file still mode 600' eval '[ "$(mode_of "$AE")" = 600 ]'
SHA_AE=$(sha "$AE")
run_tool proof-a-again -- proof shop assistant "$PROOF_A"
check 'the same proof again: exit 0, unchanged' eval 'rc_is 0 && has "$OUT/proof-a-again.out" "already stored" && [ "$(sha "$AE")" = "$SHA_AE" ]'
SHA_SE=$(sha "$SE")
n=0
for bad in 'not a proof' '["auth","'"$OWNER"'",""]' '["nope","'"$OWNER"'","","'"$SIG_A"'"]' \
    '["auth","abc","","'"$SIG_A"'"]' '["auth","'"$OWNER"'","kind=01","'"$SIG_A"'"]' \
    '["auth","'"$OWNER"'","kind=1 & created_at<5","'"$SIG_A"'"]' '["auth","'"$OWNER"'","","'"${SIG_A%?}"'"]' \
    '["auth","'"$OWNER"'","color=red","'"$SIG_A"'"]' '["auth","'"$OWNER"'","","'"$SIG_A"'"'; do
    n=$((n + 1))
    run_tool "proof-malformed-$n" -- proof shop supervisor "$bad"
    check "malformed proof $n refused, file unchanged" eval 'rc_is 1 && has "$OUT/proof-malformed-$n.out" "malformed proof" && [ "$(sha "$SE")" = "$SHA_SE" ]'
done
run_tool proof-other-agent -- proof shop supervisor "$PROOF_A"
check 'a proof made for another agent is refused (signature)' eval 'rc_is 1 && has "$OUT/proof-other-agent.out" "signature:  FAILED" && [ "$(sha "$SE")" = "$SHA_SE" ]'
run_tool proof-wrong-owner -- proof shop supervisor "$PROOF_WRONG_OWNER"
check 'a proof from another owner is refused' eval 'rc_is 1 && has "$OUT/proof-wrong-owner.out" "but this agent'"'"'s owner is" && [ "$(sha "$SE")" = "$SHA_SE" ]'
run_tool proof-expired -- proof shop supervisor "$PROOF_EXPIRED"
check 'an expired proof is refused' eval 'rc_is 1 && has "$OUT/proof-expired.out" "expired at" && [ "$(sha "$SE")" = "$SHA_SE" ]'
run_tool proof-future -- proof shop supervisor "$PROOF_FUTURE"
check 'a not-yet-valid proof is refused' eval 'rc_is 1 && has "$OUT/proof-future.out" "not valid before" && [ "$(sha "$SE")" = "$SHA_SE" ]'
# The unquoted shorthand, pasted as an env line in quotes, through standard input.
S_OWN=$(printf '%s' "$PROOF_S" | cut -d'"' -f4) S_SIG=$(printf '%s' "$PROOF_S" | cut -d'"' -f8)
run_stdin proof-shorthand "BUZZ_AUTH_TAG='[auth, $S_OWN, , $S_SIG]'" -- proof shop supervisor -
check 'shorthand form from standard input stored as canonical JSON' eval 'rc_is 0 && grep -qxF "BUZZ_AUTH_TAG=$PROOF_S" "$SE"'
SHA_SE=$(sha "$SE")
run_tool proof-second -- proof shop supervisor "$PROOF_S2"
check 'a different second proof is refused without --force' eval 'rc_is 1 && has "$OUT/proof-second.out" "--force" && [ "$(sha "$SE")" = "$SHA_SE" ]'
run_tool proof-force -- proof shop supervisor "$PROOF_S2" --force
check 'with --force it replaces the proof' eval 'rc_is 0 && grep -qxF "BUZZ_AUTH_TAG=$PROOF_S2" "$SE" && has "$OUT/proof-force.out" "valid until"'
check 'every other line of the env file is unchanged by proof' eval '[ "$(grep -v "^BUZZ_AUTH_TAG=" "$SE" | shasum -a 256)" = "$SE_REST" ] && [ "$(grep -c "^BUZZ_AUTH_TAG=" "$SE")" = 1 ]'
check 'env file still mode 600 after replacing' eval '[ "$(mode_of "$SE")" = 600 ]'
# --no-signature-check: for a genuine proof the offline check wrongly refuses. Format, owner and time checks stay.
WE=$ROOT/web/assistant/.env.buzz-acp.local
WAPUB=$(grep '^pubkey=' "$ROOT/web/assistant/agent.conf" | cut -d= -f2)
WSPUB=$(grep '^pubkey=' "$ROOT/web/supervisor/agent.conf" | cut -d= -f2)
SIGFAIL=$(sign "$TD/keys/owner.key" "$WSPUB" '')   # a well-formed proof whose signature does not match this agent
SHA_WE=$(sha "$WE")
run_tool proof-sigfail -- proof web assistant "$SIGFAIL"
check 'a signature refusal tells the user what to do next' eval 'rc_is 1 && has "$OUT/proof-sigfail.out" "store it with" && has "$OUT/proof-sigfail.out" "--no-signature-check"'
run_tool proof-nosig-malformed -- proof web assistant '["auth","abc","",""]' --no-signature-check
check 'with --no-signature-check a malformed proof is still refused, file unchanged' eval 'rc_is 1 && has "$OUT/proof-nosig-malformed.out" "malformed proof" && [ "$(sha "$WE")" = "$SHA_WE" ]'
run_tool proof-nosig-owner -- proof web assistant "$(sign "$TD/keys/owner2.key" "$WAPUB" '')" --no-signature-check
check 'with --no-signature-check a wrong-owner proof is still refused, file unchanged' eval 'rc_is 1 && has "$OUT/proof-nosig-owner.out" "but this agent'"'"'s owner is" && [ "$(sha "$WE")" = "$SHA_WE" ]'
run_tool proof-nosig-expired -- proof web assistant "$(sign "$TD/keys/owner.key" "$WAPUB" 'created_at<1700000000')" --no-signature-check
check 'with --no-signature-check an expired proof is still refused, file unchanged' eval 'rc_is 1 && has "$OUT/proof-nosig-expired.out" "expired at" && [ "$(sha "$WE")" = "$SHA_WE" ]'
run_tool proof-nosig -- proof web assistant "$SIGFAIL" --no-signature-check
check 'with --no-signature-check the proof is stored (exit 0)' eval 'rc_is 0 && grep -qxF "BUZZ_AUTH_TAG=$SIGFAIL" "$WE"'
check 'it says the signature was not checked' has "$OUT/proof-nosig.out" 'signature:  NOT CHECKED (--no-signature-check)'
check 'it warns that the first start is the first real check' eval 'has "$OUT/proof-nosig.out" "WITHOUT checking its signature" && has "$OUT/proof-nosig.out" "first real check"'
run_tool proof-nosig-second -- proof web assistant "$(sign "$TD/keys/owner.key" "$WAPUB" '')"
check '--force alone still governs replacing it (a second proof is refused without --force)' eval 'rc_is 1 && has "$OUT/proof-nosig-second.out" "--force"'
# A hand-edited env file with an indented proof line: the line is replaced, never duplicated.
DE=$ROOT/docs/assistant/.env.buzz-acp.local
DPUB=$(grep '^pubkey=' "$ROOT/docs/assistant/agent.conf" | cut -d= -f2)
sed 's/^BUZZ_AUTH_TAG=$/   BUZZ_AUTH_TAG = /' "$DE" > "$DE.edit" && mv "$DE.edit" "$DE" && chmod 600 "$DE"
run_tool proof-indented -- proof docs assistant "$(sign "$TD/keys/owner2.key" "$DPUB" '')"
check 'an indented proof line is replaced, not duplicated' eval 'rc_is 0 && [ "$(grep -v "^#" "$DE" | grep -c "BUZZ_AUTH_TAG")" = 1 ] && [ "$(grep -c "^BUZZ_AUTH_TAG=\[" "$DE")" = 1 ]'
check 'no temporary file left by proof' eval '[ -z "$(find "$ROOT/shop" -name ".new-*")" ]'

scenario 'proof pasted at a terminal, wrapped over three lines (C6)'
PTY=$TD/pty_paste.py
cat > "$PTY" <<'PY'
import os, pty, select, sys, time
args = sys.argv[1:]
sep = args.index("--")
prompt, lines, cmd = args[0].encode(), args[1:sep], args[sep + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent, deadline = b"", False, time.time() + 20
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and prompt in out:
        for line in lines:
            os.write(fd, line.encode() + b"\n")
            time.sleep(0.2)
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
sys.exit(status >> 8)
PY
DSPUB=$(grep '^pubkey=' "$ROOT/docs/supervisor/agent.conf" | cut -d= -f2)
PROOF_D=$(sign "$TD/keys/owner2.key" "$DSPUB" '')
RC=0
python3 -I "$PTY" 'Paste the proof' "${PROOF_D:0:40}" "${PROOF_D:40:90}" "${PROOF_D:130}" -- \
    /bin/bash "$SCRIPT" proof docs supervisor > "$OUT/proof-tty.out" 2>&1 || RC=$?
check 'the terminal prompt was shown and the proof stored (exit 0)' eval 'rc_is 0 && has "$OUT/proof-tty.out" "Paste the proof from Buzz Desktop"'
check 'the three pasted lines were joined into the canonical proof' grep -qxF "BUZZ_AUTH_TAG=$PROOF_D" "$ROOT/docs/supervisor/.env.buzz-acp.local"

scenario 'verify-proof against the NIP-OA specification test vector (Q1)'
SPEC='["auth","79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","kind=1&created_at<1713957000","8b7df2575caf0a108374f8471722b233c53f9ff827a8b0f91861966c3b9dd5cb2e189eae9f49d72187674c2f5bd244145e10ff86c9f257ffe65a1ee5f108b369"]'
SPEC_AGENT=c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5
run_tool spec-vector -- verify-proof "$SPEC_AGENT" "$SPEC"
check 'the specification signature verifies' has "$OUT/spec-vector.out" "signature:  valid for agent $SPEC_AGENT"
check 'its 2024 expiry is reported' has "$OUT/spec-vector.out" 'expired at 2024-04-24'
check 'its kind limit is warned about' has "$OUT/spec-vector.out" 'limited to event kinds 1'
run_tool spec-altered -- verify-proof "$SPEC_AGENT" "${SPEC/8b7df/8b7de}"
check 'one altered hex digit fails the signature' has "$OUT/spec-altered.out" 'signature:  FAILED'
run_tool spec-nopython AGENT_TEAM_PYTHON=none -- verify-proof "$APUB" "$PROOF_A"
check 'without python3 the signature is reported as not checked' eval 'rc_is 0 && has "$OUT/spec-nopython.out" "not checked offline"'

scenario 'finish --dry-run prints the exact commands and runs nothing (C7, Q2)'
: > "$FAKE_BUZZ_LOG"
run_tool finish-dry -- finish shop --dry-run
check 'dry run exits 0' rc_is 0
check 'nothing ran (no buzz call recorded)' eval '[ ! -s "$FAKE_BUZZ_LOG" ]'
check 'prints the launcher check per agent' eval '[ "$(grep -c -- "--check" "$OUT/finish-dry.out")" = 2 ]'
check 'prints set-profile per agent' eval '[ "$(grep -c " users set-profile --name " "$OUT/finish-dry.out")" = 2 ]'
check 'prints add-member per agent with --role bot' eval '[ "$(grep -c " channels add-member --channel $CHANNEL --pubkey " "$OUT/finish-dry.out")" = 2 ] && has "$OUT/finish-dry.out" "--role bot"'
check 'no secret key in the dry-run output' no_key_in "$OUT/finish-dry.out"
run_tool finish-bogus -- finish shop bogus --dry-run
check 'an unknown agent name fails finish (exit 1), with no success line' eval 'rc_is 1 && has "$OUT/finish-bogus.out" "unknown agent: bogus" && hasnt "$OUT/finish-bogus.out" "complete"'
run_tool finish-dry-join -- finish shop supervisor --dry-run --channel-step join --role member
check 'join variant prints channels join for one agent' eval 'rc_is 0 && [ "$(grep -c " channels join --channel $CHANNEL" "$OUT/finish-dry-join.out")" = 1 ]'
if [ -n "$REAL_BUZZ" ]; then
    "$REAL_BUZZ" --help > "$OUT/help-top.txt" 2>&1
    check 'buzz --help documents the --relay option (placed before the subcommand)' grep -q -- '--relay <RELAY>' "$OUT/help-top.txt"
    for sub in 'users set-profile' 'channels add-member' 'channels join'; do
        set -- $sub
        "$REAL_BUZZ" "$1" "$2" --help > "$OUT/help-$1-$2.txt" 2>&1
        line=$(grep -h " $sub " "$OUT/finish-dry.out" "$OUT/finish-dry-join.out" | head -n 1)
        check "dry-run line for '$sub' was printed" eval '[ -n "$line" ]'
        check "dry-run line for '$sub' puts --relay before the subcommand" eval 'case $line in *" --relay "*" $sub "*) true ;; *) false ;; esac'
        for w in $line; do
            case $w in --relay) ;; --*) check "buzz $sub has $w" grep -q -- " $w" "$OUT/help-$1-$2.txt" ;; esac
        done
    done
    check 'add-member accepts the bot and member roles' grep -q 'owner, admin, member, guest, bot' "$OUT/help-channels-add-member.txt"
    set --
else
    skip 'AGENT_TEAM_REAL_BUZZ not set'
fi

scenario 'finish refuses agents without a proof (C7, rule 1)'
: > "$FAKE_BUZZ_LOG"
run_tool finish-noproof -- finish web
check 'refused (exit 1) naming the proof step' eval 'rc_is 1 && has "$OUT/finish-noproof.out" "has no ownership proof yet"'
check 'nothing ran' eval '[ ! -s "$FAKE_BUZZ_LOG" ]'

scenario 'finish runs check, profile and channel steps with the right identities (stand-in buzz) (C7, C3)'
: > "$FAKE_BUZZ_LOG"
FINISH_LAUNCHER=$BIN/standin-launcher.sh
[ -z "$REAL_LAUNCHER" ] || FINISH_LAUNCHER=$REAL_LAUNCHER
run_tool finish-run AGENT_TEAM_LAUNCHER="$FINISH_LAUNCHER" -- finish shop
check 'finish exits 0' rc_is 0
check "the check step used $( [ -n "$REAL_LAUNCHER" ] && echo 'the accepted launcher' || echo 'the stand-in launcher')" eval '[ "$(grep -cE "Required settings and executables found|stand-in launcher: check" "$OUT/finish-run.out")" = 2 ]'
check 'set-profile ran once per agent' eval '[ "$(grep -c "\[users\] \[set-profile\]" "$FAKE_BUZZ_LOG")" = 2 ]'
check 'add-member ran once per agent' eval '[ "$(grep -c "\[channels\] \[add-member\]" "$FAKE_BUZZ_LOG")" = 2 ]'
# The stand-in hashes the key value it received; hash each key file's value the same way.
KA=$(IFS= read -r v < "$ROOT/shop/assistant/identity.key"; printf '%s' "$v" | shasum -a 256 | cut -c1-64)
KS=$(IFS= read -r v < "$ROOT/shop/supervisor/identity.key"; printf '%s' "$v" | shasum -a 256 | cut -c1-64)
check 'set-profile for the assistant signed with the assistant key' eval 'grep -A1 "Shop" "$FAKE_BUZZ_LOG" | grep -q "key-sha256: $KA"'
check 'set-profile for the supervisor signed with the supervisor key' eval 'grep -A1 "Shop Supervisor" "$FAKE_BUZZ_LOG" | grep -q "key-sha256: $KS"'
check 'set-profile carried each agent'"'"'s proof' eval 'grep -qF "auth-tag: $PROOF_A" "$FAKE_BUZZ_LOG" && grep -qF "auth-tag: $PROOF_S2" "$FAKE_BUZZ_LOG"'
check 'add-member ran as you: no agent key, no proof, not the stray exported key' eval '[ "$(grep -A2 "\[add-member\]" "$FAKE_BUZZ_LOG" | grep -c "key-sha256: none")" = 2 ] && [ "$(grep -A2 "\[add-member\]" "$FAKE_BUZZ_LOG" | grep -c "auth-tag: none")" = 2 ]'
check 'add-member named both agents'"'"' public keys' eval 'grep -q "\[--pubkey\] \[$APUB\]" "$FAKE_BUZZ_LOG" && grep -q "\[--pubkey\] \[$SPUB\]" "$FAKE_BUZZ_LOG"'
check 'no secret key in any buzz argument or in finish output' no_key_in "$FAKE_BUZZ_LOG" "$OUT/finish-run.out"
check 'the stray exported BUZZ_PRIVATE_KEY never reached buzz' eval '! grep -q "key-sha256: $(printf %s "$BUZZ_PRIVATE_KEY" | shasum -a 256 | cut -c1-64)" "$FAKE_BUZZ_LOG"'

scenario 'finish stops at the first failed step (rule 1)'
: > "$FAKE_BUZZ_LOG"
run_tool finish-fail FAKE_BUZZ_FAIL=set-profile AGENT_TEAM_LAUNCHER="$BIN/standin-launcher.sh" -- finish shop
check 'finish exits 1' rc_is 1
check 'the failure is named' has "$OUT/finish-fail.out" 'assistant: setting the display name failed (exit 3)'
check 'no later step ran' eval '[ "$(grep -c "^argv:" "$FAKE_BUZZ_LOG")" = 1 ] && ! grep -q add-member "$FAKE_BUZZ_LOG"'

scenario 'start refuses an agent without a proof (C8)'
run_tool start-noproof -- start web
check 'refused (exit 1)' eval 'rc_is 1 && has "$OUT/start-noproof.out" "has no ownership proof; nothing was started"'
check 'no pid file written' eval '[ ! -e "$ROOT/web/assistant/agent.pid" ] && [ ! -e "$ROOT/web/supervisor/agent.pid" ]'
run_tool start-bogus -- start shop bogus
check 'an unknown agent name fails start (exit 1) and starts nothing' eval 'rc_is 1 && has "$OUT/start-bogus.out" "unknown agent: bogus" && [ ! -e "$ROOT/shop/assistant/agent.pid" ]'
run_tool stop-bogus -- stop shop bogus
check 'an unknown agent name fails stop (exit 1)' eval 'rc_is 1 && has "$OUT/stop-bogus.out" "unknown agent: bogus"'

scenario 'start runs each agent in the background with its own log (C8)'
run_tool start-shop -- start shop
check 'start exits 0' rc_is 0
check 'start names the launcher it uses' has "$OUT/start-shop.out" "Launcher: $BIN/standin-launcher.sh"
PA=$(head -n 1 "$ROOT/shop/assistant/agent.pid" 2>/dev/null) PS=$(head -n 1 "$ROOT/shop/supervisor/agent.pid" 2>/dev/null)
BG_PIDS="$PA $PS"
check 'assistant is running' alive "$PA"
check 'supervisor is running' alive "$PS"
check 'each agent has its own log' eval 'has "$ROOT/shop/assistant/agent.log" "stand-in harness: pid $PA" && has "$ROOT/shop/supervisor/agent.log" "stand-in harness: pid $PS"'
check 'the launcher ran from the agent folder' has "$ROOT/shop/assistant/agent.log" "stand-in launcher: cwd $ROOT/shop/assistant"
check 'CLAUDE_AGENT_ACP_PROTOCOL=v1 was set' has "$ROOT/shop/assistant/agent.log" 'CLAUDE_AGENT_ACP_PROTOCOL=v1'
check 'the stray exported BUZZ_PRIVATE_KEY was removed' has "$ROOT/shop/assistant/agent.log" 'inherited BUZZ_PRIVATE_KEY=no'
check 'the harness process is the recorded PID (exec, no wrapper)' eval '[ "$(ps -o pid= -p "$PA" | tr -d " ")" = "$PA" ] && ps -ww -o args= -p "$PA" | grep -q buzz-acp'
ps -ww -A -o args= > "$OUT/ps-args.txt" 2>/dev/null
check 'no secret key in any running process'"'"'s arguments' no_key_in "$OUT/ps-args.txt"

scenario 'start does not start a second copy (C8)'
run_tool start-again -- start shop
check 'second start exits 0 and says already running' eval 'rc_is 0 && [ "$(grep -c "already running" "$OUT/start-again.out")" = 2 ]'
check 'the PIDs are unchanged' eval '[ "$(head -n 1 "$ROOT/shop/assistant/agent.pid")" = "$PA" ] && [ "$(head -n 1 "$ROOT/shop/supervisor/agent.pid")" = "$PS" ]'
check 'exactly one harness per agent folder' eval '[ "$(grep -c "stand-in harness: pid" "$ROOT/shop/assistant/agent.log")" = 1 ]'

scenario 'status shows keys, proofs and running state'
run_tool status-shop -- status shop
check 'status exits 0' rc_is 0
check 'status shows both running PIDs and the backend each runs on' eval 'has "$OUT/status-shop.out" "running on claude, PID $PA" && has "$OUT/status-shop.out" "running on claude, PID $PS"'
check 'status shows proofs stored' eval '[ "$(grep -c "proof stored" "$OUT/status-shop.out")" = 2 ]'
check 'status names the launcher start would use' has "$OUT/status-shop.out" "Launcher for start: $BIN/standin-launcher.sh"
run_tool status-all -- status
check 'status without a name lists the workspaces' eval 'has "$OUT/status-all.out" "  shop  $TD/ws/shop" && has "$OUT/status-all.out" "  docs  "'

scenario 'stop ends only processes this tool started (C8)'
(cd "$TD" && exec "$BIN/buzz-acp") > "$OUT/unrelated.log" 2>&1 &
UPID=$!
BG_PIDS="$BG_PIDS $UPID"
cp "$ROOT/shop/supervisor/agent.pid" "$TD/keys/sup.pid.saved"
printf '%s\n%s\n' "$UPID" 'Mon Jan  1 00:00:00 2001' > "$ROOT/shop/supervisor/agent.pid"
run_tool stop-reused AGENT_TEAM_STOP_GRACE=2 -- stop shop supervisor
check 'a recorded PID that now belongs to another process is not touched' eval 'rc_is 0 && has "$OUT/stop-reused.out" "belongs to another process" && alive "$UPID"'
cp "$TD/keys/sup.pid.saved" "$ROOT/shop/supervisor/agent.pid"
T0=$(date +%s)
run_tool stop-shop AGENT_TEAM_STOP_GRACE=5 -- stop shop
T1=$(date +%s)
check 'stop exits 0' rc_is 0
check 'both agents stopped' eval '! alive "$PA" && ! alive "$PS"'
check 'the harness got SIGTERM and shut down cleanly' has "$ROOT/shop/assistant/agent.log" 'stand-in harness: stopping'
check 'the unrelated process is still running' alive "$UPID"
check 'pid files removed' eval '[ ! -e "$ROOT/shop/assistant/agent.pid" ] && [ ! -e "$ROOT/shop/supervisor/agent.pid" ]'
check "stop finished within its bound ($((T1 - T0)) s)" eval '[ $((T1 - T0)) -le 5 ]'
run_tool stop-again -- stop shop
check 'stopping again is harmless' eval 'rc_is 0 && [ "$(grep -c "not started by this tool" "$OUT/stop-again.out")" = 2 ]'
kill "$UPID" 2>/dev/null; wait "$UPID" 2>/dev/null

scenario 'stop is bounded when the harness ignores SIGTERM; --force ends it (C8, rule 4)'
run_tool start-stubborn FAKE_HARNESS_MODE=ignore-term -- start shop assistant
PX=$(head -n 1 "$ROOT/shop/assistant/agent.pid" 2>/dev/null)
BG_PIDS="$BG_PIDS $PX"
check 'started' eval 'rc_is 0 && alive "$PX"'
T0=$(date +%s)
run_tool stop-stubborn AGENT_TEAM_STOP_GRACE=1 -- stop shop assistant
T1=$(date +%s)
check 'stop reports failure (exit 1), never success' eval 'rc_is 1 && has "$OUT/stop-stubborn.out" "still running as PID $PX"'
check "it gave up within its bound ($((T1 - T0)) s)" eval '[ $((T1 - T0)) -le 4 ]'
check 'the process is still there, still recorded' eval 'alive "$PX" && [ -f "$ROOT/shop/assistant/agent.pid" ]'
run_tool stop-force AGENT_TEAM_STOP_GRACE=1 -- stop shop assistant --force
check 'stop --force ends it' eval 'rc_is 0 && ! alive "$PX"'

scenario 'start reports an agent that exits at once, and the protocol can be overridden (C8, rule 1)'
run_tool start-failfast FAKE_HARNESS_MODE=fail-fast AGENT_TEAM_START_WAIT=2 -- start shop supervisor
check 'start exits 1' rc_is 1
check 'it says the agent did not start and shows the log tail' eval 'has "$OUT/start-failfast.out" "supervisor did not start" && has "$OUT/start-failfast.out" "failing on purpose"'
run_tool status-exited -- status shop
check 'status shows it exited' has "$OUT/status-exited.out" 'not running (exited; see the log)'
printf 'x%.0s' $(seq 1 64) >> "$ROOT/shop/supervisor/agent.log"
run_tool start-v2 CLAUDE_AGENT_ACP_PROTOCOL=v2 AGENT_TEAM_LOG_MAX_BYTES=32 -- start shop supervisor
PV=$(head -n 1 "$ROOT/shop/supervisor/agent.pid" 2>/dev/null)
BG_PIDS="$BG_PIDS $PV"
check 'started with the overridden protocol' eval 'rc_is 0 && has "$ROOT/shop/supervisor/agent.log" "CLAUDE_AGENT_ACP_PROTOCOL=v2"'
check 'a log above the size cap was moved to agent.log.1' eval '[ -s "$ROOT/shop/supervisor/agent.log.1" ] && has "$ROOT/shop/supervisor/agent.log.1" "failing on purpose"'
run_tool stop-v2 AGENT_TEAM_STOP_GRACE=5 -- stop shop supervisor
check 'stopped' eval 'rc_is 0 && ! alive "$PV"'

scenario 'Settings: public defaults only, mode 600, used by create, options win (D3)'
RS=$TD/root-settings
SET_OWNER=$OWNER
run_tool set-show AGENT_TEAM_ROOT="$RS" -- settings
check 'settings with no option shows the (empty) settings and creates nothing' eval 'rc_is 0 && has "$OUT/set-show.out" "(not created yet)" && [ ! -e "$RS" ]'
run_tool set-1 AGENT_TEAM_ROOT="$RS" -- settings --keygen "$KEYGEN" --launcher "$BIN/standin-launcher.sh" \
    --community wss://defaults.example.org --owner "$SET_OWNER" --model claude-sonnet-5-5
check 'settings saves (exit 0)' rc_is 0
check 'settings.conf sits under the root with mode 600' eval '[ -f "$RS/settings.conf" ] && [ "$(mode_of "$RS/settings.conf")" = 600 ]'
check 'the root is mode 700' eval '[ "$(mode_of "$RS")" = 700 ]'
check 'settings.conf holds only the known names' \
    eval '[ -z "$(grep -v "^#" "$RS/settings.conf" | cut -d= -f1 | grep -Ev "^(format|keygen|launcher|community|owner|model|base_url)$")" ]'
run_tool set-create -u AGENT_TEAM_KEYGEN -u AGENT_TEAM_LAUNCHER AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/shop" --channel "$CHANNEL"
SE2=$RS/shop/assistant/.env.buzz-acp.local
check 'create with no community or owner option uses the settings (exit 0)' rc_is 0
check 'create used the key generator from settings' key_is_hex "$RS/shop/assistant/identity.key"
check 'create took community, owner and the Claude model from settings; no gateway' eval 'has "$SE2" "BUZZ_RELAY_URL=wss://defaults.example.org" && has "$SE2" "BUZZ_ACP_AGENT_OWNER=$SET_OWNER" && has "$SE2" "BUZZ_MODEL_CLAUDE=claude-sonnet-5-5" && hasnt "$SE2" ANTHROPIC_'
run_tool set-create-opt AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/api" --channel "$CHANNEL2" \
    --community wss://option.example.org --owner "$OWNER2" --model claude-opus-5-5
SE3=$RS/api/assistant/.env.buzz-acp.local
check 'explicit options win over settings' eval 'rc_is 0 && has "$SE3" "BUZZ_RELAY_URL=wss://option.example.org" && has "$SE3" "BUZZ_ACP_AGENT_OWNER=$OWNER2" && has "$SE3" "BUZZ_MODEL_CLAUDE=claude-opus-5-5"'
run_tool set-base AGENT_TEAM_ROOT="$RS" -- settings --base-url https://gateway.example.org
check 'settings refuses a gateway address (subscription only)' eval 'rc_is 1 && has "$OUT/set-base.out" "subscription"'
run_tool create-base AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/api" --channel "$CHANNEL2" --base-url https://gateway.example.org
check 'create refuses --base-url (subscription only)' eval 'rc_is 1 && has "$OUT/create-base.out" "subscription"'
# New Codex identities share the same role contract and skip the saved Claude model.
mkdir -p "$TD/ws/backend-choice"
run_tool backend-create AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/backend-choice" --channel "$CHANNEL2" --backend codex
codex_pair=$RS/backend-choice
check 'Codex creation selects the restricted partner and stock supervisor' eval 'rc_is 0 && has "$codex_pair/assistant/.env.buzz-acp.local" "BUZZ_ACP_AGENT_COMMAND=$codex_pair/assistant/runtime/codex-acp" && has "$codex_pair/supervisor/.env.buzz-acp.local" "BUZZ_ACP_AGENT_COMMAND=codex-acp"'
check 'Codex ignores the saved Claude model; both agents record codex' eval 'grep -qx BUZZ_MODEL_CODEX= "$codex_pair/assistant/.env.buzz-acp.local" && grep -qx BUZZ_MODEL_CLAUDE= "$codex_pair/assistant/.env.buzz-acp.local" && ! grep -q ANTHROPIC_ "$codex_pair/assistant/.env.buzz-acp.local" && grep -qx backend=codex "$codex_pair/supervisor/agent.conf"'
codex_key_sha=$(sha "$codex_pair/assistant/identity.key")
rm -- "$codex_pair/assistant/.env.buzz-acp.local"
run_tool backend-repair AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/backend-choice" --channel "$CHANNEL2"
check 'repair remembers the selected backend and identity' eval 'rc_is 0 && has "$codex_pair/assistant/.env.buzz-acp.local" "runtime/codex-acp" && grep -qx BUZZ_MODEL_CODEX= "$codex_pair/assistant/.env.buzz-acp.local" && [ "$codex_key_sha" = "$(sha "$codex_pair/assistant/identity.key")" ]'
run_tool backend-invalid AGENT_TEAM_ROOT="$RS" -- start backend-choice --backend invalid
check 'invalid startup selection fails before recording a PID' eval 'rc_is 1 && has "$OUT/backend-invalid.out" "--backend codex" && [ ! -e "$codex_pair/assistant/agent.pid" ]'
run_tool set-launcher-start -u AGENT_TEAM_LAUNCHER AGENT_TEAM_ROOT="$RS" -- status shop
check 'status reports the launcher from settings' has "$OUT/set-launcher-start.out" "Launcher for start: $BIN/standin-launcher.sh"
# Refusals: nothing secret can be written. Each run must fail and leave settings.conf unchanged.
SHA_SET=$(sha "$RS/settings.conf")
AGENT_SECRET_FILE=$RS/shop/assistant/identity.key
n=0
set_refused() { # LABEL ARGS...
    local label=$1
    shift
    n=$((n + 1))
    run_tool "set-refuse-$n" AGENT_TEAM_ROOT="$RS" -- settings "$@"
    check "refused: $label (file unchanged)" eval 'rc_is 1 && [ "$(sha "$RS/settings.conf")" = "$SHA_SET" ]'
}
# The agent's own secret key, read into the shell only, offered as the owner key.
AGENT_SECRET=0000000000000000000000000000000000000000000000000000000000000000
if [ -f "$AGENT_SECRET_FILE" ]; then IFS= read -r AGENT_SECRET < "$AGENT_SECRET_FILE" || true; fi
set_refused 'an agent secret key as the owner' --owner "$AGENT_SECRET"
check 'the refusal names it as an agent secret key without printing it' eval 'has "$OUT/set-refuse-$n.out" "secret key of one of your agents" && hasnt "$OUT/set-refuse-$n.out" "$AGENT_SECRET"'
run_tool create-secret-owner AGENT_TEAM_ROOT="$RS" -- create --workspace "$TD/ws/web" --channel "$CHANNEL" --owner "$AGENT_SECRET"
check 'create also refuses an agent secret key as the owner' eval 'rc_is 1 && has "$OUT/create-secret-owner.out" "secret key of one of your agents" && [ ! -e "$RS/web/assistant" ]'
AGENT_SECRET=''
set_refused 'an nsec secret key' --owner nsec1exampleexampleexampleexampleexampleexampleexampleexample
set_refused 'a proof as the community' --community '["auth","'"$OWNER"'","","'"$SIG_A"'"]'
set_refused 'a model API key as the model' --model sk-ant-api03-ExampleOnlyNotARealKey0123456789
set_refused 'a gateway address with a user and password' --base-url 'https://user:example-password@gateway.example.org'
set_refused 'a gateway address with a token in its query' --base-url 'https://gateway.example.org/v1?api_key=example'
set_refused 'a community address with a token in its query' --community 'wss://community.example.org/?token=example'
set_refused 'a relative key generator path' --keygen buzz-admin
set_refused 'a key generator that is not executable' --keygen "$RS/settings.conf"
set_refused 'an unknown setting (no option for a private key exists)' --private-key 0123
set_refused 'an unknown name to unset' --unset private_key
mkdir -p "$TD/root-link" && chmod 700 "$TD/root-link" && ln -s "$RS/settings.conf" "$TD/root-link/settings.conf"
run_tool set-symlink AGENT_TEAM_ROOT="$TD/root-link" -- settings --model example-model
check 'a settings.conf that is a symbolic link is refused, and its target is unchanged' eval 'rc_is 1 && has "$OUT/set-symlink.out" "not a regular file" && [ "$(sha "$RS/settings.conf")" = "$SHA_SET" ]'
# --from-env copies only the four public values, even from a file full of secrets.
run_tool set-from-env AGENT_TEAM_ROOT="$TD/root-fromenv" -- settings --from-env "$FIX"
check 'settings --from-env saves (exit 0)' rc_is 0
check 'it copied the community, owner and model, and no gateway' eval 'has "$TD/root-fromenv/settings.conf" "community=wss://other-community.example.org" && has "$TD/root-fromenv/settings.conf" "owner=$OWNER2" && has "$TD/root-fromenv/settings.conf" "model=claude-sonnet-5-5" && hasnt "$TD/root-fromenv/settings.conf" base_url'
check 'it copied no secret: fixture key, API key and proof absent' eval '! grep -qF -- "$FAKE_SECRET" "$TD/root-fromenv/settings.conf" && ! grep -qF example-made-up-api-key "$TD/root-fromenv/settings.conf" && ! grep -qF made-up "$TD/root-fromenv/settings.conf"'
run_tool set-unset AGENT_TEAM_ROOT="$TD/root-fromenv" -- settings --unset model --unset base_url
check 'settings --unset removes values' eval 'rc_is 0 && ! grep -q "^model=" "$TD/root-fromenv/settings.conf" && ! grep -q "^base_url=" "$TD/root-fromenv/settings.conf" && [ "$(mode_of "$TD/root-fromenv/settings.conf")" = 600 ]'
run_tool set-git -u GIT_CEILING_DIRECTORIES AGENT_TEAM_ROOT="$INREPO/agents2" -- settings --model example-model
check 'settings refuses a root inside a Git work tree' eval 'rc_is 1 && has "$OUT/set-git.out" "inside the Git work tree" && [ ! -e "$INREPO/agents2" ]'

scenario 'Preflight: one fix line per missing item, non-zero exit, prints the launcher (D3)'
MB=$TD/minbin
mkdir -p "$MB"
ln -s "$BIN/buzz" "$MB/buzz"; ln -s "$BIN/buzz-acp" "$MB/buzz-acp"; ln -s "$BIN/claude-agent-acp" "$MB/claude-agent-acp"
ln -s "$BIN/node" "$MB/node"   # the partner runtime check runs buzz-tools with node
MINPATH=$MB:/usr/bin:/bin:/usr/sbin:/sbin
RP=$TD/root-preflight
pre() { # NAME [VAR=value ...]: preflight with a controlled PATH and no tool variables
    local name=$1
    shift
    RC=0
    env -u AGENT_TEAM_KEYGEN -u AGENT_TEAM_LAUNCHER -u AGENT_TEAM_BUZZ PATH="$MINPATH" AGENT_TEAM_ROOT="$RP" AGENT_TEAM_PYTHON=none "$@" \
        /bin/bash "$SCRIPT" preflight > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?
}
pre pre-empty
check 'nothing set: exit 1' rc_is 1
check 'missing key generator: a MISSING line and a fix line' eval 'grep -q "MISSING  key generator" "$OUT/pre-empty.out" && grep -q "fix: agent-team.sh settings --keygen" "$OUT/pre-empty.out"'
check 'missing launcher: a MISSING line and a fix line' eval 'grep -q "MISSING  launcher" "$OUT/pre-empty.out" && grep -q "fix: agent-team.sh settings --launcher" "$OUT/pre-empty.out"'
check 'one fix line per missing item' eval '[ "$(grep -cE "^  (MISSING|PROBLEM) " "$OUT/pre-empty.out")" = "$(grep -c "fix: " "$OUT/pre-empty.out")" ]'
check 'unset defaults are listed with how to set them' eval 'grep -q "to set: agent-team.sh settings --community" "$OUT/pre-empty.out" && grep -q "to set: agent-team.sh settings --owner" "$OUT/pre-empty.out"'
check 'preflight created nothing' eval '[ ! -e "$RP" ]'
mkdir -p "$RP" && chmod 700 "$RP"
env AGENT_TEAM_ROOT="$RP" /bin/bash "$SCRIPT" settings --keygen "$KEYGEN" --launcher "$BIN/standin-launcher.sh" --community "$COMMUNITY" --owner "$OWNER" > "$OUT/pre-settings.out" 2>&1
SNAP_RP=$(cd "$RP" && find . -print | LC_ALL=C sort; sha "$RP/settings.conf")
pre pre-ok
check 'everything present: exit 0, "Preflight passed"' eval 'rc_is 0 && has "$OUT/pre-ok.out" "Preflight passed"'
check 'it prints the launcher path' has "$OUT/pre-ok.out" "Launcher: $BIN/standin-launcher.sh"
check 'python3 absent is only a warning' has "$OUT/pre-ok.out" 'warning  python3'
check 'preflight changed nothing under the root' eval '[ "$(cd "$RP" && find . -print | LC_ALL=C sort; sha "$RP/settings.conf")" = "$SNAP_RP" ]'
pre pre-nobuzzacp PATH="$TD/nowhere:/usr/bin:/bin"
check 'buzz, buzz-acp and claude-agent-acp missing from PATH: exit 1 with fix lines (the adapter once per role)' \
    eval 'rc_is 1 && grep -q "MISSING  buzz-acp" "$OUT/pre-nobuzzacp.out" && grep -q "MISSING  buzz " "$OUT/pre-nobuzzacp.out" && [ "$(grep -c "MISSING  claude-agent-acp" "$OUT/pre-nobuzzacp.out")" = 2 ] && [ "$(grep -c "fix: " "$OUT/pre-nobuzzacp.out")" = 4 ]'
chmod 644 "$RP/settings.conf"
pre pre-mode
check 'settings.conf with mode 644: exit 1 and the chmod fix' eval 'rc_is 1 && grep -q "PROBLEM  settings file" "$OUT/pre-mode.out" && grep -q "fix: chmod 600" "$OUT/pre-mode.out"'
chmod 600 "$RP/settings.conf"
RC=0
env -u GIT_CEILING_DIRECTORIES -u AGENT_TEAM_KEYGEN -u AGENT_TEAM_LAUNCHER AGENT_TEAM_ROOT="$INREPO/agents3" /bin/bash "$SCRIPT" preflight > "$OUT/pre-git.out" 2>&1 || RC=$?
check 'a root inside a Git work tree: exit 1 and a PROBLEM line' eval 'rc_is 1 && grep -q "PROBLEM  agents root" "$OUT/pre-git.out" && [ ! -e "$INREPO/agents3" ]'

scenario 'Self-contained: the skill folder works from any location (D1)'
EL="$TD/elsewhere/a parent with spaces"
mkdir -p "$EL"
cp -Rp "$SKILL_DIR" "$EL/buzz-agent-team"
CS="$EL/buzz-agent-team/scripts/agent-team.sh"
printf '\n<!-- template of the copied folder -->\n' >> "$EL/buzz-agent-team/templates/supervisor.md"
RD=$TD/root-d1
d1() { local name=$1; shift; RC=0; env AGENT_TEAM_ROOT="$RD" "$CS" "$@" > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?; }
d1 d1-create create --workspace "$TD/ws/web" --channel 3e4f5061-7283-94a5-b6c7-d8e9f0a1b2c3 --community "$COMMUNITY" --owner "$OWNER"
check 'create from the copied folder (exit 0)' rc_is 0
check 'the prompts came from the copied folder'"'"'s templates' has "$RD/web/supervisor/prompt.md" 'template of the copied folder'
check 'no placeholder left' eval 'hasnt "$RD/web/assistant/prompt.md" "{{" && hasnt "$RD/web/supervisor/prompt.md" "{{"'
D1A=$(grep '^pubkey=' "$RD/web/assistant/agent.conf" | cut -d= -f2)
D1S=$(grep '^pubkey=' "$RD/web/supervisor/agent.conf" | cut -d= -f2)
d1 d1-proof-a proof web assistant "$(sign "$TD/keys/owner.key" "$D1A" '')"
d1 d1-proof-s proof web supervisor "$(sign "$TD/keys/owner.key" "$D1S" '')"
check 'proof from the copied folder (exit 0)' rc_is 0
d1 d1-finish finish web --dry-run
check 'finish --dry-run from the copied folder' eval 'rc_is 0 && has "$OUT/d1-finish.out" "Dry run complete"'
d1 d1-start start web
DPA=$(head -n 1 "$RD/web/assistant/agent.pid" 2>/dev/null) DPS=$(head -n 1 "$RD/web/supervisor/agent.pid" 2>/dev/null)
BG_PIDS="$BG_PIDS $DPA $DPS"
check 'start from the copied folder' eval 'rc_is 0 && alive "$DPA" && alive "$DPS"'
d1 d1-status status web
check 'status from the copied folder' eval 'rc_is 0 && [ "$(grep -c "running on claude, PID" "$OUT/d1-status.out")" = 2 ]'
d1 d1-stop stop web
check 'stop from the copied folder' eval 'rc_is 0 && ! alive "$DPA" && ! alive "$DPS"'
mkdir -p "$TD/linkbin" && ln -s "$CS" "$TD/linkbin/agent-team.sh"
RC=0
env AGENT_TEAM_ROOT="$TD/root-d1b" "$TD/linkbin/agent-team.sh" create --workspace "$TD/ws/docs" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" > "$OUT/d1-link.out" 2>&1 || RC=$?
check 'called through a symbolic link, it still finds its templates' eval 'rc_is 0 && has "$TD/root-d1b/docs/supervisor/prompt.md" "template of the copied folder"'

scenario 'Installer: dry run, install for both tools, repeat, update, other skills untouched (D2)'
IS=$TD/inst-src
mkdir -p "$IS"
cp -Rp "$INSTALLER" "$SKILL_DIR" "$IS/"
HI=$TD/home-inst
for d in .claude .codex; do
    mkdir -p "$HI/$d/skills/other-skill"
    printf -- '---\nname: other-skill\ndescription: An unrelated example skill.\n---\nExample.\n' > "$HI/$d/skills/other-skill/SKILL.md"
done
snap() { (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do if [ -f "$f" ]; then printf '%s %s %s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-16)" "$(stat -f %Lp "$f")"; else printf '%s\n' "$f"; fi; done); }
srcman() { (cd "$1" && find . -type f ! -name .buzz-agent-team-install | LC_ALL=C sort | xargs shasum -a 256); }
inst() { # NAME HOME [VAR=value ...] -- ARGS...
    local name=$1 home=$2 assigns=()
    shift 2
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
    shift
    RC=0
    env HOME="$home" ${assigns[@]+"${assigns[@]}"} "$IS/install.sh" "$@" > "$OUT/$name.out" 2>&1 < /dev/null || RC=$?
}
OTHER_C=$(sha "$HI/.claude/skills/other-skill/SKILL.md") OTHER_X=$(sha "$HI/.codex/skills/other-skill/SKILL.md")
SNAP0=$(snap "$HI")
inst inst-dry "$HI" -- --dry-run
check 'dry run: exit 0, two planned installs' eval 'rc_is 0 && [ "$(grep -c "would install a new copy" "$OUT/inst-dry.out")" = 2 ]'
check 'dry run changed nothing' eval '[ "$(snap "$HI")" = "$SNAP0" ]'
inst inst-1 "$HI" --
CT=$HI/.claude/skills/buzz-agent-team XT=$HI/.codex/skills/buzz-agent-team
check 'install for both tools: exit 0, "installed" twice' eval 'rc_is 0 && [ "$(grep -c "^  installed$" "$OUT/inst-1.out")" = 2 ]'
check 'each copy matches the source file for file' eval '[ "$(srcman "$CT")" = "$(srcman "$IS/buzz-agent-team")" ] && [ "$(srcman "$XT")" = "$(srcman "$IS/buzz-agent-team")" ]'
check 'each copy'"'"'s script is executable' eval '[ -x "$CT/scripts/agent-team.sh" ] && [ -x "$XT/scripts/agent-team.sh" ]'
check 'each copy carries the installer'"'"'s marker' eval '[ -f "$CT/.buzz-agent-team-install" ] && [ -f "$XT/.buzz-agent-team-install" ]'
check 'the other skills are untouched' eval '[ "$(sha "$HI/.claude/skills/other-skill/SKILL.md")" = "$OTHER_C" ] && [ "$(sha "$HI/.codex/skills/other-skill/SKILL.md")" = "$OTHER_X" ] && [ "$(ls -A "$HI/.claude/skills" | tr "\n" " ")" = "buzz-agent-team other-skill " ]'
check 'it prints how to invoke the skill in each tool' eval 'has "$OUT/inst-1.out" "Claude Code: type /buzz-agent-team" && has "$OUT/inst-1.out" "Codex: type \$buzz-agent-team"'
check 'nothing under ~/.buzz-agents' eval '[ ! -e "$HI/.buzz-agents" ]'
RC=0
"$XT/scripts/agent-team.sh" help > "$OUT/inst-run.out" 2>&1 || RC=$?
check 'the installed copy runs' eval 'rc_is 0 && grep -q "^Usage: agent-team.sh" "$OUT/inst-run.out"'
SNAP1=$(snap "$HI")
inst inst-2 "$HI" --
check 'running it again: up to date, nothing changed' eval 'rc_is 0 && [ "$(grep -c "up to date" "$OUT/inst-2.out")" = 2 ] && [ "$(snap "$HI")" = "$SNAP1" ]'
printf '\nAn edit made after the first install.\n' >> "$IS/buzz-agent-team/SKILL.md"
inst inst-3 "$HI" --
check 'after a change in the source: "updated" twice' eval 'rc_is 0 && [ "$(grep -c "^  updated$" "$OUT/inst-3.out")" = 2 ]'
check 'the copies now match the new source' eval 'has "$CT/SKILL.md" "An edit made after the first install." && [ "$(srcman "$XT")" = "$(srcman "$IS/buzz-agent-team")" ]'
check 'no temporary or old copies are left' eval '[ -z "$(ls -A "$HI/.claude/skills" "$HI/.codex/skills" | grep "^\.buzz-agent-team")" ]'

scenario 'Installer: one tool, missing tools, other folders, wrong targets (D2)'
HJ=$TD/home-one
mkdir -p "$HJ/.claude" "$HJ/.codex"
inst inst-claude "$HJ" -- --claude
check '--claude installs only for Claude Code' eval 'rc_is 0 && [ -d "$HJ/.claude/skills/buzz-agent-team" ] && [ ! -e "$HJ/.codex/skills" ]'
inst inst-codex "$HJ" -- --codex
check '--codex installs only for Codex' eval 'rc_is 0 && [ -d "$HJ/.codex/skills/buzz-agent-team" ] && grep -q "^Codex:" "$OUT/inst-codex.out" && ! grep -q "^Claude Code:" "$OUT/inst-codex.out"'
HK=$TD/home-claude-only
mkdir -p "$HK/.claude"
inst inst-auto-one "$HK" --
check 'with no Codex folder, the default installs for Claude Code and says Codex was skipped' eval 'rc_is 0 && [ -d "$HK/.claude/skills/buzz-agent-team" ] && has "$OUT/inst-auto-one.out" "not found; skipped" && [ ! -e "$HK/.codex" ]'
HN=$TD/home-none
mkdir -p "$HN"
inst inst-none "$HN" --
check 'with neither tool folder, it stops with exit 1 and creates nothing' eval 'rc_is 1 && [ -z "$(ls -A "$HN")" ]'
inst inst-agents "$HJ" -- --codex-dir "$HJ/.agents/skills"
check '--codex-dir installs into another skills folder' eval 'rc_is 0 && [ -f "$HJ/.agents/skills/buzz-agent-team/SKILL.md" ]'
mkdir -p "$TD/codex-home"
inst inst-codexhome "$HN" CODEX_HOME="$TD/codex-home" -- --codex
check 'CODEX_HOME chooses the Codex folder' eval 'rc_is 0 && [ -f "$TD/codex-home/skills/buzz-agent-team/SKILL.md" ]'
HW=$TD/home-wrong
mkdir -p "$HW/.claude/skills" "$HW/.codex/skills/buzz-agent-team" "$HW/.agents/skills" "$TD/elsewhere-skill"
printf 'not a skill folder\n' > "$HW/.claude/skills/buzz-agent-team"
printf -- '---\nname: buzz-agent-team\ndescription: Someone else'"'"'s skill with the same name.\n---\n' > "$HW/.codex/skills/buzz-agent-team/SKILL.md"
ln -s "$TD/elsewhere-skill" "$HW/.agents/skills/buzz-agent-team"
SNAPW=$(snap "$HW")
inst inst-wrong-file "$HW" -- --claude
check 'a file where the folder should be: exit 1, clear message, untouched' eval 'rc_is 1 && has "$OUT/inst-wrong-file.out" "a file is where the skill folder should be"'
inst inst-wrong-skill "$HW" -- --codex
check 'a different skill of the same name: exit 1, clear message, untouched' eval 'rc_is 1 && has "$OUT/inst-wrong-skill.out" "a different skill named buzz-agent-team is already at"'
inst inst-wrong-link "$HW" -- --codex-dir "$HW/.agents/skills"
check 'a symbolic link at the target: exit 1, clear message, untouched' eval 'rc_is 1 && has "$OUT/inst-wrong-link.out" "is a symbolic link"'
inst inst-wrong-uninstall "$HW" -- --uninstall --codex
check 'uninstall refuses a skill it did not make' eval 'rc_is 1 && has "$OUT/inst-wrong-uninstall.out" "was not made by this installer"'
check 'every wrong target is byte-identical afterwards' eval '[ "$(snap "$HW")" = "$SNAPW" ]'

scenario 'Installer: an interrupted install leaves the previous copy or nothing; uninstall (D2, rule 5)'
OLDMAN=$(srcman "$CT")
printf '\nA second edit.\n' >> "$IS/buzz-agent-team/SKILL.md"
inst inst-fault1 "$HI" AGENT_TEAM_INSTALL_FAULT=after-stage -- --claude
check 'a failure after staging: exit 1, never success' eval 'rc_is 1 && has "$OUT/inst-fault1.out" "failed" && hasnt "$OUT/inst-fault1.out" "How to use it"'
check 'the previous copy is intact and nothing temporary is left' eval '[ "$(srcman "$CT")" = "$OLDMAN" ] && [ -z "$(ls -A "$HI/.claude/skills" | grep "^\.buzz-agent-team")" ]'
inst inst-fault2 "$HI" AGENT_TEAM_INSTALL_FAULT=after-move-aside -- --claude
check 'killed between its two renames: it did not report success' eval '[ "$RC" != 0 ] && hasnt "$OUT/inst-fault2.out" "updated"'
check 'what remains is nothing at the target and the previous copy aside' eval '[ ! -e "$CT" ] && OLD=$(ls -d "$HI/.claude/skills/".buzz-agent-team.old.* 2>/dev/null | head -n 1) && [ -n "$OLD" ] && [ "$(srcman "$OLD")" = "$OLDMAN" ]'
inst inst-recover "$HI" -- --claude
check 'the next run cleans up and installs (exit 0)' eval 'rc_is 0 && has "$OUT/inst-recover.out" "removed an unfinished copy" && [ "$(srcman "$CT")" = "$(srcman "$IS/buzz-agent-team")" ] && [ -z "$(ls -A "$HI/.claude/skills" | grep "^\.buzz-agent-team")" ]'
SNAPU=$(snap "$HI")
inst inst-un-dry "$HI" -- --uninstall --dry-run
check 'uninstall --dry-run changes nothing' eval 'rc_is 0 && [ "$(snap "$HI")" = "$SNAPU" ] && [ "$(grep -c "would remove it" "$OUT/inst-un-dry.out")" = 2 ]'
inst inst-un "$HI" -- --uninstall
check 'uninstall removes both copies' eval 'rc_is 0 && [ ! -e "$CT" ] && [ ! -e "$XT" ]'
check 'uninstall leaves the other skills alone' eval '[ "$(sha "$HI/.claude/skills/other-skill/SKILL.md")" = "$OTHER_C" ] && [ "$(sha "$HI/.codex/skills/other-skill/SKILL.md")" = "$OTHER_X" ]'
inst inst-un2 "$HI" -- --uninstall
check 'uninstalling again: not installed, exit 0' eval 'rc_is 0 && [ "$(grep -c "not installed" "$OUT/inst-un2.out")" = 2 ]'
check 'no installer run created anything under any ~/.buzz-agents' eval '[ -z "$(ls -d "$TD"/home*/.buzz-agents 2>/dev/null)" ]'
check 'no installer run printed a shell error' eval '! grep -lE "command not found|unbound variable|syntax error|No such file or directory" "$OUT"/inst-*.out >/dev/null'
check 'uninstall names each tool' eval 'grep -q "^Claude Code: " "$OUT/inst-un.out" && grep -q "^Codex: " "$OUT/inst-un.out"'

scenario 'SKILL.md: both tools, guided flow, only real commands and options (D4)'
SK=$SKILL_DIR/SKILL.md
FM=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SK")
check 'front matter opens on line 1 and is closed' eval '[ "$(head -n 1 "$SK")" = "---" ] && [ "$(grep -c "^---$" "$SK")" -ge 2 ]'
check 'front matter has exactly name and description (fields both tools document)' eval '[ "$(printf "%s\n" "$FM" | cut -d: -f1 | sort | tr "\n" " ")" = "description name " ]'
check 'name equals the folder name' eval 'printf "%s\n" "$FM" | grep -qx "name: $(basename "$SKILL_DIR")"'
DESC=$(printf '%s\n' "$FM" | sed -n 's/^description: //p')
check "description is 1-1024 characters (${#DESC})" eval '[ ${#DESC} -ge 1 ] && [ ${#DESC} -le 1024 ]'
check "SKILL.md is under 500 lines ($(wc -l < "$SK" | tr -d ' '))" eval '[ "$(wc -l < "$SK")" -lt 500 ]'
"$SCRIPT" help > "$OUT/help-all.txt" 2>&1
# The team command has its own help; SKILL.md may name its options too.
/bin/bash "$SKILL_DIR/templates/team.sh" help > "$OUT/help-team.txt" 2>&1
HELP_CMDS=$(grep -oE '^  [a-z][a-z-]+' "$OUT/help-all.txt" | tr -d ' ' | sort -u | tr '\n' ' ')
for c in $(grep -oE 'agent-team\.sh [a-z][a-z-]*' "$SK" | awk '{print $2}' | sort -u); do
    check "SKILL.md command exists in help: $c" eval 'case " $HELP_CMDS help " in *" $c "*) true ;; *) false ;; esac'
done
for o in $(grep -oE -- '--[a-z][a-z-]*' "$SK" | sort -u); do
    case $o in --relay | --add-dir | --help | --prefix | --save-exact | --text) continue ;; esac   # buzz --relay, the tools' --add-dir, codex --help, npm, claude auth status --text
    check "SKILL.md option exists in help: $o" grep -qE -- "(^|[^a-z-])$o([^a-z-]|\$)" "$OUT/help-all.txt" "$OUT/help-team.txt"
done
check 'the flow starts with preflight' eval 'awk "/^## Flow/{f=1} f && /^1\\./{print; exit}" "$SK" | grep -q "agent-team.sh preflight"'
for phrase in 'agent-team.sh create' 'agent-team.sh proof' 'agent-team.sh start' 'agent-team.sh status' 'one question per message' 'whether to remember these values' \
    'right after the first preflight, before any command writes' '`<agent>` is `assistant` or `supervisor`' \
    'paired the CLI with Buzz Desktop already' 'team.sh check`' "Agents are started with the team's own command" 'show the values it printed' 'agent-team.sh settings --from-env' 'Authorize external identity' \
    'signature: FAILED' '--no-signature-check' 'Never read, print, copy, move or upload a key file' '.env.buzz-acp.local' \
    'agent-team.sh finish <name> --dry-run' 'in their own terminal' 'chmod +x' '${CLAUDE_SKILL_DIR}' 'buzz-agent-team/SKILL.md'; do
    check "skill covers: $phrase" has "$SK" "$phrase"
done
for tool in 'Claude Code' 'Codex'; do
    sec=$(awk -v h="### $tool" '$0 == h { f = 1; next } f && /^##/ { exit } f { print }' "$SK")
    check "$tool section covers ~/.buzz-agents, finish and start" eval 'printf "%s" "$sec" | grep -q "~/.buzz-agents" && printf "%s" "$sec" | grep -q "finish" && printf "%s" "$sec" | grep -q "start"'
    check "$tool section: every statement carries a source or says not checked" \
        eval '[ -z "$(printf "%s\n" "$sec" | grep "^- " | grep -vE "Source: https://|not checked|codex --help")" ]'
done
check 'README covers the installer, update, uninstall and the refused-proof path' \
    eval 'has "$HERE/README.md" "install.sh" && has "$HERE/README.md" "--uninstall" && has "$HERE/README.md" ".codex/skills" && has "$HERE/README.md" ".claude/skills" && has "$HERE/README.md" "--no-signature-check"'


scenario 'A backend per role, saved per agent; one-run override; a switch for a running agent stops (F1)'
RB=$TD/root-backend
mkdir -p "$TD/ws/mixed"
run_tool mix-create AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/mixed" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --assistant-backend codex --supervisor-model claude-opus-5-5
MA=$RB/mixed/assistant MS=$RB/mixed/supervisor
check 'per-role backends: agent.conf and the env file agree' eval 'rc_is 0 && grep -qx backend=codex "$MA/agent.conf" && has "$MA/.env.buzz-acp.local" "runtime/codex-acp" && grep -qx backend=claude "$MS/agent.conf" && grep -qx BUZZ_ACP_AGENT_COMMAND=claude-agent-acp "$MS/.env.buzz-acp.local"'
check 'per-role model saved for its backend only' eval 'grep -qx model_claude=claude-opus-5-5 "$MS/agent.conf" && grep -qx model_codex= "$MS/agent.conf" && grep -qx BUZZ_MODEL_CLAUDE=claude-opus-5-5 "$MS/.env.buzz-acp.local"'
for a in assistant supervisor; do f=$RB/mixed/$a/.env.buzz-acp.local; sed "s/^BUZZ_AUTH_TAG=.*/BUZZ_AUTH_TAG=[\"auth\",\"$OWNER\",\"created_at<9999999999\",\"$(printf '%0128d' 1)\"]/" "$f" > "$f.t" && mv "$f.t" "$f"; done
run_tool mix-status AGENT_TEAM_ROOT="$RB" -- status mixed
check 'status shows each agent'"'"'s backend, model and sign-in mode' eval 'has "$OUT/mix-status.out" "backend codex, model runtime default; sign-in: your ChatGPT sign-in only" && has "$OUT/mix-status.out" "backend claude, model claude-opus-5-5; sign-in: your Claude subscription only"'
run_tool mix-check AGENT_TEAM_ROOT="$RB" -- start mixed --backend claude --check
check 'start --backend reaches the launcher for every agent (SEL1)' eval 'rc_is 0 && [ "$(grep -c "stand-in launcher: args --check --backend claude" "$OUT/mix-check.out")" = 2 ]'
run_tool mix-check-saved AGENT_TEAM_ROOT="$RB" -- start mixed --check
check 'without --backend each agent gets its saved backend' eval 'rc_is 0 && has "$OUT/mix-check-saved.out" "args --check --backend codex" && has "$OUT/mix-check-saved.out" "args --check --backend claude"'
# In a terminal, start asks for the backend, then the model; Enter keeps the saved one (F12).
cat > "$TD/pty-answer.py" <<'EOF'
import os, pty, select, sys, time
out, rest = sys.argv[1], sys.argv[2:]
cut = rest.index("--")
pairs, cmd = rest[:cut], rest[cut + 1:]
answers = [(pairs[k].encode(), pairs[k + 1].encode() + b"\n") for k in range(0, len(pairs), 2)]
pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)
buf, seen, deadline = b"", 0, time.time() + 60
while time.time() < deadline:
    if not select.select([fd], [], [], 1)[0]:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if answers and answers[0][0] in buf[seen:]:
        seen = len(buf)
        os.write(fd, answers.pop(0)[1])
else:
    os.kill(pid, 9)
status = os.waitpid(pid, 0)[1]
open(out, "wb").write(buf)
sys.exit(os.waitstatus_to_exitcode(status))
EOF
tty_start() { # NAME BACKEND_ANSWER MODEL_ANSWER ARGS...
    local name=$1 b=$2 m=$3
    shift 3
    RC=0
    env AGENT_TEAM_ROOT="$RB" python3 -I "$TD/pty-answer.py" "$OUT/$name.out" 'Backend for' "$b" 'Model for this run' "$m" -- /bin/bash "$SCRIPT" "$@" || RC=$?
}
tty_start tty-switch 2 '' start mixed supervisor --check
check 'in a terminal: backend, then model, saved model shown for that backend; Enter keeps it' eval 'rc_is 0 && has "$OUT/tty-switch.out" "Backend for supervisor" && has "$OUT/tty-switch.out" "saved for supervisor on codex: runtime default" && has "$OUT/tty-switch.out" "args --check --backend codex" && hasnt "$OUT/tty-switch.out" "--model"'
tty_start tty-keep '' '' start mixed supervisor --check
check 'in a terminal, Enter twice keeps the saved backend and model' eval 'rc_is 0 && has "$OUT/tty-keep.out" "saved for supervisor on claude: claude-opus-5-5" && has "$OUT/tty-keep.out" "args --check --backend claude" && hasnt "$OUT/tty-keep.out" "--model"'
tty_start tty-model '' sonnet start mixed supervisor --check
check 'a model typed at the prompt is checked and passed for this run' eval 'rc_is 0 && has "$OUT/tty-model.out" "args --check --backend claude --model sonnet"'
tty_start tty-bad '' gpt-example-sol start mixed supervisor --check
check 'a model the backend does not offer is refused at the prompt' eval 'rc_is 1 && has "$OUT/tty-bad.out" "not a claude model offered for the supervisor"'
run_tool mix-badmodel AGENT_TEAM_ROOT="$RB" -- start mixed supervisor --model gpt-example-sol --check
check 'start --model refuses a model the backend does not offer' eval 'rc_is 1 && has "$OUT/mix-badmodel.out" "not a claude model"'
run_tool mix-start AGENT_TEAM_ROOT="$RB" -- start mixed
check 'start records the backend each agent runs on' eval 'rc_is 0 && [ "$(sed -n 3p "$MA/agent.pid")" = codex ] && [ "$(sed -n 3p "$MS/agent.pid")" = claude ]'
check 'the running launcher is given each agent'"'"'s backend (SEL1, the run path)' eval 'has "$MA/agent.log" "stand-in launcher: args --run --backend codex" && has "$MS/agent.log" "stand-in launcher: args --run --backend claude"'
run_tool mix-switch AGENT_TEAM_ROOT="$RB" -- start mixed --backend claude
check 'a switch for a running agent stops start with a clear message (T-9 defect 3)' eval 'rc_is 1 && has "$OUT/mix-switch.out" "assistant is running as PID" && has "$OUT/mix-switch.out" "on codex, not claude" && has "$OUT/mix-switch.out" "nothing was started"'
run_tool mix-same AGENT_TEAM_ROOT="$RB" -- start mixed supervisor --backend claude
check 'the same backend for a running agent is just "already running"' eval 'rc_is 0 && has "$OUT/mix-same.out" "already running"'
run_tool mix-stop AGENT_TEAM_ROOT="$RB" -- stop mixed
check 'stop ends both' rc_is 0

scenario 'The launcher: subscription sign-in only, per-backend runtime and model (F2, F3, F12)'
if [ -n "$REAL_LAUNCHER" ]; then
    lc() { (cd "$1" && shift && env -u BUZZ_PRIVATE_KEY "$@" "$REAL_LAUNCHER" --check ${LC_ARGS:-}) > "$OUT/lc.out" 2>&1; RC=$?; }
    LC_ARGS='' lc "$MS"
    check 'Claude supervisor: subscription sign-in, model via ANTHROPIC_MODEL, no gateway line' eval 'rc_is 0 && has "$OUT/lc.out" "Sign-in:      Claude subscription (max)" && has "$OUT/lc.out" "Model:        claude-opus-5-5 (ANTHROPIC_MODEL" && hasnt "$OUT/lc.out" "Base URL"'
    LC_ARGS='--backend codex' lc "$MS"
    check 'switching the supervisor to codex sends no Claude model (its codex model: runtime default)' eval 'rc_is 0 && has "$OUT/lc.out" "Model:        runtime default" && has "$OUT/lc.out" "Sign-in:      Codex with your ChatGPT sign-in" && has "$OUT/lc.out" "Runtime:      $BIN/codex-acp"'
    LC_ARGS='--backend claude' lc "$MA"
    check 'the partner switches inside its own runtime folder (SEL2)' eval 'rc_is 0 && has "$OUT/lc.out" "Runtime:      $MA/runtime/claude-agent-acp"'
    (env BUZZ_PRIVATE_KEY=example-not-a-key BUZZ_AUTH_TAG=example-tag RUN_BUZZ_ACP_KEY_FILE=/nonexistent "$MA/runtime/claude-agent-acp" --cli env-check) > "$OUT/rt-env.out" 2>&1; RC=$?
    check 'the partner runtime passes no agent secret to the model runtime' eval 'rc_is 0 && has "$OUT/rt-env.out" "env-check done" && hasnt "$OUT/rt-env.out" leaked'
    mkdir -p "$TD/oldacp"; printf '#!/bin/bash\necho "@agentclientprotocol/codex-acp 1.12.0"\n' > "$TD/oldacp/codex-acp"; chmod 755 "$TD/oldacp/codex-acp"
    (PATH="$TD/oldacp:$PATH" "$MA/runtime/codex-acp" --check-runtime) > "$OUT/rt-oldacp.out" 2>&1; RC=$?
    check 'the Codex partner refuses an untested codex-acp version' eval '[ "$RC" != 0 ] && has "$OUT/rt-oldacp.out" "requires @agentclientprotocol/codex-acp@1.13.1"'
    LC_ARGS='' lc "$MS" ANTHROPIC_API_KEY=example-not-a-key CLAUDE_CODE_OAUTH_TOKEN=example-not-a-token
    check 'exported credentials are removed for the agent (names only)' eval 'rc_is 0 && has "$OUT/lc.out" "Removed:      ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN" && hasnt "$OUT/lc.out" example-not-a'
    LC_ARGS='--backend codex' lc "$MS" CODEX_CONFIG='{"openai_base_url": "https://gateway.example.org"}' OPENAI_API_KEY=example-not-a-key
    check 'a Codex config override and key from this shell are removed too (names only)' eval 'rc_is 0 && has "$OUT/lc.out" "Removed:      CODEX_CONFIG OPENAI_API_KEY" && hasnt "$OUT/lc.out" gateway.example.org'

    echo api_key > "$HOME/.claude/fake-auth"; LC_ARGS='' lc "$MS"; echo claude.ai > "$HOME/.claude/fake-auth"
    check 'a Claude sign-in that is not the subscription is refused' eval 'rc_is 1 && has "$OUT/lc.out" "\"api_key\", not your Claude subscription"'
    echo none > "$HOME/.claude/fake-auth"; LC_ARGS='' lc "$MS"; echo claude.ai > "$HOME/.claude/fake-auth"
    check 'no Claude sign-in is refused with the fix' eval 'rc_is 1 && has "$OUT/lc.out" "claude auth login"'
    printf '{"env": {"ANTHROPIC_BASE_URL": "https://gateway.example.org"}}\n' > "$HOME/.claude/settings.json"; LC_ARGS='' lc "$MS"; rm -f "$HOME/.claude/settings.json"
    check 'a gateway in the user'"'"'s Claude settings is refused (names only)' eval 'rc_is 1 && has "$OUT/lc.out" "sets ANTHROPIC_BASE_URL" && hasnt "$OUT/lc.out" gateway.example.org'
    mkdir -p "$TD/ws/mixed/.claude"; printf '{"apiKeyHelper": "/bin/echo"}\n' > "$TD/ws/mixed/.claude/settings.local.json"; LC_ARGS='' lc "$MS"; rm -rf "$TD/ws/mixed/.claude"
    check 'an apiKeyHelper in the project'"'"'s local settings is refused' eval 'rc_is 1 && has "$OUT/lc.out" "sets apiKeyHelper"'
    mkdir -p "$TD/managed"; printf '{"env": {"CLAUDE_CODE_USE_BEDROCK": "1"}}\n' > "$TD/managed/managed-settings.json"; LC_ARGS='' lc "$MS" BUZZ_CLAUDE_MANAGED_DIR="$TD/managed"
    check 'a provider switch in managed settings is refused' eval 'rc_is 1 && has "$OUT/lc.out" "sets CLAUDE_CODE_USE_BEDROCK"'
    echo none > "$HOME/.codex/fake-login"; LC_ARGS='' lc "$MA"; echo chatgpt > "$HOME/.codex/fake-login"
    check 'the Codex partner without a ChatGPT sign-in is refused' eval 'rc_is 1 && has "$OUT/lc.out" "codex login"'
    printf 'model_provider = "example-gateway"\n' > "$HOME/.codex/config.toml"; LC_ARGS='' lc "$MA"; rm -f "$HOME/.codex/config.toml"
    check 'a non-OpenAI Codex provider is refused' eval 'rc_is 1 && has "$OUT/lc.out" "sets model_provider"'
    cp "$MS/.env.buzz-acp.local" "$TD/sub-extra.env"; echo 'ANTHROPIC_AUTH_TOKEN=example-not-a-token' >> "$TD/sub-extra.env"
    LC_ARGS="--env-file $TD/sub-extra.env" lc "$MS"
    check 'an env file with a credential is refused in subscription mode' eval 'rc_is 1 && has "$OUT/lc.out" "sets ANTHROPIC_AUTH_TOKEN" && hasnt "$OUT/lc.out" example-not-a-token'
    sed 's/^BUZZ_ACP_PERMISSION_MODE=.*/BUZZ_ACP_PERMISSION_MODE=dont-ask/' "$MA/.env.buzz-acp.local" > "$TD/dontask.env"
    LC_ARGS="--env-file $TD/dontask.env --backend claude" lc "$MA"
    check 'dont-ask is refused, never skipped without a message (T-9 defect 2)' eval 'rc_is 1 && has "$OUT/lc.out" "offers no dontAsk mode"'
    LC_ARGS='--model gpt-example-sol' lc "$MS"
    check 'the launcher refuses a non-Claude model for a Claude agent' eval 'rc_is 1 && has "$OUT/lc.out" "is not a Claude model"'
else
    skip 'AGENT_TEAM_REAL_LAUNCHER not set'
fi

scenario 'Preflight per role: subscription sign-in and settings overrides (F2, F3)'
run_tool pf-mixed AGENT_TEAM_ROOT="$RB" -- preflight mixed
check 'preflight of a team checks each role on its saved backend and own runtime' eval 'rc_is 0 && has "$OUT/pf-mixed.out" "Role assistant (discussion partner): codex" && has "$OUT/pf-mixed.out" "Role supervisor: claude" && has "$OUT/pf-mixed.out" "$MA/runtime/codex-acp" && has "$OUT/pf-mixed.out" "your Claude subscription (max)"'
echo oauth_token > "$HOME/.claude/fake-auth"; run_tool pf-token AGENT_TEAM_ROOT="$RB" -- preflight --backend claude; echo claude.ai > "$HOME/.claude/fake-auth"
check 'preflight fails a token sign-in with a fix line' eval 'rc_is 1 && has "$OUT/pf-token.out" "uses oauth_token, not your Claude subscription" && has "$OUT/pf-token.out" "fix: remove that credential"'
run_tool pf-exported ANTHROPIC_API_KEY=example-not-a-key AGENT_TEAM_ROOT="$RB" -- preflight --backend claude
check 'a key exported in this shell is named and removed before the sign-in check, as the launcher does' eval 'rc_is 0 && has "$OUT/pf-exported.out" "exports ANTHROPIC_API_KEY; the launcher removes them" && hasnt "$OUT/pf-exported.out" "uses api_key" && [ "$(grep -c "your Claude subscription (max)" "$OUT/pf-exported.out")" = 2 ]'
printf '{"apiKeyHelper": "/bin/echo", "env": {"ANTHROPIC_AUTH_TOKEN": "x"}}\n' > "$HOME/.claude/settings.json"; run_tool pf-settings AGENT_TEAM_ROOT="$RB" -- preflight --backend claude; rm -f "$HOME/.claude/settings.json"
check 'preflight fails settings overrides, names only' eval 'rc_is 1 && has "$OUT/pf-settings.out" "sets ANTHROPIC_AUTH_TOKEN apiKeyHelper"'
echo none > "$HOME/.codex/fake-login"; run_tool pf-codex AGENT_TEAM_ROOT="$RB" -- preflight --backend codex; echo chatgpt > "$HOME/.codex/fake-login"
check 'preflight fails Codex without ChatGPT for both roles' eval 'rc_is 1 && [ "$(grep -c "not signed in with ChatGPT" "$OUT/pf-codex.out")" = 2 ]'
# The supervisor's Codex sign-in is asked of the CLI its stock adapter runs (codex-acp cli), not of a codex on PATH.
NOCODEX=$TD/nocodex-bin; mkdir -p "$NOCODEX"
for f in "$BIN"/*; do [ "${f##*/}" = codex ] || ln -sf "$f" "$NOCODEX/"; done
ln -sf "$(command -v python3)" "$NOCODEX/python3"
run_tool pf-nocodex PATH="$NOCODEX:/usr/bin:/bin:/usr/sbin:/sbin" AGENT_TEAM_ROOT="$RB" -- preflight --assistant-backend claude --supervisor-backend codex
check 'preflight asks the supervisor'"'"'s own Codex CLI: no codex on PATH needed' eval 'has "$OUT/pf-nocodex.out" "Role supervisor: codex" && hasnt "$OUT/pf-nocodex.out" "not signed in with ChatGPT" && has "$OUT/pf-nocodex.out" "Codex sign-in"'
if [ -n "$REAL_LAUNCHER" ]; then
    (cd "$MS" && env -u BUZZ_PRIVATE_KEY PATH="$NOCODEX:/usr/bin:/bin:/usr/sbin:/sbin" "$REAL_LAUNCHER" --check --backend codex) > "$OUT/lc-nocodex.out" 2>&1; RC=$?
    check 'the launcher asks the Codex supervisor'"'"'s own CLI: no codex on PATH needed' eval 'rc_is 0 && has "$OUT/lc-nocodex.out" "Sign-in:      Codex with your ChatGPT sign-in"'
fi

scenario 'Model lists: list, empty, error, hang; the checks use the list (F12, F13)'
mm() { local mode=$1 name=$2; shift 2; echo "$mode" > "$HOME/.fake-acp-mode"; run_tool "$name" AGENT_TEAM_ROOT="$RB" AGENT_TEAM_MODELS_TIMEOUT=2 -- models "$@"; }
mm list ml-claude --backend claude
LIST=$RB/models/claude-supervisor.list
check 'a list: exit 0, every model shown, claude-opus-5-5 marked, kept with mode 600' eval 'rc_is 0 && has "$OUT/ml-claude.out" "claude-opus-5-5   Opus 5.5   (live-test default)" && [ "$(mode_of "$LIST")" = 600 ] && [ "$(grep -vc "^#" "$LIST")" = 4 ]'
mm list-no-opus ml-noopus --backend claude --role assistant
check 'without claude-opus-5-5 by name, the run says how Opus 5.5 is offered' eval 'rc_is 0 && has "$OUT/ml-noopus.out" "claude-opus-5-5 is not listed by that name; the list offers Opus 5.5 as opus"'
mm empty ml-empty --backend codex
check 'an empty list is not success: exit 1, the reason, the documented list of the CLI that role runs' eval 'rc_is 1 && has "$OUT/ml-empty.out" "empty model list" && has "$OUT/ml-empty.out" "Documented list instead" && has "$OUT/ml-empty.out" gpt-example-old && hasnt "$OUT/ml-empty.out" gpt-example-sol && [ ! -e "$RB/models/codex-supervisor.list" ]'
mm error ml-error --backend codex
check 'an adapter error names the cause (not signed in)' eval 'rc_is 1 && has "$OUT/ml-error.out" "not signed in"'
mm nomodels ml-none --backend claude --role supervisor mixed
check 'an adapter that reports no models says so' eval 'rc_is 1 && has "$OUT/ml-none.out" "does not report models"'
T0=$(date +%s); mm hang ml-hang --backend claude; T1=$(date +%s)
check 'a hanging adapter is stopped at the bound, once, with the reason' eval 'rc_is 1 && has "$OUT/ml-hang.out" "did not answer within 2 s" && [ $((T1 - T0)) -le 15 ] && [ -z "$(pgrep -f "$BIN/acp-models-stub.py")" ]'
echo list > "$HOME/.fake-acp-mode"
mkdir -p "$TD/ws/models-ws"
run_tool mod-refuse AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/models-ws" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER" --supervisor-model claude-haiku-5-5
check 'create refuses a Claude model the retrieved list does not offer' eval 'rc_is 1 && has "$OUT/mod-refuse.out" "is not a claude model offered for the supervisor" && [ ! -e "$RB/models-ws" ]'
run_tool mod-codex AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/models-ws" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER" --backend codex --assistant-model gpt-example-hidden
check 'with no retrieved Codex list, the bundled catalog decides: a hidden model is refused' eval 'rc_is 1 && has "$OUT/mod-codex.out" "not a codex model"'
run_tool mod-codex-sup AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/models-ws" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER" --backend codex --supervisor-model gpt-example-sol
check 'the supervisor is checked against the CLI its adapter bundles, not the partner'"'"'s' eval 'rc_is 1 && has "$OUT/mod-codex-sup.out" "not a codex model offered for the supervisor" && [ ! -e "$RB/models-ws" ]'
run_tool mod-ok AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/models-ws" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER" --assistant-backend codex --assistant-model gpt-example-sol --supervisor-model opus
check 'listed models are accepted and saved per backend' eval 'rc_is 0 && grep -qx model_codex=gpt-example-sol "$RB/models-ws/assistant/agent.conf" && grep -qx model_claude=opus "$RB/models-ws/supervisor/agent.conf"'
run_tool mod-upg AGENT_TEAM_ROOT="$RB" -- upgrade models-ws --supervisor-model sonnet
check 'upgrade sets a listed model and keeps the other backend'"'"'s slot' eval 'rc_is 0 && grep -qx model_claude=sonnet "$RB/models-ws/supervisor/agent.conf" && grep -qx model_codex=gpt-example-sol "$RB/models-ws/assistant/agent.conf"'
run_tool mod-upg-bad AGENT_TEAM_ROOT="$RB" -- upgrade models-ws --supervisor-model claude-haiku-5-5
check 'upgrade refuses an unlisted model and changes nothing' eval 'rc_is 1 && grep -qx model_claude=sonnet "$RB/models-ws/supervisor/agent.conf"'
# A team record still at format 1 (an upgrade stopped before its last step) is refused even when its agents are current.
cp -p "$RB/models-ws/team.conf" "$TD/team.conf.keep"; sed 's/^format=2$/format=1/' "$TD/team.conf.keep" > "$RB/models-ws/team.conf"
run_tool mod-team1 AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/models-ws" --channel "$CHANNEL2" --community "$COMMUNITY" --owner "$OWNER"
check 'create refuses a format-1 team record even with current agents' eval 'rc_is 1 && has "$OUT/mod-team1.out" "upgrade models-ws"'
cp -p "$TD/team.conf.keep" "$RB/models-ws/team.conf"
run_tool mod-upg-dry AGENT_TEAM_ROOT="$RB" -- upgrade models-ws --dry-run --supervisor-model opus
check 'the dry run shows the model change and repeats the model option in its run line' eval 'rc_is 0 && has "$OUT/mod-upg-dry.out" "model (claude): sonnet -> opus" && has "$OUT/mod-upg-dry.out" "Run it: agent-team.sh upgrade models-ws --supervisor-model opus" && grep -qx model_claude=sonnet "$RB/models-ws/supervisor/agent.conf"'

scenario 'Two teams in one channel: each partner ignores the other team'"'"'s agents (F6, rule 9)'
mkdir -p "$TD/ws/second"
run_tool second AGENT_TEAM_ROOT="$RB" -- create --workspace "$TD/ws/second" --channel "$CHANNEL" --community "$COMMUNITY" --owner "$OWNER" --name second --assistant-name 'Second' --supervisor-name 'Second Lead'
R2=$RB/second/assistant/subscriptions.toml
check 'the new partner'"'"'s channel rule names the other team'"'"'s agents too' eval 'rc_is 0 && has "$R2" "author != \"$(grep ^pubkey= "$MA/agent.conf" | cut -d= -f2)\"" && has "$R2" "author != \"$(grep ^pubkey= "$MS/agent.conf" | cut -d= -f2)\""'
check 'create says the earlier partner must be refreshed with upgrade' has "$OUT/second.out" 'until: agent-team.sh upgrade mixed'
run_tool second-upg AGENT_TEAM_ROOT="$RB" -- upgrade mixed
check 'after upgrade the earlier partner ignores the new team'"'"'s agents' eval 'rc_is 0 && has "$MA/subscriptions.toml" "author != \"$(grep ^pubkey= "$RB/second/supervisor/agent.conf" | cut -d= -f2)\""'

scenario 'Secrets: a final sweep of every output and log (C3)'
check 'no secret key in any captured output, log or record' no_key_in "$OUT"/* "$TD"/root*/*/*/agent.log* "$TD"/root*/*/*/.env.buzz-acp.local "$TD"/root*/*/*/prompt.md "$TD"/root*/*/*/agent.conf "$TD"/root*/*/team.conf "$TD"/root*/settings.conf
if [ -n "$REAL_LAUNCHER" ]; then
    check 'the accepted launcher is byte-identical after the tests' eval '[ "$(sha "$REAL_LAUNCHER")" = "$LAUNCHER_SHA_BEFORE" ]'
fi

for p in $BG_PIDS; do
    if [ -n "$p" ] && alive "$p"; then kill -KILL "$p" 2>/dev/null; fi
done
left=$(pgrep -f "$TD/bin/" 2>/dev/null | tr '\n' ' ')
check 'no test process is left running' eval '[ -z "$left" ]'

printf '\nScenarios: %d   checks passed: %d   failed: %d   skipped: %d\n' "$SCEN" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
