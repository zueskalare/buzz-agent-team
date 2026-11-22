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
    assert server.tool_lists
    for tools in server.tool_lists:
        if not tools:
            continue
        names = {tool.get("name", tool["type"]) for tool in tools}
        assert names <= {"functions", "mcp__buzz_discussion", "list_mcp_resources", "read_mcp_resource",
                         "list_mcp_resource_templates", "request_user_input"}, names
        for entry in tools:
            if entry.get("name") == "mcp__buzz_discussion":
                assert {tool["name"] for tool in entry["tools"]} == {
                    "list_project", "read_project", "read_channel", "read_thread", "search_messages",
                    "read_canvas", "read_issue", "list_issues", "post_message",
                    "list_memory", "read_memory", "save_memory"}
            if entry.get("name") == "functions":
                assert {t["name"] for t in entry["tools"]} <= {
                    "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource",
                    "request_user_input"}, entry
    assert any(t.get("name") == "mcp__buzz_discussion" for tools in server.tool_lists for t in tools)
    assert set(server.models) == {MODEL}, server.models
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


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="buzz-codex-test-") as folder:
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model) as endpoint:
            endpoint.tool_lists, endpoint.models = [], []
            threading.Thread(target=endpoint.serve_forever, daemon=True).start()
            try:
                asyncio.run(check(endpoint, Path(folder)))
            finally:
                endpoint.shutdown()
    print("Verified Codex tool declarations without personal MCP tools, the chosen model, project reads, "
          "and denied external paths, symbolic-link directories included.")
