"""Live checks of the stock Codex adapter as every agent on Codex runs it: codex-acp in its agent mode,
driven over ACP as the Buzz harness drives it (every permission request answered with its first allow
option), with a local model. Offline: a loopback model endpoint, a fixture API key, a disposable home folder.

    python3 test-codex-adapter.py [--also-browser] [--also-buzz-rule]
    AGENT_TEAM_CODEX_CLI=/full/path/to/codex python3 test-codex-adapter.py [--also-browser] [--also-buzz-rule]

Each check is opt-in; without an option the program says which there are and runs none. The adapter runs
the Codex CLI it bundles, or the one AGENT_TEAM_CODEX_CLI names (as team.sh names it to an agent on Codex,
by CODEX_PATH), so the checks can be run for adapter 1.13.1 with a newer Codex. Each result line names the
Codex CLI that was driven and its version.

--also-browser: the browser of the project folder, in a project folder whose .codex/config.toml names the
Playwright server exactly as workspace-browser.py writes it. The local model asks the browser to open a
loopback page, to save a screenshot without a name and one named outside the project folder, and to open
a file: address; it answers Codex's own reviewer with "allow". It asserts that the browser tools are
offered, that the page opens, that the screenshot lands in .browser-output/, and that the outside file and
the file: address are refused. It needs codex-acp, npx and Google Chrome, and it is offline apart from
npx's cache (npm_config_cache, else ~/.npm), where it fetches @playwright/mcp@0.0.86 once when it is not
cached yet.

--also-buzz-rule: the buzz rule, PROJECT/.codex/rules/buzz.rules exactly as workspace-settings.py codex
writes it. A stand-in buzz on PATH reports whether it reaches a page on a loopback address. The local model
runs a plain buzz command, then five lines that combine buzz with something else; it answers Codex's own
reviewer with "allow" and counts the times it is asked. It asserts that the plain command reaches the
network, that none of the five does, that the reviewer is not asked, and that no permission request
reaches the client; then, in a project folder without the rule file, that a plain buzz command does not
reach the network. It needs codex-acp.
"""
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
import time

SKILL = Path(__file__).resolve().parent / "buzz-agent-team"


def stock_adapter(option):
    """codex-acp on PATH, and the Codex CLI to drive: the file AGENT_TEAM_CODEX_CLI names (a full path; none
    means none), as team.sh takes it, else the one the adapter bundles, found as agent-team.sh finds it
    (codex_choice). Unlike team.sh, an unset AGENT_TEAM_CODEX_CLI means the adapter's own here, so that a
    plain run measures the adapter as it is installed."""
    adapter = shutil.which("codex-acp")
    if not adapter:
        raise SystemExit(f"{option} needs codex-acp (@agentclientprotocol/codex-acp@1.13.1) on PATH.")
    named = os.environ.get("AGENT_TEAM_CODEX_CLI", "")
    if named and named != "none":
        cli = Path(named)
        if not (cli.is_absolute() and cli.is_file() and os.access(cli, os.X_OK)):
            raise SystemExit(f"AGENT_TEAM_CODEX_CLI={named} is not a program that can be run (a full path).")
        return adapter, cli
    return adapter, Path(os.path.realpath(adapter)).parent.parent / "node_modules/.bin/codex"


def codex_words(cli):
    """The Codex CLI that was driven, and its version, for the result lines."""
    try:
        version = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        version = ""
    source = "AGENT_TEAM_CODEX_CLI" if os.environ.get("AGENT_TEAM_CODEX_CLI", "none") != "none" else "the adapter's own"
    return f"{cli} ({version or 'version unknown'}, {source})"


def codex_fixture(tmp, cli, port):
    """A disposable Codex home whose provider is the loopback model, and a CODEX_PATH that signs in with the
    fixture key, the adapter's other sign-in method."""
    home = tmp / "h"
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True)
    (codex_home / "config.toml").write_text(f'openai_base_url="http://127.0.0.1:{port}/v1"\n')
    driver = tmp / "codex-fixture"
    driver.write_text("#!" + sys.executable + "\nimport os,sys\n" f"cli={str(cli)!r}\n"
                      "os.execv(cli,[cli,*sys.argv[1:],'-c','forced_login_method=\"api\"'])\n")
    driver.chmod(0o700)
    return dict(HOME=str(home), PATH=os.environ["PATH"], CODEX_HOME=str(codex_home), OPENAI_API_KEY="local-fixture",
                NO_PROXY="127.0.0.1,localhost", TMPDIR=os.environ.get("TMPDIR", "/tmp"), CODEX_PATH=str(driver),
                INITIAL_AGENT_MODE="agent")


