"""Check the production Codex partner's model-visible tools using a local Responses fixture."""
import asyncio
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

RUNTIME = Path(__file__).resolve().parent / "buzz-agent-team/runtime"
DEPS = Path.home() / ".local/share/buzz-agent-team"
MODEL = "gpt-6.2-astra"   # not the catalog's first model: the request must carry the chosen one
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
BASE_TOOLS = {"list_project", "read_project", "read_channel", "read_thread", "search_messages",
              "read_canvas", "read_issue", "list_issues", "post_message",
              "list_memory", "read_memory", "save_memory"}
# The channel supervisor's alone (agent.conf role=supervisor).
CHANNEL_TOOLS = {"list_channels", "get_channel", "list_channel_members", "create_channel", "update_channel",
                 "set_channel_topic", "set_channel_purpose", "add_channel_member", "remove_channel_member",
                 "archive_channel", "unarchive_channel"}
CHANNEL = "00000000-0000-4000-8000-000000000001"
PUBKEY = "ab" * 32
YEAR = 365 * 24 * 3600
# Free text that starts with "--" and holds spaces and both quotes: each must reach the CLI as one argument.
NAME = '--type forum "Q4" it\'s --unlisted'
TEXT = '--visibility open --ttl 60 "said" \'so\' --no-ttl'
# (tool, arguments, the CLI's arguments after "--format agent", or None: refused, the CLI never runs)
CHANNEL_CALLS = [
    ("list_channels", {}, ["channels", "list"]),
    ("get_channel", {"channel": CHANNEL}, ["channels", "get", "--channel", CHANNEL]),
    ("list_channel_members", {"channel": CHANNEL}, ["channels", "members", "--channel", CHANNEL]),
    ("create_channel", {"name": NAME},
     ["channels", "create", "--name=" + NAME, "--type", "stream", "--visibility", "private"]),
    ("create_channel", {"name": "n" * 80, "type": "forum", "visibility": "open", "description": TEXT,
                        "ttl_seconds": 60, "unlisted": True},
     ["channels", "create", "--name=" + "n" * 80, "--type", "forum", "--visibility", "open",
      "--description=" + TEXT, "--ttl", "60", "--unlisted"]),
    ("create_channel", {"name": "temp", "ttl_seconds": YEAR, "unlisted": False},
     ["channels", "create", "--name=temp", "--type", "stream", "--visibility", "private", "--ttl", str(YEAR)]),
    ("update_channel", {"channel": CHANNEL, "name": NAME}, ["channels", "update", "--channel", CHANNEL, "--name=" + NAME]),
    ("update_channel", {"channel": CHANNEL, "description": TEXT, "visibility": "open", "ttl_seconds": 3600},
     ["channels", "update", "--channel", CHANNEL, "--description=" + TEXT, "--visibility", "open", "--ttl", "3600"]),
    ("update_channel", {"channel": CHANNEL, "permanent": True}, ["channels", "update", "--channel", CHANNEL, "--no-ttl"]),
    ("set_channel_topic", {"channel": CHANNEL, "topic": TEXT}, ["channels", "topic", "--channel", CHANNEL, "--topic=" + TEXT]),
    ("set_channel_purpose", {"channel": CHANNEL, "purpose": TEXT},
     ["channels", "purpose", "--channel", CHANNEL, "--purpose=" + TEXT]),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY},
     ["channels", "add-member", "--channel", CHANNEL, "--pubkey", PUBKEY, "--role", "member"]),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY, "role": "bot"},
     ["channels", "add-member", "--channel", CHANNEL, "--pubkey", PUBKEY, "--role", "bot"]),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY, "role": "guest"},
     ["channels", "add-member", "--channel", CHANNEL, "--pubkey", PUBKEY, "--role", "guest"]),
    ("remove_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY},
     ["channels", "remove-member", "--channel", CHANNEL, "--pubkey", PUBKEY]),
    ("archive_channel", {"channel": CHANNEL}, ["channels", "archive", "--channel", CHANNEL]),
    ("unarchive_channel", {"channel": CHANNEL}, ["channels", "unarchive", "--channel", CHANNEL]),
    ("create_channel", {"name": ""}, None),
    ("create_channel", {"name": "n" * 81}, None),
    ("create_channel", {"name": "two\nlines"}, None),
    ("create_channel", {"name": "bell\x07"}, None),
    ("create_channel", {"name": "c1 control\x85"}, None),
    ("create_channel", {"name": "ok", "description": "d" * 1001}, None),
    ("create_channel", {"name": "ok", "ttl_seconds": 59}, None),
    ("create_channel", {"name": "ok", "ttl_seconds": YEAR + 1}, None),
    ("create_channel", {"name": "ok", "ttl_seconds": 90.5}, None),
    ("create_channel", {"name": "ok", "ttl_seconds": "3600"}, None),
    ("create_channel", {"name": "ok", "type": "dm"}, None),
    ("create_channel", {"name": "ok", "visibility": "public"}, None),
    ("update_channel", {"channel": CHANNEL}, None),
    ("update_channel", {"channel": CHANNEL, "permanent": False}, None),
    ("update_channel", {"channel": CHANNEL, "ttl_seconds": 3600, "permanent": True}, None),
    ("update_channel", {"channel": CHANNEL, "ttl_seconds": 3600, "permanent": False}, None),
    ("update_channel", {"channel": CHANNEL, "ttl_seconds": 59}, None),
    ("update_channel", {"channel": CHANNEL, "name": "n" * 81}, None),
    ("update_channel", {"channel": CHANNEL, "description": "d" * 1001}, None),
    ("get_channel", {"channel": "--help"}, None),
    ("set_channel_topic", {"channel": CHANNEL, "topic": "t" * 1001}, None),
    ("set_channel_purpose", {"channel": CHANNEL, "purpose": "cut\x00here"}, None),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY, "role": "owner"}, None),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY, "role": "admin"}, None),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": "--role=owner"}, None),
    ("add_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY[:-1]}, None),
    ("remove_channel_member", {"channel": CHANNEL, "pubkey": PUBKEY.upper()}, None),
    ("archive_channel", {"channel": "not-a-uuid"}, None),
    ("delete_channel", {"channel": CHANNEL}, None),
    ("leave_channel", {"channel": CHANNEL}, None),
]
# Agent folders and the role= lines of their agent.conf (None: no agent.conf). Only the first gets the channel tools.
FOLDERS = {"supervisor": "role=supervisor\n", "reviewer": "role=reviewer\n", "no agent.conf": None,
           "first role= line wins": "role=reviewer\nrole=supervisor\n", "unreadable agent.conf": "role=supervisor\n"}


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        tools = list(request.get("tools", []))
        for item in request.get("input", []):
            if item.get("type") == "additional_tools":
                tools.extend(item["tools"])
        self.server.tool_lists.append(tools)
        self.server.models.append(request.get("model"))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for event in ("created", "completed"):
            data = {"type": "response." + event, "response": {"id": "resp_test", "output": [],
                                                              "status": "completed"}}
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())


