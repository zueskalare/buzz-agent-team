#!/usr/bin/env bash
# start.sh: start this one agent, and no other. Bash 3.2+.
#
# This file lives in the agent's own folder, beside its key and its settings. The team's command is
# one folder up and does the work, so the check, the sandbox settings and the launcher are the same:
#   <team>/<agent>/start.sh        <team>/team.sh
# Run it from the project folder, as the team's command is:
#   cd ~/code/shop && ~/.buzz-agents/shop/assistant/start.sh
# In a terminal it asks this agent's provider, model and reasoning effort; Enter keeps the saved
# one. The model menu shows the list the provider's adapter offers at that moment. With --yes, or
# without a terminal, it asks nothing and the agent starts on its saved choices. A choice lasts for
# that run; the saved ones are changed with the skill (agent-team.sh upgrade). Stopping and status
# stay with the team's command.

set -uo pipefail

PROG=start.sh
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

HERE=$(CDPATH='' cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd) || die 'cannot find the folder this script is in'
AGENT=${HERE##*/}
TEAM=${HERE%/*}/team.sh
[ -f "$HERE/agent.conf" ] || die "$HERE has no agent.conf; start.sh must stay in its agent folder"
[ -x "$TEAM" ] || die "$TEAM is missing or cannot be run; start.sh needs the team's command one folder up"

usage() {
    cat <<EOF
Usage: start.sh [options]     start the $AGENT of this folder, and no other agent

In a terminal it asks this agent's provider, its model and its reasoning effort; Enter keeps the
saved one. Before the model menu, the provider's adapter is asked which models it offers now.
  --yes                     ask nothing: the saved provider, model and reasoning effort
  --model ID                this model, for this run (no model question)
  --backend claude|codex    this provider, for this run (no provider question)
  --effort LEVEL            this reasoning effort, for this run; default sets none
  --workspace DIR           another project folder than the current one
  --no-wall                 do not put the sandbox settings into the project folder (the workspace agent on Claude)
  --check                   check this agent and start nothing
  --verbose                 also print the launcher's own check

Stop it:  $TEAM stop $AGENT
See it:   $TEAM status
EOF
}

args=()
while [ "$#" -gt 0 ]; do
    case $1 in
        --model | --backend | --effort | --workspace)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
            args+=("$1" "$2"); shift ;;
        --yes | -y | --no-wall | --check | --verbose | -v) args+=("$1") ;;
        help | -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1. This command starts the $AGENT only (see start.sh --help); each other agent has its own start.sh, and the team's command is $TEAM" ;;
    esac
    shift
done
exec "$TEAM" start "$AGENT" ${args[@]+"${args[@]}"}
