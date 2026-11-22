"""Exercise the workspace wall the way an agent session runs: the installed Claude ACP adapter,
started through wall/claude-agent-acp, driven over ACP as the Buzz harness drives it, with a local
model that asks for file and shell actions inside and outside the project folder.

Offline: a loopback model endpoint, a fixture API key, a disposable home folder, a stand-in buzz.
Nothing signs in, and nothing contacts a provider or a community.

    python3 test-wall.py
"""
import http.server
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time

SKILL = Path(__file__).resolve().parent / "buzz-agent-team"

BUZZ_STANDIN = """#!/bin/sh
# Reports whether it runs inside the wall: can it read a file outside the project folder?
if cat "$HOME/private.txt" >/dev/null 2>&1; then w=UNWALLED; else w=walled; fi
case "$1" in
  stdin) printf 'buzz[%s] stdin=' "$w"; cat ;;
  file) printf 'buzz[%s] file=' "$w"; cat "$2" 2>&1 ;;
  *) echo "buzz[$w] ran" ;;
esac
"""


def model_fixture(calls, requests):
    class Model(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if "/count_tokens" in self.path:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"input_tokens":10}')
                return
            # Only the conversation that carries the fixture's tools is scripted; any helper request
            # the CLI makes on the side (a title, a summary) gets a plain answer.
            scripted = any(t.get("name") == "Bash" for t in body.get("tools") or [])
            index = len(requests) if scripted else -1
            if scripted:
                requests.append(body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()

            def emit(event, **data):
                self.wfile.write(f"event: {event}\ndata: {json.dumps({'type': event, **data})}\n\n".encode())

            emit("message_start", message={
                "id": f"msg_{index}", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5",
                "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 0}})
            if 0 <= index < len(calls):
                name, arguments = calls[index][1], calls[index][2]
                emit("content_block_start", index=0, content_block={
                    "type": "tool_use", "id": f"tool_{index}", "name": name, "input": {}})
                emit("content_block_delta", index=0, delta={"type": "input_json_delta", "partial_json": json.dumps(arguments)})
                reason = "tool_use"
            else:
                emit("content_block_start", index=0, content_block={"type": "text", "text": ""})
                emit("content_block_delta", index=0, delta={"type": "text_delta", "text": "Done."})
                reason = "end_turn"
            emit("content_block_stop", index=0)
            emit("message_delta", delta={"stop_reason": reason}, usage={"output_tokens": 2})
            emit("message_stop")

    return Model


class Acp:
    """A minimal ACP client that behaves as the Buzz harness does: it answers every permission
    request with allow_once, and it can set a permission mode with session/set_config_option."""

    def __init__(self, command, cwd, env, deadline):
        self.proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
        self.buffer, self.next_id, self.deadline, self.approved = b"", 1, deadline, 0

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if "method" in message and "id" in message:
                    if message["method"] == "session/request_permission":
                        options = message["params"].get("options") or []
                        allow = next((o for o in options if o.get("kind") == "allow_once"), None)
                        pick = allow or next((o for o in options if o.get("kind") == "reject_once"), None)
                        self.approved += 1 if allow else 0
                        self.send({"jsonrpc": "2.0", "id": message["id"],
                                   "result": {"outcome": {"outcome": "selected", "optionId": pick["optionId"]}}})
                    else:
                        self.send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "not supported"}})
                    continue
                if message.get("id") == request_id:
                    return message
            left = self.deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(method)
            ready, _, _ = select.select([self.proc.stdout], [], [], left)
            if not ready:
                raise TimeoutError(method)
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError(method + ": " + (self.proc.stderr.read() or b"").decode(errors="replace")[-600:])
            self.buffer += chunk

    def close(self):
        try:
            os.killpg(self.proc.pid, 15)
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            try:
                os.killpg(self.proc.pid, 9)
            except OSError:
                pass