def review_answer(fmt):
    """An answer of "allow" to Codex's own reviewer, in the shape its JSON schema asks for."""
    answer = {}
    for key, value in ((fmt.get("schema") or {}).get("properties") or {}).items():
        choices = value.get("enum")
        if choices:
            answer[key] = next((c for c in choices if c in ("allow", "approve", "approved", "low")), choices[0])
        elif value.get("type") == "string":
            answer[key] = "A command on the user's own loopback server; low risk."
        elif value.get("type") in ("number", "integer"):
            answer[key] = 5
        elif value.get("type") == "boolean":
            answer[key] = True
        elif value.get("type") == "array":
            answer[key] = []
    return answer


def is_review(request):
    fmt = (request.get("text") or {}).get("format") or {}
    return fmt.get("type") == "json_schema" and "guardian" in json.dumps(request)[:200000].lower(), fmt


def emit_response(handler, output):
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.end_headers()
    def emit(data):
        handler.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
    emit({"type": "response.created", "response": {"id": "resp_b", "output": [], "status": "in_progress"}})
    for i, item in enumerate(output):
        emit({"type": "response.output_item.done", "output_index": i, "item": item})
    emit({"type": "response.completed", "response": {"id": "resp_b", "output": output, "status": "completed",
          "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})


def review_message(server, fmt):
    answer = review_answer(fmt)
    server.reviews.append(answer)
    return [dict(type="message", id=f"msg_r{len(server.reviews)}", role="assistant", status="completed",
                 content=[dict(type="output_text", text=json.dumps(answer), annotations=[])])]


def output_text(item):
    output = (item or {}).get("output")
    if isinstance(output, list):
        return " ".join(part.get("text", "") for part in output if isinstance(part, dict))
    return str(output or "")


async def adapter_session(adapter, project, env, more, prompts=10):
    """One session of the stock adapter: initialize, a new session (signing in with the fixture key when
    asked), then prompts while more() says so, at most PROMPTS. Returns the permission requests that
    reached the client."""
    process = await asyncio.create_subprocess_exec(adapter, cwd=project, env=env, stdin=-1, stdout=-1,
                                                   stderr=asyncio.subprocess.DEVNULL, limit=64 * 1024 * 1024)
    next_id = 0
    asked = []

    async def send(message):
        process.stdin.write((json.dumps(message) + "\n").encode())
        await process.stdin.drain()

    async def request(method, params):
        nonlocal next_id
        next_id += 1
        mine = next_id
        await send(dict(jsonrpc="2.0", id=mine, method=method, params=params))
        while True:
            line = await process.stdout.readline()
            if not line:
                raise RuntimeError("the adapter exited")
            msg = json.loads(line)
            if msg.get("id") == mine and "method" not in msg:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {json.dumps(msg['error'])[:300]}")
                return msg["result"]
            if msg.get("method") == "session/request_permission":
                # As the harness answers: the first allow_once option.
                options = msg["params"]["options"]
                asked.append(msg["params"].get("toolCall", {}).get("title"))
                pick = next((o for o in options if o.get("kind") == "allow_once"), None)
                await send(dict(jsonrpc="2.0", id=msg["id"], result={"outcome": {"outcome": "selected", "optionId": pick["optionId"]}
                                                                      if pick else {"outcome": "cancelled"}}))
            elif "id" in msg and "method" in msg:
                await send(dict(jsonrpc="2.0", id=msg["id"], error={"code": -32601, "message": "not supported"}))

    try:
        async with asyncio.timeout(300):
            init = await request("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
            try:
                session = await request("session/new", {"cwd": str(project), "mcpServers": []})
            except RuntimeError:
                method = next(a["id"] for a in init.get("authMethods", []) if "api" in a.get("id", "").lower())
                await request("authenticate", {"methodId": method})
                session = await request("session/new", {"cwd": str(project), "mcpServers": []})
            for _ in range(prompts):
                if not more():
                    break
                await request("session/prompt", {"sessionId": session["sessionId"], "prompt": [{"type": "text", "text": "Test."}]})
                await asyncio.sleep(1)
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 5)
        except TimeoutError:
            process.terminate()
            await process.wait()
    return asked


def new_project(tmp):
    """A Git project folder, as the workspace of a team is; the stock adapter marks it trusted."""
    project = tmp / "p"
    project.mkdir()
    subprocess.run(["git", "init", "-q", str(project)], check=True, env={"PATH": os.environ["PATH"], "HOME": str(tmp)})
    return project.resolve()


# ---------------------------------------------------------------- --also-browser
BROWSER_PACKAGE = "@playwright/mcp@0.0.86"
NPM_CACHE = os.environ.get("npm_config_cache") or os.path.expanduser("~/.npm")
PAGE = b"<html><head><title>Fixture page</title></head><body><h1>PAGE-MARKER</h1></body></html>"


# The model's first call: list the browser tools that the model is offered. The stock adapter's Codex runs
# its models in code mode, where the tools of a tool server are deferred: they are not in the request, and
# the model finds them in ALL_TOOLS of its exec tool, as the exec tool's description says.
LIST_TOOLS = 'text(JSON.stringify(ALL_TOOLS.map(t => t.name).filter(n => n.indexOf("playwright") >= 0)))'


class BrowserModel(http.server.BaseHTTPRequestHandler):
    """A Responses endpoint that lists the browser tools through exec until they are there (a few times per
    turn), then makes the scripted browser calls, one per request; it answers Codex's reviewer with
    "allow", and serves a page for the browser to open."""
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        for item in request.get("input", []):
            if item.get("type") in ("function_call_output", "mcp_tool_call_output", "custom_tool_call_output"):
                self.server.outputs[item.get("call_id")] = item
        review, fmt = is_review(request)
        output = []
        server = self.server
        if review:
            output = review_message(server, fmt)
        else:
            if server.phase == "list":
                listed = server.outputs.get(f"list_{server.lists}")
                if listed is not None and "browser_navigate" in json.dumps(listed):
                    server.phase, server.listed = "script", json.dumps(listed)
            if server.phase == "list":
                if server.tries_this_turn < 3:
                    if server.tries_this_turn:
                        time.sleep(1)
                    server.lists += 1
                    server.tries_this_turn += 1
                    output = [dict(type="custom_tool_call", id=f"ctc_{server.lists}", call_id=f"list_{server.lists}",
                                   status="completed", name="exec", input=LIST_TOOLS)]
            elif server.phase == "script" and server.turn < len(server.script):
                n = server.turn
                call = dict(server.script[n])
                call["arguments"] = call["arguments"].replace("{PORT}", str(server.server_port))
                output = [dict(type="function_call", id=f"fc_{n}", call_id=f"call_{n}", status="completed", **call)]
                server.turn += 1
        emit_response(self, output)


async def browser_session(server, tmp):
    """One session of the stock Codex adapter in its agent mode, prompted until the scripted browser calls are
    made. Returns the permission requests that reached the client and the project folder."""
    adapter, cli = stock_adapter("--also-browser")
    npx = shutil.which("npx")
    if not npx:
        raise SystemExit("--also-browser needs npx on PATH.")
    project = new_project(tmp)
    # The entry is put there by the production helper, as create and team.sh do.
    subprocess.run([sys.executable, "-I", str(SKILL / "scripts" / "workspace-browser.py"), "apply", "codex", str(project)],
                   check=True, stdout=subprocess.DEVNULL)
    env = dict(codex_fixture(tmp, cli, server.server_port), npm_config_cache=NPM_CACHE)
    # The package is fetched once first, as a start with the browser on does.
    warm = subprocess.run([npx, "-y", BROWSER_PACKAGE, "--version"], env=env, capture_output=True, text=True, timeout=300)
    assert warm.returncode == 0, f"npx -y {BROWSER_PACKAGE} --version failed: {(warm.stderr or warm.stdout)[-400:]}"

    def more():
        # The tool server starts in the background: prompt again until its tools are listed and called.
        if server.turn >= len(server.script):
            return False
        server.tries_this_turn = 0
        return True
    asked = await adapter_session(adapter, project, env, more)
    return asked, project


def check_browser(tmp):
    outside = tmp / "outside"
    outside.mkdir()
    script = [
        {"namespace": "mcp__playwright", "name": "browser_navigate", "arguments": json.dumps({"url": "http://127.0.0.1:{PORT}/page"})},
        {"namespace": "mcp__playwright", "name": "browser_take_screenshot", "arguments": "{}"},
        {"namespace": "mcp__playwright", "name": "browser_take_screenshot", "arguments": json.dumps({"filename": str(outside / "stolen.png")})},
        {"namespace": "mcp__playwright", "name": "browser_navigate", "arguments": json.dumps({"url": "file:///etc/hosts"})},
    ]
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), BrowserModel) as server:
        server.script, server.turn, server.outputs, server.reviews = script, 0, {}, []
        server.phase, server.lists, server.tries_this_turn, server.listed = "list", 0, 0, ""
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            asked, project = asyncio.run(browser_session(server, tmp))
        finally:
            server.shutdown()
    def said(n):
        return output_text(server.outputs.get(f"call_{n}"))
    saved = sorted(p.name for p in (project / ".browser-output").glob("*.png")) if (project / ".browser-output").is_dir() else []
    # (a) the browser tools are offered to the model: its exec tool lists them.
    assert "mcp__playwright__browser_navigate" in server.listed and "mcp__playwright__browser_take_screenshot" in server.listed, \
        f"the browser tools were not listed after {server.lists} tries: {list(server.outputs.values())[-1:]}"
    assert server.turn == len(script), f"only {server.turn} of {len(script)} browser calls were made"
    # (b) a page on a loopback address opens.
    assert "Fixture page" in said(0) and "### Error" not in said(0), said(0)[:400]
    # (c) a screenshot saved without a name lands in .browser-output/ in the project folder.
    assert ".browser-output/" in said(1) and saved, (said(1)[:400], saved)
    # (d) a named file outside the project folder is refused, and nothing is written there.
    assert "outside allowed roots" in said(2) and not (outside / "stolen.png").exists(), said(2)[:400]
    # (e) a file: address is refused.
    assert 'Access to "file:" protocol is blocked' in said(3), said(3)[:400]
    return len(server.reviews), len(asked)


# ---------------------------------------------------------------- --also-buzz-rule
PLAIN = "buzz messages send --channel x --content plain"
# Lines that combine buzz with something else: each must stay in Codex's sandbox, without the network.
COMBINED = [
    "buzz messages send --content A; echo other",
    "cd . && buzz messages send --content B",
    "echo x | buzz messages send --content C",
    "/bin/sh -c 'buzz messages send --content D'",
    "FOO=1 buzz messages send --content E",
]


def exec_call(command):
    """The model's call: one shell command through the exec tool of Codex's code mode."""
    return "text((await tools.exec_command({cmd: " + json.dumps(command) + ", login: false})).output)"


class BuzzModel(http.server.BaseHTTPRequestHandler):
    """A Responses endpoint that makes the scripted commands, one per request, answers Codex's reviewer
    with "allow" (and counts it), and serves a page on a loopback address for the stand-in buzz to reach."""
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        for item in request.get("input", []):
            if item.get("type") in ("function_call_output", "custom_tool_call_output"):
                self.server.outputs[item.get("call_id")] = item
        review, fmt = is_review(request)
        output = []
        server = self.server
        if review:
            output = review_message(server, fmt)
        elif server.turn < len(server.script):
            n = server.turn
            output = [dict(type="custom_tool_call", namespace="functions", id=f"ctc_{n}", call_id=f"call_{n}",
                           status="completed", name="exec", input=exec_call(server.script[n]))]
            server.turn += 1
        emit_response(self, output)


async def buzz_session(server, tmp, with_rule):
    """One session of the stock Codex adapter in its agent mode, in a project folder with or without the
    buzz rule, with a stand-in buzz first on PATH. Returns the permission requests that reached the client."""
    adapter, cli = stock_adapter("--also-buzz-rule")
    project = new_project(tmp)
    if with_rule:
        # The rule file is put there by the production helper, as create and team.sh do.
        subprocess.run([sys.executable, "-I", str(SKILL / "scripts" / "workspace-settings.py"), "apply", "codex", str(project)],
                       check=True, stdout=subprocess.DEVNULL)
    bindir = tmp / "bin"
    bindir.mkdir()
    (bindir / "buzz").write_text(
        "#!/bin/sh\nprintf 'buzz-standin args=%s ' \"$*\"\n"
        f"curl -s -m 4 -o /dev/null -w 'loopback=%{{http_code}}\\n' http://127.0.0.1:{server.server_port}/page"
        " || printf 'loopback=FAILED(%s)\\n' $?\n")
    (bindir / "buzz").chmod(0o755)
    env = codex_fixture(tmp, cli, server.server_port)
    env["PATH"] = str(bindir) + ":" + env["PATH"]
    return await adapter_session(adapter, project, env, lambda: server.turn < len(server.script), prompts=3)


def check_buzz_rule(tmp):
    runs = {}
    for with_rule, script in ((True, [PLAIN] + COMBINED), (False, [PLAIN])):
        folder = tmp / ("with-rule" if with_rule else "without-rule")
        folder.mkdir()
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), BuzzModel) as server:
            server.script, server.turn, server.outputs, server.reviews = script, 0, {}, []
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                asked = asyncio.run(buzz_session(server, folder, with_rule))
            finally:
                server.shutdown()
        assert server.turn == len(script), f"only {server.turn} of {len(script)} commands were made"
        runs[with_rule] = ([output_text(server.outputs.get(f"call_{n}")) for n in range(len(script))], server.reviews, asked)
    said, reviews, asked = runs[True]
    assert all("buzz-standin args=" in s for s in said), said
    # (a) with the rule a plain buzz command reaches the network.
    assert "loopback=200" in said[0], said[0]
    # (b) a line that combines buzz with anything else stays in the sandbox, without the network.
    for command, s in zip(COMBINED, said[1:]):
        assert "loopback=FAILED" in s and "loopback=200" not in s, (command, s)
    # (c) Codex's own reviewer is not asked, and no permission request reaches the client.
    assert not reviews, reviews
    assert not asked, asked
    # (d) without the rule file a plain buzz command does not reach the network.
    said, reviews, asked = runs[False]
    assert "buzz-standin args=" in said[0] and "loopback=FAILED" in said[0] and "loopback=200" not in said[0], said[0]
    return len(COMBINED), len(reviews), len(asked)