def agent_folder(folder, roles):
    """An agent folder as agent-team.sh writes it, with the given role= lines in agent.conf."""
    folder.mkdir()
    (folder / "identity.key").write_text("1".zfill(64))
    (folder / ".env.buzz-acp.local").write_text("BUZZ_RELAY_URL=ws://127.0.0.1\nBUZZ_AUTH_TAG=[]\n")
    if roles is not None:
        (folder / "agent.conf").write_text("# agent-team.sh agent record: public facts only.\nformat=4\nid=x\n"
                                           + roles + "name=Shop Supervisor\n")
    return folder


async def codex_session(server, env, project):
    """One turn through the production adapter; the loopback model records the tools each request offers."""
    server.tool_lists.clear()
    server.models.clear()
    process = await asyncio.create_subprocess_exec(
        RUNTIME / "codex-acp", "app-server", cwd=project, env=env, stdin=-1, stdout=-1,
        stderr=asyncio.subprocess.DEVNULL, limit=16 * 1024 * 1024)
    next_id = 0

    async def read():
        line = await process.stdout.readline()
        if not line:
            raise RuntimeError("Codex app server exited")
        return json.loads(line)

    async def request(method, params):
        nonlocal next_id
        next_id += 1
        process.stdin.write((json.dumps(dict(id=next_id, method=method, params=params)) + "\n").encode())
        await process.stdin.drain()
        while True:
            msg = await read()
            if msg.get("id") == next_id:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    try:
        async with asyncio.timeout(60):
            await request("initialize", {"clientInfo": {"name": "fixture", "version": "1"},
                                         "capabilities": {"experimentalApi": True}})
            process.stdin.write(b'{"method":"initialized"}\n')
            thread = await request("thread/start", {"cwd": str(project), "model": MODEL,
                                                    "ephemeral": True})
            tid = thread["thread"]["id"]
            await request("turn/start", {"threadId": tid, "input": [{"type": "text", "text": "Test."}],
                                         "model": MODEL, "sandboxPolicy": {"type": "dangerFullAccess"}})
            while True:
                msg = await read()
                if msg.get("method") == "turn/completed":
                    assert msg["params"]["turn"]["status"] == "completed", msg["params"]["turn"]
                    break
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 4)
        except TimeoutError:
            process.terminate()
            await process.wait()


