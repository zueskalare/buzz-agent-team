#!/usr/bin/env python3
"""Give the workspace agent a browser: name the Playwright tool server in its project folder.

    workspace-browser.py apply  claude|codex PROJECT_FOLDER   name the server in that backend's file
    workspace-browser.py check  claude|codex PROJECT_FOLDER   say whether it is named there; change nothing
    workspace-browser.py remove PROJECT_FOLDER                take it out of both files
    workspace-browser.py show                                 print the entry

The adapter's own CLI reads the tool servers a project folder names, so no program stands between the
agent and the browser:

    Claude   PROJECT_FOLDER/.mcp.json, key mcpServers.playwright
    Codex    PROJECT_FOLDER/.codex/config.toml, table [mcp_servers.playwright]

The entry is the same for both: command npx, arguments -y @playwright/mcp@0.0.86 --headless --isolated
--output-dir .browser-output. That is a headless Chrome that starts with a new, empty profile each
session (--isolated), so it is signed in to nothing. A file it saves without a name goes to
.browser-output/ in the project folder; it refuses file: addresses and files outside the project folder.

apply writes the entry only when no server named playwright is there. One that is there with other
settings is yours: it is left as it is, and reported as in place "with your own settings". An existing
file keeps everything else it holds; the earlier file is kept beside it as <name>.bak-<UTC time>. In the
Codex file the table is added as text at the end, and the result is read again before it replaces the
file: when it does not give exactly the entry, nothing is changed.

remove takes the entry out of .mcp.json whatever it holds (the earlier file is kept beside it), and out
of .codex/config.toml only as the exact block apply writes: a playwright server written another way is
named, and left for you to remove. A file that then holds nothing else is deleted, and .codex/ with it
when that is then empty.

A file that cannot be read, does not hold an object (or table) where the entry goes, or is a symbolic
link (the file or its folder) is left alone. The Codex file needs Python 3.11 or newer (tomllib).

Exit status: 0 in place (check), written or in place (apply), removed or nothing to remove (remove);
3 no server named playwright in that file (check); 4 a playwright server in the Codex file that remove
did not write and leaves (remove); 2 anything that stopped the program.
"""
import json
import os
import sys
import tempfile
import time

try:
    import tomllib
except ImportError:   # Python before 3.11
    tomllib = None

NAME = "playwright"
ENTRY = {"command": "npx", "args": ["-y", "@playwright/mcp@0.0.86", "--headless", "--isolated", "--output-dir", ".browser-output"]}
# The exact block apply adds to the Codex file, and the only one remove takes out of it.
BLOCK = (f"[mcp_servers.{NAME}]\n"
         f"command = {json.dumps(ENTRY['command'])}\n"
         f"args = [{', '.join(json.dumps(a) for a in ENTRY['args'])}]\n")


def fail(message):
    print(f"workspace-browser.py: {message}", file=sys.stderr)
    sys.exit(2)


def stamp_backup(path):
    """Keep a copy of PATH beside it as PATH.bak-<UTC time>; returns the copy's name."""
    base = f"{path}.bak-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    mode = os.stat(path).st_mode & 0o777
    for n in range(100):
        backup = base if n == 0 else f"{base}-{n}"
        try:
            with open(path, "rb") as source, open(backup, "xb") as copy:
                copy.write(source.read())
            os.chmod(backup, mode)
            return os.path.basename(backup)
        except FileExistsError:
            continue
        except OSError as exc:
            fail(f"could not keep a copy of {path} ({exc}). Nothing was changed.")
    fail(f"could not keep a copy of {path}: too many copies of this second. Nothing was changed.")


def replace(directory, path, text, mode):
    handle, temporary = tempfile.mkstemp(prefix=".browser.", dir=directory)
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


def project(folder):
    if not os.path.isdir(folder):
        fail(f"not a folder: {folder}")
    return os.path.realpath(folder)


def refuse_links(*items):
    for item in items:
        if os.path.islink(item):
            fail(f"{item} is a symbolic link; the browser entry is not written through one. Nothing was changed.")


# ---------------------------------------------------------------- Claude: .mcp.json
def claude_path(root):
    path = os.path.join(root, ".mcp.json")
    refuse_links(path)
    if os.path.exists(path) and not os.path.isfile(path):
        fail(f"{path} is not a regular file. Nothing was changed.")
    return path


