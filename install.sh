#!/bin/bash
# install.sh: install the buzz-agent-team skill into Claude Code and Codex. Bash 3.2+.
#
#   install.sh                 install or update the skill for every tool found on this machine
#   install.sh --claude        Claude Code only    (~/.claude/skills/buzz-agent-team)
#   install.sh --codex         Codex only          ($CODEX_HOME/skills/buzz-agent-team, default ~/.codex)
#   install.sh --dry-run       print what would change; change nothing
#   install.sh --uninstall     remove the copies this installer made
#   --claude-dir DIR, --codex-dir DIR   use another skills folder (for example ~/.agents/skills)
#
# It copies the buzz-agent-team folder that sits beside this script, and prints the skill's version
# (the VERSION file in that folder) beside the version of the copy it replaces. Each copy is built
# beside its target and renamed into place, so an interrupted run leaves the previous copy or
# nothing. It only touches <skills folder>/buzz-agent-team and its own temporary names there, and
# refuses a target it did not make. It never touches ~/.buzz-agents.

set -euo pipefail
umask 022

NAME=buzz-agent-team
MARKER=.buzz-agent-team-install
PROG=install.sh
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: install.sh [--claude] [--codex] [--claude-dir DIR] [--codex-dir DIR] [--dry-run] [--uninstall]

Installs (or updates) the buzz-agent-team skill folder for Claude Code and Codex.
  --claude          Claude Code only: ~/.claude/skills/buzz-agent-team
  --codex           Codex only: $CODEX_HOME/skills/buzz-agent-team (CODEX_HOME defaults to ~/.codex)
                    With neither, every tool whose folder exists (~/.claude, ~/.codex) is used.
  --claude-dir DIR  use DIR as Claude Code's skills folder (implies --claude)
  --codex-dir DIR   use DIR as Codex's skills folder (implies --codex), for example ~/.agents/skills
  --dry-run         print what would change; change nothing
  --uninstall       remove copies made by this installer; anything else is left alone
  -h, --help        show this help
Running it again updates an existing copy, or says it is up to date.
EOF
}

HERE=$(cd -P -- "$(dirname -- "$0")" && pwd)
SRC=$HERE/$NAME
want_claude=no want_codex=no claude_dir='' codex_dir='' dry=no mode=install
while [ "$#" -gt 0 ]; do
    case $1 in
        --claude) want_claude=yes ;;
        --codex) want_codex=yes ;;
        --claude-dir) [ "$#" -ge 2 ] && [ -n "$2" ] || die '--claude-dir needs a folder'; claude_dir=$2; want_claude=yes; shift ;;
        --codex-dir) [ "$#" -ge 2 ] && [ -n "$2" ] || die '--codex-dir needs a folder'; codex_dir=$2; want_codex=yes; shift ;;
        --dry-run) dry=yes ;;
        --uninstall) mode=uninstall ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see install.sh --help)" ;;
    esac
    shift