def assert_model_tools(server, buzz_tools):
    """Every model request offers exactly these Buzz tools and nothing personal or local."""
    assert server.tool_lists
    for tools in server.tool_lists:
        if not tools:
            continue
        names = {tool.get("name", tool["type"]) for tool in tools}
        assert names <= {"functions", "mcp__buzz_discussion", "list_mcp_resources", "read_mcp_resource",
                         "list_mcp_resource_templates", "request_user_input"}, names
        for entry in tools:
            if entry.get("name") == "mcp__buzz_discussion":
                assert {tool["name"] for tool in entry["tools"]} == buzz_tools, entry["tools"]
            if entry.get("name") == "functions":
                assert {t["name"] for t in entry["tools"]} <= {
                    "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource",
                    "request_user_input"}, entry
    assert any(t.get("name") == "mcp__buzz_discussion" for tools in server.tool_lists for t in tools)
    assert set(server.models) == {MODEL}, server.models


def mcp(env, calls):
    """Run buzz-tools once over stdio: tools/list, then each (name, arguments) call. Replies come back by id."""
    protocol = [
        {"id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
         "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}},
        {"method": "notifications/initialized"},
        {"id": 1, "method": "tools/list"},
        *({"id": 100 + i, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
          for i, (name, arguments) in enumerate(calls))]
    run = subprocess.run([RUNTIME / "buzz-tools"], env=env, text=True, capture_output=True,
                         input="".join(json.dumps(dict(jsonrpc="2.0", **m)) + "\n" for m in protocol),
                         timeout=60, check=True)
    replies = {r["id"]: r for r in map(json.loads, run.stdout.splitlines())}
    return {t["name"] for t in replies[1]["result"]["tools"]}, [replies[100 + i] for i in range(len(calls))]


def refused(reply):
    return "error" in reply or bool(reply["result"].get("isError"))


def check_channel_tools(tmp, env):
    """Each agent folder's channel tools, run directly against a stand-in CLI that records its arguments."""
    record = tmp / "channel-cli.jsonl"
    cli = tmp / "buzz-recorder"
    cli.write_text("#!" + sys.executable + " -I\nimport json, sys\n"
                   f"with open({str(record)!r}, 'a') as f:\n    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                   "print(json.dumps(sys.argv[1:]))\n")
    cli.chmod(0o700)
    failures = []
    for label, roles in FOLDERS.items():
        folder = agent_folder(tmp / ("agent-" + label.replace(" ", "-").replace("=", "")), roles)
        if label.startswith("unreadable"):
            if os.geteuid() == 0:
                continue   # root reads a mode-000 file
            (folder / "agent.conf").chmod(0)
        record.write_text("")
        run_env = dict(env, PROJECT_BUZZ_CLI=str(cli), PROJECT_BUZZ_AGENT_DIR=str(folder))
        if label == "supervisor":
            listed, replies = mcp(run_env, [(name, arguments) for name, arguments, _ in CHANNEL_CALLS])
            if listed != BASE_TOOLS | CHANNEL_TOOLS:
                failures.append(f"{label}: tools/list {sorted(listed ^ (BASE_TOOLS | CHANNEL_TOOLS))}")
            for (name, arguments, argv), reply in zip(CHANNEL_CALLS, replies):
                if argv is None:
                    if not refused(reply):
                        failures.append(f"{label}: {name} {arguments!r} was not refused: {reply}")
                elif refused(reply):
                    failures.append(f"{label}: {name} {arguments!r} was refused: {reply}")
                else:
                    got = json.loads(reply["result"]["content"][0]["text"])
                    if got != ["--format", "agent", *argv]:
                        failures.append(f"{label}: {name} {arguments!r} ran {got}, not {argv}")
            ran = [json.loads(line) for line in record.read_text().splitlines()]
            expected = sorted(["--format", "agent", *argv] for _, _, argv in CHANNEL_CALLS if argv is not None)
            if sorted(ran) != expected:
                failures.append(f"{label}: the CLI's {len(ran)} recorded runs are not the {len(expected)} expected ones")
        else:
            # One well-formed call per channel tool: none is listed, and none runs the CLI.
            calls = [next((n, a) for n, a, argv in CHANNEL_CALLS if n == tool and argv is not None)
                     for tool in sorted(CHANNEL_TOOLS)]
            listed, replies = mcp(run_env, calls)
            if listed != BASE_TOOLS:
                failures.append(f"{label}: tools/list differs from the base set by {sorted(listed ^ BASE_TOOLS)}")
            for (name, _), reply in zip(calls, replies):
                if not refused(reply):
                    failures.append(f"{label}: {name} was not refused: {reply}")
            if record.read_text():
                failures.append(f"{label}: the CLI ran: {record.read_text()!r}")
    assert not failures, "\n".join(failures)
    return len(CHANNEL_CALLS)


async def check(server, tmp):
    home = tmp / "home"
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True)
    project = tmp / "project"
    project.mkdir()
    marker = "project contents"
    (project / "PROJECT.md").write_text(marker)
    (project / "outside").symlink_to(tmp / "private.txt")
    (tmp / "private.txt").write_text("outside fixture")
    (tmp / "outside-dir").mkdir()
    (tmp / "outside-dir" / "secret.txt").write_text("outside fixture")
    (project / "dirlink").symlink_to(tmp / "outside-dir", target_is_directory=True)
    personal = tmp / "personal-mcp.py"
    personal.write_text(EXTRA_MCP)
    (codex_home / "config.toml").write_text(
        f'openai_base_url="http://127.0.0.1:{server.server_port}/v1"\n'
        '[mcp_servers."unrelated.fixture"]\ncommand="false"\n'
        f'[mcp_servers.personal]\ncommand="{sys.executable}"\nargs=["-I", "{personal}"]\n'
    )
    cli = DEPS / "node_modules/.bin/codex"
    # Route the provider to localhost using a dummy API key. All role and tool
    # settings are supplied by the production adapter underneath this fixture.
    driver = tmp / "codex-fixture"
    driver.write_text("#!" + sys.executable + "\nimport os,sys\n"
                      f"cli={str(cli)!r}\n"
                      "os.execv(cli,[cli,*sys.argv[1:],'-c','forced_login_method=\"api\"'])\n")
    driver.chmod(0o700)
    env = dict(HOME=str(home), PATH=os.environ["PATH"], CODEX_HOME=str(codex_home),
               TMPDIR=str(tmp), OPENAI_API_KEY="local-fixture", NO_PROXY="127.0.0.1,localhost",
               PROJECT_BUZZ_CLI=shutil.which("false") or "/usr/bin/false",
               PROJECT_BUZZ_CODEX_CLI=str(driver), PROJECT_BUZZ_ADAPTER=str(DEPS / "package.json"),
               PROJECT_BUZZ_AGENT_DIR=str(tmp), PROJECT_BUZZ_WORKSPACE=str(project))
    # A folder without agent.conf (as the reviewer's is in this respect): no channel tools reach the model.
    await codex_session(server, env, project)
    assert_model_tools(server, BASE_TOOLS)
    # The channel supervisor's folder: the same adapter offers the model the channel tools too.
    supervisor = agent_folder(tmp / "supervisor", "role=supervisor\n")
    await codex_session(server, dict(env, PROJECT_BUZZ_AGENT_DIR=str(supervisor)), project)
    assert_model_tools(server, BASE_TOOLS | CHANNEL_TOOLS)
    # Exercise the exact MCP tools registered by the Codex partner.
    protocol = [
        {"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
         "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}},
        {"method": "notifications/initialized"},
        *({"id": i, "method": "tools/call", "params": {"name": "read_project", "arguments": {"path": name}}}
          for i, name in [(2, "PROJECT.md"), (3, "outside"), (4, "../private.txt"), (5, "dirlink/secret.txt")]),
        {"id": 6, "method": "tools/call", "params": {"name": "list_project", "arguments": {"path": "dirlink"}}}]
    run = subprocess.run([RUNTIME / "buzz-tools"], env=env, text=True, capture_output=True,
                         input="".join(json.dumps(dict(jsonrpc="2.0", **m))+"\n" for m in protocol),
                         timeout=15, check=True)
    responses = {r["id"]: r["result"] for r in map(json.loads, run.stdout.splitlines())}
    assert marker in str(responses[2]) and not responses[2].get("isError")
    assert all(responses[i].get("isError") and "outside fixture" not in str(responses[i]) for i in (3, 4, 5))
    assert responses[6].get("isError") and "secret.txt" not in str(responses[6])
    return check_channel_tools(tmp, env)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="buzz-codex-test-") as folder:
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model) as endpoint:
            endpoint.tool_lists, endpoint.models = [], []
            threading.Thread(target=endpoint.serve_forever, daemon=True).start()
            try:
                rows = asyncio.run(check(endpoint, Path(folder)))
            finally:
                endpoint.shutdown()
    print("Verified Codex tool declarations without personal MCP tools, the chosen model, project reads, "
          "and denied external paths, symbolic-link directories included; the channel tools reach the "
          f"channel supervisor's model only, and {rows} channel tool calls give the CLI exactly their "
          f"arguments or are refused, with none for the {len(FOLDERS) - 1} other agent folders.")