def claude_load(path):
    """The file's data and its mcpServers object (None when the file or the key is absent)."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as exc:
        fail(f"{path} cannot be read as JSON ({exc}); fix or remove it. Nothing was changed.")
    if not isinstance(data, dict):
        fail(f"{path} does not hold a JSON object; fix or remove it. Nothing was changed.")
    servers = data.get("mcpServers")
    if servers is not None and not isinstance(servers, dict):
        fail(f'{path}: "mcpServers" is not an object; fix or remove it. Nothing was changed.')
    return data, servers


def claude_dump(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------- Codex: .codex/config.toml
def codex_paths(root):
    directory = os.path.join(root, ".codex")
    path = os.path.join(directory, "config.toml")
    refuse_links(directory, path)
    if os.path.exists(directory) and not os.path.isdir(directory):
        fail(f"{directory} is not a folder. Nothing was changed.")
    if os.path.exists(path) and not os.path.isfile(path):
        fail(f"{path} is not a regular file. Nothing was changed.")
    return directory, path


def codex_parse(text, path):
    if tomllib is None:
        fail(f"Python 3.11 or newer is needed for the Codex file, {path} (this is Python {sys.version.split()[0]}, without tomllib). Nothing was changed.")
    try:
        data = tomllib.loads(text)
    except ValueError as exc:
        fail(f"{path} cannot be read as TOML ({exc}); fix or remove it. Nothing was changed.")
    servers = data.get("mcp_servers")
    if servers is not None and not isinstance(servers, dict):
        fail(f'{path}: "mcp_servers" is not a table; fix or remove it. Nothing was changed.')
    return data, servers


def codex_load(path):
    """The file's text, data and mcp_servers table (None, None, None when the file is absent)."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return None, None, None
    except (OSError, ValueError) as exc:
        fail(f"{path} cannot be read ({exc}); fix or remove it. Nothing was changed.")
    data, servers = codex_parse(text, path)
    return text, data, servers


def without_entry(data):
    """DATA as it is with no playwright server: the mcp_servers table goes too when it is then empty."""
    rest = json.loads(json.dumps(data, default=str))
    rest["mcp_servers"].pop(NAME, None)
    return rest


def block_span(text):
    """Where the exact block stands in TEXT, as whole lines: (start, end), or None."""
    start = 0
    while True:
        i = text.find(BLOCK, start)
        if i < 0:
            break
        if i == 0 or text[i - 1] == "\n":
            return i, i + len(BLOCK)
        start = i + 1
    tail = BLOCK.rstrip("\n")   # the block at the very end, without its last newline
    if text.endswith(tail) and (len(text) == len(tail) or text[-len(tail) - 1] == "\n"):
        return len(text) - len(tail), len(text)
    return None


# ---------------------------------------------------------------- commands
def state_words(entry, path):
    if entry == ENTRY:
        return f"in place: {path}"
    return f"in place, with your own settings: {path}"


def check(backend, root):
    if backend == "claude":
        path = claude_path(root)
        _, servers = claude_load(path)
    else:
        _, path = codex_paths(root)
        _, _, servers = codex_load(path)
    if not servers or NAME not in servers:
        print(f"absent: {path}")
        return 3
    print(state_words(servers[NAME], path))
    return 0


