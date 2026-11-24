#!/usr/bin/env bash
# restart.sh: start this one agent again as its last run was, and no other. Bash 3.2+.
#
# This file lives in the agent's own folder, beside start.sh, its key and its settings. The team's
# command is one folder up and does the work:
#   <team>/<agent>/restart.sh        <team>/team.sh restart <agent>
# It asks nothing and changes no choice. The provider, the model, the reasoning effort, the project
# folder and, for the workspace agent, the model and the reasoning effort of its workers are those of
# this agent's last run, read from the record of that run in this folder: agent.pid while the agent
# runs or after it ended by itself, agent.last after it was stopped. So it can be run from any folder:
#   ~/.buzz-agents/shop/shop/restart.sh
# An agent that runs is stopped first; then come the check and the start, as for start.sh. An agent
# with no run on record (never started, or last stopped by a version before 5.2.0) is started with
# start.sh. To change a choice, stop the agent and start it with start.sh and the option.

set -uo pipefail

PROG=restart.sh
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

HERE=$(CDPATH='' cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd) || die 'cannot find the folder this script is in'
AGENT=${HERE##*/}
TEAM=${HERE%/*}/team.sh
[ -f "$HERE/agent.conf" ] || die "$HERE has no agent.conf; restart.sh must stay in its agent folder"
# Its display name, for the messages below (agent.conf is public data: name=...).
NAME=$(sed -n 's/^name=//p' "$HERE/agent.conf" | head -n 1)
NAME=${NAME:-$AGENT}
[ -x "$TEAM" ] || die "$TEAM is missing or cannot be run; restart.sh needs the team's command one folder up"

usage() {
    cat <<EOF
Usage: restart.sh [--force] [--verbose]     start $NAME, the agent of this folder, again as its last run was

It asks nothing and changes no choice: the provider, the model, the reasoning effort, the project
folder and, for the workspace agent, its workers are those of its last run. It works whether the
agent runs or was stopped, and from any folder. An agent that runs is stopped first.
  --force                   end the agent when it does not stop in time
  --verbose                 also print the launcher's own check

To change a choice, stop it and start it with the option:
  $TEAM stop $AGENT
  $HERE/start.sh --help
See it:   $TEAM status
EOF
}

args=()
while [ "$#" -gt 0 ]; do
    case $1 in
        --force | --verbose | -v) args+=("$1") ;;
        help | -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1. This command starts $NAME again as its last run was and takes no choice (see restart.sh --help); to change one, stop it and use $HERE/start.sh" ;;
    esac
    shift
done
exec "$TEAM" restart "$AGENT" ${args[@]+"${args[@]}"}