def exercise(home, walled=True, set_bypass=False):
    """One agent session. set_bypass: the client asks for bypassPermissions, as the harness does for
    an agent whose settings say so; a walled agent is started with the default mode instead."""
    home = home.resolve()
    project = home / "WorkSpace" / "proj"
    project.mkdir(parents=True)
    (project / "inside.txt").write_text("INSIDE-MARKER\n")
    (project / "CLAUDE.md").write_text("Project instructions fixture: PROJECT-INSTRUCTIONS-MARKER.\n")
    subprocess.run(["git", "init", "-q", str(project)], check=True, env={"PATH": os.environ["PATH"], "HOME": str(home)})
    (home / "private.txt").write_text("OUTSIDE-MARKER\n")
    team = home / ".buzz-agents" / "team"
    (team / "supervisor").mkdir(parents=True)
    (team / "supervisor" / "identity.key").write_text("KEY-MARKER\n")
    shutil.copytree(SKILL / "wall", team / "wall")
    for name in ("claude-agent-acp", "walled-claude", "bin/buzz"):
        (team / "wall" / name).chmod(0o700)
    os.symlink(home / "private.txt", project / "link-file")
    (home / "bin").mkdir()
    (home / "bin" / "buzz").write_text(BUZZ_STANDIN)
    (home / "bin" / "buzz").chmod(0o700)
    (home / "tmp").mkdir()
    # The user's own settings try to open everything; the wall's settings must win over them.
    (home / ".claude").mkdir()
    (home / ".claude" / "settings.json").write_text(json.dumps({
        "permissions": {"additionalDirectories": [str(home)], "allow": ["Read(//**)", "Bash"]},
        "sandbox": {"enabled": False}}))
    adapter = shutil.which("claude-agent-acp")
    if not adapter:
        raise SystemExit("Install the Claude ACP adapter before running this test.")
    key_glob = f'P=$HOME/.buzz-agents; cat "$P"/*/*/identity.key'
    calls = [
        ("read inside", "Read", {"file_path": str(project / "inside.txt")}),
        ("write inside", "Write", {"file_path": str(project / "written-inside.txt"), "content": "ok"}),
        ("read outside", "Read", {"file_path": str(home / "private.txt")}),
        ("read key", "Read", {"file_path": str(team / "supervisor" / "identity.key")}),
        ("write outside", "Write", {"file_path": str(home / "written-outside.txt"), "content": "leak"}),
        ("shell inside", "Bash", {"command": "cat inside.txt && echo more > bash-inside.txt && cat bash-inside.txt"}),
        ("shell cat outside", "Bash", {"command": f"cat {home}/private.txt"}),
        ("shell cat key, path built in the shell", "Bash", {"command": key_glob}),
        ("shell write outside", "Bash", {"command": f"echo leak > {home}/bash-outside.txt; echo tried"}),
        ("script opens outside file", "Bash", {"command": f"python3 -c \"print(open('{home}/private.txt').read())\""}),
        ("shell asks to skip the sandbox", "Bash", {"command": f"cat {home}/private.txt", "dangerouslyDisableSandbox": True}),
        ("read symlink to outside", "Read", {"file_path": str(project / "link-file")}),
        ("plain buzz", "Bash", {"command": "buzz probe"}),
        ("plain buzz, outside path", "Bash", {"command": "buzz file $HOME/private.txt"}),
        ("pipe into buzz", "Bash", {"command": f"cat {home}/private.txt | buzz stdin"}),
        ("plain buzz, inside path", "Bash", {"command": "buzz file inside.txt"}),
        ("plain buzz with a here-document", "Bash", {"command": "buzz stdin <<'EOF'\nfirst line\nsecond line\nEOF"}),
        ("two buzz commands joined", "Bash", {"command": "buzz probe && buzz probe"}),
        ("git commit", "Bash", {"command": "git add inside.txt && git -c user.name=t -c user.email=t@example.org commit -q -m t && git log --oneline | wc -l"}),
        ("read the wall's own file", "Read", {"file_path": str(team / "wall" / "walled-claude")}),
        ("shell reads the wall's own file", "Bash", {"command": f"head -1 {team}/wall/walled-claude"}),
        ("write project settings that switch the sandbox off", "Write", {"file_path": str(project / ".claude" / "settings.json"),
                                                                         "content": json.dumps({"sandbox": {"enabled": False}})}),
        ("shell cat outside, after that", "Bash", {"command": f"cat {home}/private.txt"}),
        ("shell writes project settings that name more folders", "Bash", {
            "command": "mkdir -p .claude; echo '{\"permissions\":{\"additionalDirectories\":[\"/\"]}}' > .claude/settings.local.json; echo exit=$?"}),
    ]
    requests = []
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), model_fixture(calls, requests)) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        env = {
            "PATH": str(home / "bin") + ":" + os.environ["PATH"], "HOME": str(home), "TMPDIR": str(home / "tmp"),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"), "ANTHROPIC_API_KEY": "fixture-only",
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "NO_PROXY": "localhost,127.0.0.1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1",
            "CLAUDE_AGENT_ACP_PROTOCOL": "v1", "BUZZ_WALL_PROJECT": str(project),
        }
        command = [str(team / "wall" / "claude-agent-acp")] if walled else [adapter]
        acp = Acp(command, str(project), env, time.monotonic() + 420)
        try:
            init = acp.request("initialize", {"protocolVersion": 1, "clientCapabilities": {},
                                              "clientInfo": {"name": "wall-test", "version": "1"}})
            assert "result" in init, init
            new = acp.request("session/new", {"cwd": str(project), "mcpServers": []})
            assert "result" in new, new
            session = new["result"]["sessionId"]
            mode = {"result": None}
            if set_bypass:
                mode = acp.request("session/set_config_option", {"sessionId": session, "configId": "mode", "value": "bypassPermissions"})
            done = acp.request("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "Run the fixture."}]})
            assert "result" in done, done
        finally:
            acp.close()
            server.shutdown()
            worker.join()
    results = {}
    for request in requests:
        for message in request["messages"]:
            if isinstance(message["content"], list):
                for item in message["content"]:
                    if item.get("type") == "tool_result":
                        results[item["tool_use_id"]] = item
    out = {}
    for index, (label, _, _) in enumerate(calls):
        item = results.get(f"tool_{index}")
        assert item is not None, f"no result for: {label} ({len(requests)} model requests)"
        out[label] = (bool(item.get("is_error")), json.dumps(item.get("content")))
    first = json.dumps(requests[0].get("system")) + json.dumps(requests[0].get("messages")) if requests else ""
    state = {
        "mode_applied": "result" in mode, "approved": acp.approved, "project_instructions": "PROJECT-INSTRUCTIONS-MARKER" in first,
        "settings_planted": (project / ".claude" / "settings.local.json").exists(),
        "written_inside": (project / "written-inside.txt").exists(), "written_outside": (home / "written-outside.txt").exists(),
        "bash_inside": (project / "bash-inside.txt").exists(), "bash_outside": (home / "bash-outside.txt").exists(),
    }
    return out, state


def check_walled(out, state, label):
    # Nothing outside the project folder was read: no marker of an outside file is in any result.
    for name, (_, text) in out.items():
        assert "OUTSIDE-MARKER" not in text and "KEY-MARKER" not in text, f"{label}: leak in: {name}: {text[:200]}"
    # Inside the project folder everything works.
    assert not out["read inside"][0] and "INSIDE-MARKER" in out["read inside"][1], out["read inside"]
    assert not out["write inside"][0] and state["written_inside"], out["write inside"]
    assert not out["shell inside"][0] and "more" in out["shell inside"][1] and state["bash_inside"], out["shell inside"]
    assert "1" in out["git commit"][1] and not out["git commit"][0], out["git commit"]
    # Outside it, the file tools and the shell are refused, and nothing is written.
    for name in ("read outside", "read key", "write outside", "read symlink to outside", "read the wall's own file"):
        assert out[name][0], f"{label}: not refused: {name}: {out[name][1][:200]}"
    assert not state["written_outside"] and not state["bash_outside"], state
    for name in ("shell cat outside", "shell cat key, path built in the shell", "script opens outside file",
                 "shell asks to skip the sandbox", "shell reads the wall's own file", "shell cat outside, after that"):
        assert "not permitted" in out[name][1] or "blocked" in out[name][1] or out[name][0], f"{label}: not refused: {name}: {out[name][1][:200]}"
    # A plain buzz command runs outside the sandbox, so it has the network; a path outside the project
    # folder is refused to it, and a pipe into it runs walled as a whole.
    assert "buzz[UNWALLED] ran" in out["plain buzz"][1], out["plain buzz"]
    assert "buzz[UNWALLED] file=INSIDE-MARKER" in out["plain buzz, inside path"][1], out["plain buzz, inside path"]
    assert out["plain buzz, outside path"][0], out["plain buzz, outside path"]
    assert "this workspace is walled" in out["pipe into buzz"][1], out["pipe into buzz"]
    # The agent cannot plant settings that would widen the wall for its next session.
    assert not state["settings_planted"], state
    assert out["write project settings that switch the sandbox off"][0], out["write project settings that switch the sandbox off"]
    # No approval was needed, so the harness's "allow" to every request opened nothing.
    assert state["approved"] == 0, state
    # The project's own instructions still reach the agent.
    assert state["project_instructions"], "the project's CLAUDE.md did not reach the agent"


def main():
    verbose = "--verbose" in sys.argv
    runs = [("walled, started with the default mode as team.sh starts it", False),
            ("walled, with a client that asks for bypassPermissions and allows every request", True)]
    for label, set_bypass in runs:
        with tempfile.TemporaryDirectory(prefix="buzz-wall-") as tmp:
            out, state = exercise(Path(tmp), walled=True, set_bypass=set_bypass)
        if verbose:
            print(f"--- {label}")
            for name, (error, text) in out.items():
                print(f"  {name:52s} error={error!s:5} {text[:140]}")
            print("  ", state)
        check_walled(out, state, label)
    if "--also-unwalled" in sys.argv:
        # The same session without the wall reads the outside files: the checks above can fail.
        with tempfile.TemporaryDirectory(prefix="buzz-wall-open-") as tmp:
            open_out, open_state = exercise(Path(tmp), walled=False, set_bypass=True)
        leaks = [name for name, (_, text) in open_out.items() if "OUTSIDE-MARKER" in text or "KEY-MARKER" in text]
        assert len(leaks) >= 5 and open_state["written_outside"], (leaks, open_state)
        print(f"Without the wall, the same session read outside files in {len(leaks)} of {len(open_out)} actions and wrote outside.")
    print("Verified over ACP, as the harness drives the adapter, in two sessions: reads and writes inside the project "
          "folder work; the file tools and the shell are refused outside it, the key file and the wall's own files "
          "included; hostile user settings and a client that allows every request open nothing; a plain buzz command "
          "runs outside the sandbox and is refused a path outside the project folder.")


if __name__ == "__main__":
    main()
