#!/usr/bin/env python3
"""List the models an ACP adapter offers, without a model turn.

Usage: acp-models.py [--timeout SECONDS] [--cwd DIR] [--lines] -- ADAPTER [ARGS...]

Opens one ACP session (initialize, then session/new) with the adapter, reads the models it
reports, and stops the adapter. No prompt is sent, so no model turn happens; the adapter signs
in with the user's own sign-in. Prints one JSON object on stdout:
  {"ok": true, "models": [...], "current": "..."}   or   {"ok": false, "reason": "..."}
With --lines it prints one "ID<TAB>name" line per model instead, and a failure's reason on stderr.
Exit status 0 only for a non-empty list. One attempt; no retry. At most --timeout seconds (30).
The adapter and the temporary folder it ran in are removed on every way out, a signal included.
"""
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

LINES = False    # --lines
ADAPTER = None   # the running adapter: stopped on every way out
WORK = None      # the temporary folder made for it: removed on every way out


def main():
    global LINES, ADAPTER, WORK
    args = sys.argv[1:]
    timeout, cwd = 30.0, None
    while args and args[0] != "--":
        if args[0] == "--timeout" and len(args) > 1:
            timeout = min(float(args[1]), 30.0)
            args = args[2:]
        elif args[0] == "--cwd" and len(args) > 1:
            cwd = args[1]
            args = args[2:]
        elif args[0] == "--lines":
            LINES = True
            args = args[1:]
        else:
            return finish(False, f"unknown option {args[0]}")
    command = args[1:]
    if not command:
        return finish(False, "no adapter command given")
    work = cwd
    if work is None:
        work = WORK = tempfile.mkdtemp(prefix="acp-models-")
    deadline = time.monotonic() + timeout
    try:
        proc = ADAPTER = subprocess.Popen(command, cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, start_new_session=True)
    except OSError as exc:
        return finish(False, f"the adapter could not start: {exc.strerror}")
    buffer = b""

    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def answer(request_id):
        nonlocal buffer
        while True:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if "method" in message and "id" in message:
                    # A request from the adapter (for example a permission): this client grants nothing.
                    send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "not supported"}})
                    continue
                if message.get("id") == request_id:
                    return message
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError
            ready, _, _ = select.select([proc.stdout], [], [], left)
            if not ready:
                raise TimeoutError
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError
            buffer += chunk

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": "agent-team-models", "version": "1"}}})
        init = answer(1)
        if "error" in init:
            return finish(False, "the adapter refused to start a session: " + describe(init["error"]))
        send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": work, "mcpServers": []}})
        new = answer(2)
    except TimeoutError:
        return finish(False, f"the adapter did not answer within {timeout:g} s", proc)
    except (EOFError, BrokenPipeError, OSError):
        return finish(False, "the adapter stopped before reporting models: " + stderr_tail(proc), proc)
    if "error" in new:
        return finish(False, "the adapter could not open a session: " + describe(new["error"]), proc)
    result = new.get("result") or {}
    # The values the harness can apply, in its search order: model configOptions, then
    # availableModels (buzz-acp acp.rs resolve_model_switch_method). Both are kept.
    models, current, names = [], None, {}
    state = result.get("models") or {}
    for option in result.get("configOptions") or []:
        if isinstance(option, dict) and option.get("category") == "model":
            current = current or option.get("currentValue")
            for value in option.get("options") or []:
                if isinstance(value, dict) and value.get("value"):
                    models.append(value["value"])
                    names.setdefault(value["value"], " - ".join(str(value[k]) for k in ("name", "description") if value.get(k))[:120])
    for entry in state.get("availableModels") or []:
        if isinstance(entry, dict) and entry.get("modelId"):
            models.append(entry["modelId"])
            names.setdefault(entry["modelId"], " - ".join(str(entry[k]) for k in ("name", "description") if entry.get(k))[:120])
    current = state.get("currentModelId") or current
    if not state and not result.get("configOptions"):
        return finish(False, "the adapter does not report models in session/new", proc)
    if not models:
        return finish(False, "the adapter reported an empty model list", proc)
    return finish(True, None, proc, models, current, names)


def describe(error):
    text = str(error.get("message", "")) if isinstance(error, dict) else str(error)
    data = error.get("data") if isinstance(error, dict) else None
    if data:
        text += " " + json.dumps(data)[:300]
    low = text.lower()
    if "auth" in low or "login" in low or "sign in" in low or "signed in" in low:
        return "not signed in (" + text[:300] + ")"
    if "network" in low or "connect" in low or "dns" in low or "enotfound" in low:
        return "no network (" + text[:300] + ")"
    return text[:400]


def stderr_tail(proc):
    try:
        proc.wait(timeout=2)
        data = proc.stderr.read() or b""
    except (subprocess.TimeoutExpired, OSError):
        data = b""
    return data.decode(errors="replace").strip().splitlines()[-1:][0][:300] if data.strip() else "no message"


def stop_adapter():
    """Stop the adapter's whole process group and remove the temporary folder. Safe to repeat."""
    global ADAPTER, WORK
    proc, ADAPTER = ADAPTER, None
    if proc is not None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
    work, WORK = WORK, None
    if work is not None:
        shutil.rmtree(work, ignore_errors=True)


def plain(text):
    """One line of text for a terminal: no tab, newline or other control character."""
    return "".join(c if c.isprintable() else " " for c in str(text)).strip()


def finish(ok, reason, proc=None, models=None, current=None, names=None):
    stop_adapter()
    seen = []
    for model in models or []:
        if model not in seen:
            seen.append(model)
    if LINES:
        # An ID is used as typed in a command line, so one with a space or a control character is left out.
        rows = [(m, plain((names or {}).get(m, ""))) for m in seen if isinstance(m, str) and m == plain(m) and " " not in m]
        if ok and not rows:
            ok, reason = False, "the adapter reported no usable model ID"
        if ok:
            for model, name in rows:
                print(model + "\t" + name)
        else:
            print(plain(reason), file=sys.stderr)
        return 0 if ok else 1
    out = {"ok": ok}
    if ok:
        out.update(models=seen, current=current, names={m: (names or {}).get(m, '') for m in seen})
    else:
        out["reason"] = reason
    print(json.dumps(out))
    return 0 if ok else 1


def interrupted(number, frame):
    sys.exit(128 + number)


if __name__ == "__main__":
    # A signal ends the run through the same way out, so the adapter never outlives this script.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    code = 1
    try:
        code = main()
    except KeyboardInterrupt:
        code = 130
    finally:
        stop_adapter()
    sys.exit(code)