def apply(backend, root):
    if backend == "claude":
        path = claude_path(root)
        data, servers = claude_load(path)
        if servers and NAME in servers:
            print(state_words(servers[NAME], path))
            return 0
        if data is None:
            replace(root, path, claude_dump({"mcpServers": {NAME: ENTRY}}), 0o644)
            print(f"added: {path}")
            return 0
        data.setdefault("mcpServers", {})[NAME] = ENTRY
        mode = os.stat(path).st_mode & 0o777
        backup = stamp_backup(path)
        replace(root, path, claude_dump(data), mode)
        print(f"added: {path} (the earlier file is kept as {backup})")
        return 0
    directory, path = codex_paths(root)
    text, data, servers = codex_load(path)
    if servers and NAME in servers:
        print(state_words(servers[NAME], path))
        return 0
    base = text or ""
    if base and not base.endswith("\n"):
        base += "\n"
    new = base + ("\n" if base.strip() else "") + BLOCK
    # The text is read again before it replaces the file: it must give exactly the entry, beside what was there.
    want = json.loads(json.dumps(data or {}, default=str))
    want.setdefault("mcp_servers", {})[NAME] = ENTRY
    if tomllib is None:
        codex_parse(new, path)   # stops with the reason
    try:
        got = tomllib.loads(new)
    except ValueError as exc:
        fail(f"{path}: the [mcp_servers.{NAME}] table cannot be added at its end ({exc}); add it yourself (workspace-browser.py show prints it). Nothing was changed.")
    if json.loads(json.dumps(got, default=str)) != want:
        fail(f"{path}: adding the [mcp_servers.{NAME}] table at its end would not give exactly the entry; add it yourself (workspace-browser.py show prints it). Nothing was changed.")
    if text is None:
        try:
            if not os.path.isdir(directory):
                os.mkdir(directory)
                os.chmod(directory, 0o755)
        except OSError as exc:
            fail(f"could not create {directory} ({exc}). Nothing was changed.")
        replace(directory, path, new, 0o644)
        print(f"added: {path}")
        return 0
    mode = os.stat(path).st_mode & 0o777
    backup = stamp_backup(path)
    replace(directory, path, new, mode)
    print(f"added: {path} (the earlier file is kept as {backup})")
    return 0


def remove(root):
    # Both files are read first: one that cannot be used stops the program before either is changed.
    jpath = claude_path(root)
    jdata, jservers = claude_load(jpath)
    directory, tpath = codex_paths(root)
    text, tdata, tservers = codex_load(tpath)
    status, said = 0, False
    if jservers and NAME in jservers:
        own = jservers[NAME] != ENTRY
        del jservers[NAME]
        if jdata in ({}, {"mcpServers": {}}):
            backup = stamp_backup(jpath) if own else None
            os.unlink(jpath)
            print(f"removed: {jpath} is deleted: it held nothing else" + (f" (the earlier file is kept as {backup})" if backup else ""))
        else:
            mode = os.stat(jpath).st_mode & 0o777
            backup = stamp_backup(jpath)
            replace(root, jpath, claude_dump(jdata), mode)
            print(f"removed: {jpath} (the earlier file is kept as {backup})")
        said = True
    if tservers and NAME in tservers:
        span = block_span(text) if tservers[NAME] == ENTRY else None
        rest = None
        if span is not None:
            head, tail = text[:span[0]], text[span[1]:]
            if head.endswith("\n\n") and not tail.strip():
                head = head[:-1]   # the blank line apply put before the block
            rest = head + tail
            want = without_entry(tdata)
            got = json.loads(json.dumps(tomllib.loads(rest), default=str)) if rest.strip() else {}
            if not want["mcp_servers"] and got.get("mcp_servers", {}) == {}:
                want.pop("mcp_servers")
                got.pop("mcp_servers", None)
            if got != want:
                rest = None
        if rest is None:
            print(f"left: {tpath} names a server {NAME} that workspace-browser.py did not write as it stands; remove its [mcp_servers.{NAME}] table yourself")
            status = 4
        elif not rest.strip():
            os.unlink(tpath)
            gone = ""
            try:
                os.rmdir(directory)
                gone = ", and so is .codex/, which held nothing else"
            except OSError:
                pass
            print(f"removed: {tpath} is deleted: it held nothing else{gone}")
        else:
            mode = os.stat(tpath).st_mode & 0o777
            backup = stamp_backup(tpath)
            replace(directory, tpath, rest, mode)
            print(f"removed: {tpath} (the earlier file is kept as {backup})")
        said = True
    if not said:
        print(f"absent: neither {jpath} nor {tpath} names a server {NAME}")
    return status


def show():
    print("# PROJECT_FOLDER/.mcp.json (Claude)")
    print(claude_dump({"mcpServers": {NAME: ENTRY}}), end="")
    print("# PROJECT_FOLDER/.codex/config.toml (Codex)")
    print(BLOCK, end="")
    return 0


def main(argv):
    if argv == ["show"]:
        return show()
    if len(argv) == 2 and argv[0] == "remove":
        return remove(project(argv[1]))
    if len(argv) == 3 and argv[0] in ("apply", "check") and argv[1] in ("claude", "codex"):
        root = project(argv[2])
        return apply(argv[1], root) if argv[0] == "apply" else check(argv[1], root)
    fail("usage: workspace-browser.py apply|check claude|codex PROJECT_FOLDER   (or: remove PROJECT_FOLDER, show)")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
