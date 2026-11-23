"""Exercise the actual Claude tool policy with a local model, a fake Buzz CLI and disposable files."""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

SKILL = Path(__file__).resolve().parent / "buzz-agent-team"
CHANNEL = "00000000-0000-4000-8000-000000000001"
EXTRA_MCP = """import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    if m.get("method") == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
             "serverInfo": {"name": "personal", "version": "1"}}
    elif m.get("method") == "tools/list":
        r = {"tools": [{"name": "personal_tool", "description": "A personal tool.", "inputSchema": {"type": "object"}}]}
    else:
        r = {"content": [{"type": "text", "text": "personal tool ran"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
"""
BUZZ_TOOLS = {
    "read_channel", "read_thread", "search_messages", "read_canvas", "read_issue",
    "list_issues", "post_message", "list_memory", "read_memory", "save_memory",
}
# The channel supervisor's alone (agent.conf role=supervisor); test-codex-partner.py checks each one's arguments.
CHANNEL_TOOLS = {
    "list_channels", "get_channel", "list_channel_members", "create_channel", "update_channel",
    "set_channel_topic", "set_channel_purpose", "add_channel_member", "remove_channel_member",
    "archive_channel", "unarchive_channel",
}
# The CLI's tool-discovery entries; DeferredToolPlaceholder stands for deferred tools that are
# still limited to the allowed set (it appears with some models, for example claude-opus-5-5).
DISCOVERY = {"ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool", "DeferredToolPlaceholder"}


def model_fixture(calls, requests, models):
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

            index = len(requests)
            requests.append(body)
            models.append(body.get("model"))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()

            def emit(event, **data):
                payload = json.dumps({"type": event, **data})
                self.wfile.write(f"event: {event}\ndata: {payload}\n\n".encode())

            emit("message_start", message={
                "id": f"msg_{index}", "type": "message", "role": "assistant",
                "model": "claude-sonnet-4-5", "content": [], "stop_reason": None,
                "usage": {"input_tokens": 10, "output_tokens": 0},
            })
            if index < len(calls):
                name, arguments = calls[index]
                emit("content_block_start", index=0, content_block={
                    "type": "tool_use", "id": f"tool_{index}", "name": name, "input": {},
                })
                emit("content_block_delta", index=0, delta={
                    "type": "input_json_delta", "partial_json": json.dumps(arguments),
                })
                reason = "tool_use"
            else:
                emit("content_block_start", index=0, content_block={"type": "text", "text": ""})
                emit("content_block_delta", index=0, delta={"type": "text_delta", "text": "Done."})
                reason = "end_turn"
            emit("content_block_stop", index=0)
            emit("message_delta", delta={"stop_reason": reason}, usage={"output_tokens": 2})
            emit("message_stop")

    return Model


def exercise(home):
    workspace = home / "workspace"
    workspace.mkdir()
    project = workspace / "PROJECT.md"
    project.write_text("shared project fixture\n")
    outside = home / "private-marker.txt"
    outside.write_text("outside project fixture\n")
    # A personal MCP server at user level and one in the project: neither may reach the partner.
    server = home / "personal-mcp.py"
    server.write_text(EXTRA_MCP)
    entry = {"command": sys.executable, "args": ["-I", str(server)]}
    (home / ".claude").mkdir()
    (home / ".claude" / ".claude.json").write_text(json.dumps({"mcpServers": {"personal": entry}}))
    (workspace / ".mcp.json").write_text(json.dumps({"mcpServers": {"projectpersonal": entry}}))
    # The user's own model setting; the agent's chosen model (ANTHROPIC_MODEL, as the launcher sets it) wins.
    (home / ".claude" / "settings.json").write_text(json.dumps({"model": "claude-haiku-4-5"}))
    identity = home / "identity"
    runtime = identity / "runtime"
    shutil.copytree(SKILL / "runtime", runtime)
    (identity / "identity.key").write_text("1".zfill(64))
    (identity / ".env.buzz-acp.local").write_text(
        "BUZZ_RELAY_URL=ws://127.0.0.1\n export BUZZ_AUTH_TAG = '[]'\n"
    )
    cli = home / "buzz"
    cli.write_text(
        "#!/bin/sh\n"
        f'[ "$*" = "--format agent messages send --channel {CHANNEL} --content -" ] || exit 1\n'
        '[ "$BUZZ_AUTH_TAG" = "[]" ] && [ "$(cat)" = "Proposed todo" ] || exit 1\n'
        "echo proposal-observed\n"
    )
    cli.chmod(0o700)
    adapter = shutil.which("claude-agent-acp")
    if not adapter:
        raise SystemExit("Install the Claude ACP adapter before running this test.")
    calls = [
        ("Write", {"file_path": str(project), "content": "changed"}),
        ("Read", {"file_path": str(project)}),
        ("mcp__buzz__post_message", {"channel": CHANNEL, "text": "Proposed todo"}),
        ("Read", {"file_path": str(outside)}),
    ]
    # This folder has no agent.conf, so no channel tool is registered.
    init, requests, models, results = session(home, runtime, workspace, adapter, cli, calls)
    expected = {"Read", "Glob", "Grep"} | {"mcp__buzz__" + name for name in BUZZ_TOOLS}
    assert init["permissionMode"] == "dontAsk"
    assert expected <= set(init["tools"]) <= expected | DISCOVERY, init["tools"]
    assert len(requests) == len(calls) + 1, len(requests)
    for request in requests:
        assert {tool["name"] for tool in request["tools"]} <= expected | DISCOVERY
    assert results["tool_0"].get("is_error") and project.read_text() == "shared project fixture\n"
    assert "shared project fixture" in str(results["tool_1"]) and not results["tool_1"].get("is_error")
    assert "proposal-observed" in str(results["tool_2"]) and not results["tool_2"].get("is_error")
    assert results["tool_3"].get("is_error") and "outside project fixture" not in str(results["tool_3"])
    assert not any("personal" in t for t in init["tools"]), init["tools"]
    assert set(models) == {"claude-opus-5-5"}, models
    check_supervisor(home, workspace, adapter)
    check_sign_in_passthrough(home, runtime, adapter)