if __name__ == "__main__":
    options = sys.argv[1:]
    if not options or set(options) - {"--also-browser", "--also-buzz-rule"}:
        print("usage: python3 test-codex-adapter.py [--also-browser] [--also-buzz-rule]\n"
              "Each check is opt-in (see the top of this file); nothing was run.", file=sys.stderr)
        sys.exit(2)
    if "--also-browser" in options:
        folder = tempfile.mkdtemp(prefix="buzz-codex-browser-")
        try:
            reviews, asked = check_browser(Path(folder))
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        print("Measured over ACP with the stock Codex adapter in its agent mode and .codex/config.toml as workspace-browser.py "
              "writes it: the browser tools are offered, a loopback page opens, a screenshot without a name lands in "
              ".browser-output/, a named file outside the project folder is refused, and a file: address is refused; "
              f"Codex's own reviewer was asked {reviews} time(s), and {asked} permission request(s) reached the client. "
              f"Codex CLI: {codex_words(stock_adapter('--also-browser')[1])}.")
    if "--also-buzz-rule" in options:
        folder = tempfile.mkdtemp(prefix="buzz-codex-rule-")
        try:
            combined, reviews, asked = check_buzz_rule(Path(folder))
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        print("Measured over ACP with the stock Codex adapter in its agent mode and .codex/rules/buzz.rules as "
              "workspace-settings.py writes it: a plain buzz command reached the network, with no review by Codex's "
              f"own reviewer and no permission request; none of the {combined} lines that combine buzz with something "
              "else did; and without the rule file a plain buzz command did not reach the network (Codex's reviewer "
              f"was asked {reviews} time(s) and {asked} permission request(s) reached the client in that session). "
              f"Codex CLI: {codex_words(stock_adapter('--also-buzz-rule')[1])}.")
