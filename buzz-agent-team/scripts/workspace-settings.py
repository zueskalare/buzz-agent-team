#!/usr/bin/env python3
"""Put the sandbox settings of an agent on the stock Claude adapter into its project folder.

    workspace-settings.py apply  PROJECT_FOLDER    write or complete PROJECT_FOLDER/.claude/settings.json
    workspace-settings.py check  PROJECT_FOLDER    say whether they are in place; change nothing
    workspace-settings.py show                     print the settings this program keeps in place

The settings are plain Claude Code settings, read by Claude Code itself from the project folder a
session starts in. No program stands between the agent and its adapter:

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
included, runs under the same settings.

An existing settings.json keeps everything else it holds; the earlier file is kept beside it as
settings.json.bak-<UTC time>. A file that is not a JSON object, or a symbolic link, is left alone.

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


def locate(folder):
    if not os.path.isdir(folder):
        fail(f"not a folder: {folder}")
    folder = os.path.realpath(folder)
    directory = os.path.join(folder, ".claude")
    path = os.path.join(directory, "settings.json")
    for item in (directory, path):
        if os.path.islink(item):
            fail(f"{item} is a symbolic link; the settings are not written through one. Nothing was changed.")
    if os.path.exists(directory) and not os.path.isdir(directory):
        fail(f"{directory} is not a folder. Nothing was changed.")
    if os.path.exists(path) and not os.path.isfile(path):
        fail(f"{path} is not a regular file. Nothing was changed.")
    return directory, path


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


def write(directory, path, data, mode):
    handle, temporary = tempfile.mkstemp(prefix=".settings.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2, ensure_ascii=False)
            out.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except OSError as exc:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        fail(f"could not write {path} ({exc}). Nothing was changed.")


def main(argv):
    if argv == ["show"]:
        print(json.dumps(required(), indent=2))
        return 0
    if len(argv) != 2 or argv[0] not in ("apply", "check"):
        fail("usage: workspace-settings.py apply|check PROJECT_FOLDER   (or: show)")
    directory, path = locate(argv[1])
    data = load(path)
    if argv[0] == "check":
        if data is None:
            print(f"absent: {path}")
            return 3
        names = lacking(data)
        if names:
            print(f"incomplete: {path} lacks {', '.join(names)}")
            return 4
        print(f"in place: {path}")
        return 0
    if data is None:
        try:
            if not os.path.isdir(directory):
                os.mkdir(directory)
                os.chmod(directory, 0o755)
        except OSError as exc:
            fail(f"could not create {directory} ({exc}). Nothing was changed.")
        write(directory, path, required(), 0o644)
        print(f"added: {path}")
        return 0
    if not lacking(data):
        print(f"in place: {path}")
        return 0
    completed = complete(data, path)   # stops here, before anything is written, when it cannot be
    backup = f"{path}.bak-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    mode = os.stat(path).st_mode & 0o777
    try:
        with open(path, "rb") as source, open(backup, "xb") as copy:
            copy.write(source.read())
        os.chmod(backup, mode)
    except OSError as exc:
        fail(f"could not keep a copy of {path} ({exc}). Nothing was changed.")
    write(directory, path, completed, mode)
    print(f"completed: {path} (the earlier file is kept as {os.path.basename(backup)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