def session(home, runtime, workspace, adapter, cli, calls):
    """One run of the restricted runtime against the loopback model, which makes CALLS in turn. Returns the
    CLI's init event, the model requests, the models they named and the tool results by tool_use id."""
    requests, models = [], []
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), model_fixture(calls, requests, models)) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(home),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"), "ANTHROPIC_API_KEY": "fixture-only",
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}",
            "NO_PROXY": "localhost,127.0.0.1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1", "PROJECT_BUZZ_ADAPTER": adapter, "PROJECT_BUZZ_CLI": str(cli),
            "ANTHROPIC_MODEL": "claude-opus-5-5",
        }
        try:
            run = subprocess.run(
                [runtime / "restricted-claude", "-p", "Run the fixture.",
                 "--output-format", "stream-json", "--verbose", "--permission-mode", "bypassPermissions",
                 "--tools", "default"], cwd=workspace, env=env, capture_output=True, text=True, timeout=75,
            )
            run.check_returncode()
        finally:
            server.shutdown()
            worker.join()
    init = next(e for line in run.stdout.splitlines() if line.startswith("{")
                and (e := json.loads(line)).get("subtype") == "init")
    results = {item["tool_use_id"]: item for message in requests[-1]["messages"]
               if isinstance(message["content"], list) for item in message["content"]
               if item.get("type") == "tool_result"}
    return init, requests, models, results


def check_supervisor(home, workspace, adapter):
    """In a channel supervisor's folder (agent.conf role=supervisor) its model also sees the channel tools,
    and a call reaches the CLI as one fixed argument list. The runtime finds its folder as in production:
    PROJECT_BUZZ_AGENT_DIR is unset, so it is the folder around runtime/."""
    folder = home / "supervisor"
    runtime = folder / "runtime"
    shutil.copytree(SKILL / "runtime", runtime)
    (folder / "agent.conf").write_text("format=4\nid=supervisor\nrole=supervisor\n")
    (folder / "identity.key").write_text("1".zfill(64))
    (folder / ".env.buzz-acp.local").write_text("BUZZ_RELAY_URL=ws://127.0.0.1\nBUZZ_AUTH_TAG=[]\n")
    name = '--temporary "Q4" it\'s'
    argv = ["--format", "agent", "channels", "create", "--name=" + name, "--type", "stream",
            "--visibility", "private", "--ttl", "3600"]
    cli = home / "buzz-channels"
    cli.write_text("#!" + sys.executable + " -I\nimport sys\n"
                   f"if sys.argv[1:] != {argv!r}:\n    sys.exit(1)\nprint('channel-created')\n")
    cli.chmod(0o700)
    calls = [("mcp__buzz__create_channel", {"name": name, "ttl_seconds": 3600})]
    init, requests, _, results = session(home, runtime, workspace, adapter, cli, calls)
    expected = {"Read", "Glob", "Grep"} | {"mcp__buzz__" + tool for tool in BUZZ_TOOLS | CHANNEL_TOOLS}
    assert expected <= set(init["tools"]) <= expected | DISCOVERY, init["tools"]
    for request in requests:
        assert {tool["name"] for tool in request["tools"]} <= expected | DISCOVERY
    assert "channel-created" in str(results["tool_0"]) and not results["tool_0"].get("is_error"), results


def check_sign_in_passthrough(home, runtime, adapter):
    """The partner's CLI reports the same sign-in as the adapter's own CLI (T-9 defect 1).

    A fixture credential file under a scratch CLAUDE_CONFIG_DIR stands in for a subscription sign-in.
    """
    config = home / "signin"
    config.mkdir()
    (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": "fixture-access", "refreshToken": "fixture-refresh", "expiresAt": 4102444800000,
        "scopes": ["user:inference", "user:profile"], "subscriptionType": "max"}}))
    (config / ".credentials.json").chmod(0o600)
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(home), "CLAUDE_CONFIG_DIR": str(config),
           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "PROJECT_BUZZ_ADAPTER": adapter}
    partner = subprocess.run([runtime / "restricted-claude", "auth", "status"], env=env, capture_output=True,
                             text=True, timeout=30)
    plain = subprocess.run([adapter, "--cli", "auth", "status"], env=env, capture_output=True, text=True, timeout=30)
    assert partner.returncode == 0 and plain.returncode == 0, (partner.stderr[-300:], plain.stderr[-300:])
    assert json.loads(partner.stdout)["authMethod"] == "claude.ai", partner.stdout
    assert json.loads(partner.stdout) == json.loads(plain.stdout)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="buzz-partner-") as tmp:
        exercise(Path(tmp))
    print("Verified the tool list, workspace read, denied write and external read, no personal MCP tool, "
          "the chosen model over the user's setting, the sign-in passthrough, and the Buzz proposal; "
          "a channel supervisor's model also sees the channel tools, and creating a channel reaches the CLI.")
