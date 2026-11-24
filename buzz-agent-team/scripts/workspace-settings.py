#!/usr/bin/env python3
"""Put the settings an agent's backend needs into its project folder, and check them.

    workspace-settings.py apply  [claude|codex] PROJECT_FOLDER    write or complete them
    workspace-settings.py check  [claude|codex] PROJECT_FOLDER    say whether they are in place; change nothing
    workspace-settings.py show   [claude|codex]                   print what this program keeps in place

claude, when the word is left out: the sandbox settings of an agent on the stock Claude adapter,
PROJECT_FOLDER/.claude/settings.json. They are plain Claude Code settings, read by Claude Code itself
from the project folder a session starts in. No program stands between the agent and its adapter:

    "permissions": {
      "blockReadsOutsideWorkingDirectories": true,    the file tools read only inside the project folder
      "blockWritesOutsideWorkingDirectories": true    and write only inside it, in every permission mode
    },
    "sandbox": {
      "enabled": true,                     shell commands run in Claude Code's sandbox: they write only
                                           inside the project folder and a temporary folder, and read
                                           no user folder outside the project folder
      "autoAllowBashIfSandboxed": true,    a sandboxed command needs no approval
      "excludedCommands": ["buzz *"]       a plain buzz command runs outside the sandbox, which has no
                                           direct network; the agent talks to Buzz with that command
    }

What they do not hold, and the agent's prompt asks for instead: a command the agent runs again
outside the sandbox, a buzz command given a file outside the project folder, and folders your own
Claude settings add as working folders. Every Claude Code session started in that folder, your own
included, runs under the same settings. An existing settings.json keeps everything else it holds; the
earlier file is kept beside it as settings.json.bak-<UTC time>. A file that is not a JSON object, or a
symbolic link, is left alone.

codex: the rule file of an agent on the stock Codex adapter, PROJECT_FOLDER/.codex/rules/buzz.rules,
holding one line:

    prefix_rule(pattern = ["buzz"], decision = "allow")

Codex reads the rule files of the project folder, which the stock adapter marks trusted. With the line,
a plain buzz command runs with the network, and Codex's own reviewer is not asked; the agent posts to
Buzz with that command. A line that combines buzz with anything else (a ;, &&, a pipe, sh -c, a
variable set in front) stays in Codex's sandbox, which has no network. Without the line, a buzz command
has no network, and asking to run it outside the sandbox sends it to Codex's own reviewer. An existing
buzz.rules keeps everything else it holds: the line is added at its end, and the earlier file is kept
beside it as buzz.rules.bak-<UTC time>. A file that cannot be read as text, or a symbolic link (the
file, .codex/ or .codex/rules/), is left alone.

Exit status: 0 in place (check) or written (apply); 3 the file is absent (check); 4 it is there
without some of these settings (check); 2 anything that stopped the program.
"""
import json
import os
import sys
import tempfile
import time

SCALARS = (
    ("permissions", "blockReadsOutsideWorkingDirectories", True),
    ("permissions", "blockWritesOutsideWorkingDirectories", True),
    ("sandbox", "enabled", True),
    ("sandbox", "autoAllowBashIfSandboxed", True),
)
EXCLUDED = "buzz *"   # sandbox.excludedCommands must hold this entry
RULE = 'prefix_rule(pattern = ["buzz"], decision = "allow")'   # the line buzz.rules must hold


def fail(message):
    print(f"workspace-settings.py: {message}", file=sys.stderr)
    sys.exit(2)


def required():
    data = {}
    for section, key, value in SCALARS:
        data.setdefault(section, {})[key] = value
    data["sandbox"]["excludedCommands"] = [EXCLUDED]
    return data


def lacking(data):
    """The names of the settings DATA does not hold as required."""
    names = []
    for section, key, value in SCALARS:
        part = data.get(section)
        if not isinstance(part, dict) or part.get(key) is not value:
            names.append(f"{section}.{key}")
    sandbox = data.get("sandbox")
    commands = sandbox.get("excludedCommands") if isinstance(sandbox, dict) else None
    if not isinstance(commands, list) or EXCLUDED not in commands:
        names.append("sandbox.excludedCommands")
    return names


def complete(data, path):
    """DATA with the required settings set; everything else it holds is kept."""
    for section, key, value in SCALARS:
        part = data.setdefault(section, {})
        if not isinstance(part, dict):
            fail(f'{path}: "{section}" is not an object; fix or remove it. Nothing was changed.')
        part[key] = value
    commands = data["sandbox"].setdefault("excludedCommands", [])
    if not isinstance(commands, list):
        fail(f'{path}: "sandbox.excludedCommands" is not a list; fix or remove it. Nothing was changed.')
    if EXCLUDED not in commands:
        commands.append(EXCLUDED)
    return data