done
[ -n "${HOME:-}" ] || die 'HOME is not set'
case $HOME in /*) ;; *) die "HOME must be an absolute path (got: $HOME)" ;; esac

# The version a skill folder holds: the one line of its VERSION file, MAJOR.MINOR.PATCH.
version_of() { # DIR
    local v=''
    [ -f "$1/VERSION" ] || return 1
    IFS= read -r v < "$1/VERSION" || [ -n "$v" ] || return 1
    printf '%s\n' "$v" | grep -Eqx '(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)' || return 1
    printf '%s' "$v"
}

# The source must be a complete skill folder before anything is changed.
VERSION=''
if [ "$mode" = install ]; then
    [ -f "$SRC/SKILL.md" ] || die "the skill folder is missing or incomplete: $SRC/SKILL.md not found"
    VERSION=$(version_of "$SRC") || die "the skill folder has no valid VERSION file: $SRC/VERSION"
    [ "$(sed -n '1p' "$SRC/SKILL.md")" = '---' ] && grep -qx "name: $NAME" "$SRC/SKILL.md" ||
        die "$SRC/SKILL.md does not declare name: $NAME"
    [ -f "$SRC/scripts/agent-team.sh" ] || die "missing $SRC/scripts/agent-team.sh"
    for t in agent supervisor reviewer project; do
        [ -f "$SRC/templates/$t.md" ] || die "missing $SRC/templates/$t.md"
    done
    [ -f "$SRC/templates/subscriptions.toml" ] || die "missing $SRC/templates/subscriptions.toml"
    [ -f "$SRC/templates/team.sh" ] || die "missing $SRC/templates/team.sh"
    [ -f "$SRC/templates/agent-start.sh" ] || die "missing $SRC/templates/agent-start.sh"
    [ -f "$SRC/templates/agent-restart.sh" ] || die "missing $SRC/templates/agent-restart.sh"
    for t in workspace-settings.py workspace-browser.py acp-models.py run-buzz-acp.sh; do
        [ -f "$SRC/scripts/$t" ] || die "missing $SRC/scripts/$t"
    done
fi

# A sorted list of "sha256  path" for every file under DIR except the install marker.
manifest() {
    (cd -- "$1" && find . -type f ! -name "$MARKER" | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -c1-64)" "${f#./}"
    done)
}
ours() { [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/$MARKER" ] && grep -qx "installer=$NAME" "$1/$MARKER"; }

# Remove leftovers of an interrupted run of this installer (only folders that carry the marker).
clean_leftovers() { # SKILLS_DIR
    local d
    for d in "$1"/.$NAME.new.* "$1"/.$NAME.old.*; do
        [ -e "$d" ] || continue
        if ours "$d"; then
            if [ "$dry" = yes ]; then say "  would remove an unfinished copy: $d"
            else rm -rf -- "$d"; say "  removed an unfinished copy from an earlier run: $d"; fi
        else
            say "  left alone (not made by this installer): $d"
        fi
    done
}

STAGE=''
trap '[ -z "$STAGE" ] || rm -rf -- "$STAGE"' EXIT

label() { case $1 in claude) printf 'Claude Code' ;; codex) printf 'Codex' ;; esac; }

install_one() { # TOOL SKILLS_DIR
    local tool=$1 dir=$2 target=$2/$NAME old
    say "$(label "$tool"): $target"
    if [ -L "$target" ]; then say "  refused: $target is a symbolic link; it was not touched. Remove the link or choose another folder."; return 1; fi
    if [ -e "$target" ] && [ ! -d "$target" ]; then say "  refused: a file is where the skill folder should be ($target); it was not touched."; return 1; fi
    if [ -d "$target" ] && ! ours "$target"; then
        say "  refused: a different skill named $NAME is already at $target; it was not touched."
        say "  Move it away, or install elsewhere with --${tool}-dir."
        return 1
    fi
    if [ -d "$dir" ]; then clean_leftovers "$dir"; fi
    if [ -d "$target" ]; then say "  version $VERSION (installed: $(version_of "$target" || printf 'no version recorded'))"
    else say "  version $VERSION"; fi
    if [ -d "$target" ] && [ "$(manifest "$target")" = "$(manifest "$SRC")" ]; then
        say "  up to date; nothing changed"
        return 0
    fi
    if [ "$dry" = yes ]; then
        if [ -d "$target" ]; then say "  would update the installed copy"; else say "  would install a new copy"; fi
        return 0
    fi
    mkdir -p -- "$dir" || { say "  failed: cannot create $dir"; return 1; }
    STAGE=$(mktemp -d "$dir/.$NAME.new.XXXXXX") || { say "  failed: cannot write in $dir"; return 1; }
    cp -R "$SRC/." "$STAGE/" || { say "  failed: copying the skill folder"; return 1; }
    chmod 755 "$STAGE" "$STAGE/scripts" "$STAGE/scripts/agent-team.sh" "$STAGE/scripts/run-buzz-acp.sh"
    { printf 'installer=%s\nformat=1\nversion=%s\nsource=%s\ninstalled=%s\n' "$NAME" "$VERSION" "$SRC" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; manifest "$SRC"; } > "$STAGE/$MARKER"
    [ "$(manifest "$STAGE")" = "$(manifest "$SRC")" ] && [ -x "$STAGE/scripts/agent-team.sh" ] ||
        { say "  failed: the copy does not match the source; nothing was changed"; return 1; }
    [ "${AGENT_TEAM_INSTALL_FAULT:-}" != after-stage ] || { say '  failed: test fault after staging'; return 1; }
    if [ -d "$target" ]; then
        old=$dir/.$NAME.old.$$
        mv -- "$target" "$old" || { say "  failed: cannot move the old copy aside; nothing was changed"; return 1; }
        [ "${AGENT_TEAM_INSTALL_FAULT:-}" != after-move-aside ] || kill -KILL $$
        if ! mv -- "$STAGE" "$target"; then mv -- "$old" "$target"; say "  failed: cannot move the new copy into place; the old copy was restored"; return 1; fi
        STAGE=''
        rm -rf -- "$old"
        say "  updated"
    else
        mv -- "$STAGE" "$target" || { say "  failed: cannot move the new copy into place"; return 1; }
        STAGE=''
        say "  installed"
    fi
}

uninstall_one() { # TOOL SKILLS_DIR
    local tool=$1 dir=$2 target=$2/$NAME old
    say "$(label "$tool"): $target"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        [ ! -d "$dir" ] || clean_leftovers "$dir"
        say "  not installed; nothing to remove"
        return 0
    fi
    if ! ours "$target"; then say "  refused: $target was not made by this installer; it was not touched."; return 1; fi
    clean_leftovers "$dir"
    if [ "$dry" = yes ]; then say "  would remove it"; return 0; fi
    old=$dir/.$NAME.old.$$
    mv -- "$target" "$old" && rm -rf -- "$old" || { say "  failed: could not remove it"; return 1; }
    say "  removed"
}

claude_home=$HOME/.claude
codex_home=${CODEX_HOME:-$HOME/.codex}
targets=''
if [ "$want_claude" = no ] && [ "$want_codex" = no ]; then
    if [ -d "$claude_home" ]; then targets="$targets claude"; else say "Claude Code: $claude_home not found; skipped (use --claude to install anyway)"; fi
    if [ -d "$codex_home" ]; then targets="$targets codex"; else say "Codex: $codex_home not found; skipped (use --codex to install anyway)"; fi
    [ -n "$targets" ] || die 'neither ~/.claude nor the Codex folder exists; choose a tool with --claude or --codex'
else
    [ "$want_claude" = no ] || targets="$targets claude"
    [ "$want_codex" = no ] || targets="$targets codex"
fi
[ "$dry" = no ] || say 'Dry run: nothing is changed.'

failed=0
for tool in $targets; do
    case $tool in
        claude) dir=${claude_dir:-$claude_home/skills} ;;
        codex) dir=${codex_dir:-$codex_home/skills} ;;
    esac
    case $dir in /*) ;; *) dir=$(pwd -P)/$dir ;; esac
    if [ "$mode" = install ]; then install_one "$tool" "$dir" || failed=1
    else uninstall_one "$tool" "$dir" || failed=1; fi
done

if [ "$failed" = 1 ]; then die 'not every target succeeded (see above)'; fi
if [ "$mode" = install ] && [ "$dry" = no ]; then
    say ''
    say 'How to use it:'
    case " $targets " in *' claude '*)
        say '  Claude Code: type /buzz-agent-team, or ask "set up a new set of Buzz agents for <folder>".' ;;
    esac
    case " $targets " in *' codex '*)
        say '  Codex: type $buzz-agent-team (or pick it with /skills), or ask the same. If it does not appear,'
        say '  restart Codex. If it still does not appear, install it with --codex-dir ~/.agents/skills.' ;;
    esac
    say 'Update: run this installer again. Remove: install.sh --uninstall.'
fi