def locate(folder, backend):
    """The folders the file goes in, outermost first, and the file itself."""
    if not os.path.isdir(folder):
        fail(f"not a folder: {folder}")
    folder = os.path.realpath(folder)
    if backend == "codex":
        directories = [os.path.join(folder, ".codex"), os.path.join(folder, ".codex", "rules")]
        path = os.path.join(directories[-1], "buzz.rules")
    else:
        directories = [os.path.join(folder, ".claude")]
        path = os.path.join(directories[-1], "settings.json")
    for item in (*directories, path):
        if os.path.islink(item):
            fail(f"{item} is a symbolic link; the settings are not written through one. Nothing was changed.")
    for directory in directories:
        if os.path.exists(directory) and not os.path.isdir(directory):
            fail(f"{directory} is not a folder. Nothing was changed.")
    if os.path.exists(path) and not os.path.isfile(path):
        fail(f"{path} is not a regular file. Nothing was changed.")
    return directories, path


def load(path):
    """The file's settings, or None when there is no file."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        fail(f"{path} cannot be read as JSON ({exc}); fix or remove it. Nothing was changed.")
    if not isinstance(data, dict):
        fail(f"{path} does not hold a JSON object; fix or remove it. Nothing was changed.")
    return data


def load_text(path):
    """The rule file's text, or None when there is no file."""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        fail(f"{path} cannot be read as text ({exc}); fix or remove it. Nothing was changed.")


def has_rule(text):
    return any(line.strip() == RULE for line in text.splitlines())


def write(directory, path, text, mode):
    handle, temporary = tempfile.mkstemp(prefix=".settings.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except OSError as exc:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        fail(f"could not write {path} ({exc}). Nothing was changed.")


def keep_copy(path):
    """Keep the earlier file beside itself as PATH.bak-<UTC time> (-1, -2 ... after a copy of the same
    second); returns the copy's name and the mode."""
    base = f"{path}.bak-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    mode = os.stat(path).st_mode & 0o777
    for n in range(100):
        backup = base if n == 0 else f"{base}-{n}"
        try:
            with open(path, "rb") as source, open(backup, "xb") as copy:
                copy.write(source.read())
            os.chmod(backup, mode)
            return os.path.basename(backup), mode
        except FileExistsError:
            continue
        except OSError as exc:
            fail(f"could not keep a copy of {path} ({exc}). Nothing was changed.")
    fail(f"could not keep a copy of {path}: too many copies of this second. Nothing was changed.")


def make_folders(directories):
    for directory in directories:
        try:
            if not os.path.isdir(directory):
                os.mkdir(directory)
                os.chmod(directory, 0o755)
        except OSError as exc:
            fail(f"could not create {directory} ({exc}). Nothing was changed.")


def dump(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    if argv and argv[0] == "show" and argv[1:] in ([], ["claude"], ["codex"]):
        print(RULE if argv[1:] == ["codex"] else json.dumps(required(), indent=2))
        return 0
    if len(argv) == 2:
        argv = [argv[0], "claude", argv[1]]
    if len(argv) != 3 or argv[0] not in ("apply", "check") or argv[1] not in ("claude", "codex"):
        fail("usage: workspace-settings.py apply|check [claude|codex] PROJECT_FOLDER   (or: show [claude|codex])")
    command, backend = argv[0], argv[1]
    directories, path = locate(argv[2], backend)
    if backend == "codex":
        text = load_text(path)
        missing = None if text is None else ([] if has_rule(text) else ["the line " + RULE])
    else:
        data = load(path)
        missing = None if data is None else lacking(data)
    if command == "check":
        if missing is None:
            print(f"absent: {path}")
            return 3
        if missing:
            print(f"incomplete: {path} lacks {', '.join(missing)}")
            return 4
        print(f"in place: {path}")
        return 0
    if missing is None:
        make_folders(directories)
        write(directories[-1], path, RULE + "\n" if backend == "codex" else dump(required()), 0o644)
        print(f"added: {path}")
        return 0
    if not missing:
        print(f"in place: {path}")
        return 0
    if backend == "codex":
        new = text + ("" if text.endswith("\n") or not text else "\n") + RULE + "\n"
    else:
        new = dump(complete(data, path))   # stops here, before anything is written, when it cannot be
    backup, mode = keep_copy(path)
    write(directories[-1], path, new, mode)
    print(f"completed: {path} (the earlier file is kept as {backup})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
