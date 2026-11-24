# Buzz agent team setup

One skill, for Claude Code and for Codex, that sets up a set of Buzz agents for one workspace and one channel in chat. You install it once. Then you ask Claude Code or Codex for a new set of agents, and the skill walks you through every step: it checks what is missing, asks one question at a time, lists the models your sign-in offers, runs the steps, shows the public keys, takes the proofs you copy from Buzz Desktop, and tells you how to start the agents.

- `buzz-agent-team/`: the skill folder, complete on its own. Copying it into a tool's skills folder gives a working skill.
  - `VERSION`: the skill's version, one line (see [Versions](#versions)).
  - `SKILL.md`: the guided flow, for both tools.
  - `scripts/agent-team.sh`: the script that does every step (Bash 3.2 or later, mode 755). `agent-team.sh help` lists every command and option.
  - `scripts/run-buzz-acp.sh`: the launcher, the program that starts one agent (since 5.4.0 part of the skill, because it changes together with it). `agent-team.sh launcher` puts it on `PATH` (see [The launcher](#the-launcher)).
  - `scripts/workspace-settings.py`: puts the settings of each backend into the project folder, and checks them: the sandbox settings of an agent on Claude, the buzz rule of an agent on Codex (see What holds each agent). `create` and `upgrade` also copy it into each team folder, where `team.sh` runs it before a start.
  - `scripts/workspace-browser.py`: names the browser, the Playwright tool server, in the project folder, checks it and takes it out (see [The browser of the project folder](#the-browser-of-the-project-folder)). `create` and `upgrade` also copy it into each team folder, where `team.sh` runs it before a start.
  - `scripts/acp-models.py`: lists the models an ACP adapter offers, without a model turn (used by `agent-team.sh models`; `create` and `upgrade` also copy it into each team folder, where `team.sh` runs it before a model menu).
  - `templates/`: the role prompts. `agent.md` holds the workspace agent's rules, `supervisor.md` the channel supervisor's and `reviewer.md` the reviewer's (see [The two jobs](#the-two-jobs)). What each agent may do is a rule in its prompt. `project.md` seeds the shared project record and `subscriptions.toml` configures which messages reach the channel supervisor. `legacy/` holds the pre-20-November prompts; nothing uses them any more.
  - `templates/team.sh`: the team's own command. `create` and `upgrade` copy it into each team folder, where it checks, starts, stops and reports that folder's agents without this skill (see The team's own command).
  - `templates/agent-start.sh`: one agent's own start command. `create` and `upgrade` copy it into each agent folder as `start.sh` (see One agent at a time).
  - `templates/agent-restart.sh`: one agent's own restart command. `create` and `upgrade` copy it into each agent folder as `restart.sh` (see [Restart](#restart-the-same-run-again)).
- `install.sh`: copies the skill folder into Claude Code's and Codex's skills folders.
- `CHANGELOG.md`: what changed in each version.
- `test-agent-team.sh`, `test-team-sh.sh`, `test-workspace-settings.py`, `test-codex-adapter.py`: offline tests (see Test).

## Install, update, remove

```sh
/path/to/buzz/local/agent-team/setup/install.sh
```

- **What it does:** it installs into every tool whose folder exists: `~/.claude/skills/buzz-agent-team` and `$CODEX_HOME/skills/buzz-agent-team` (usually `~/.codex/skills/buzz-agent-team`).
- **Options:** `--claude` or `--codex` (one tool only); `--claude-dir DIR` or `--codex-dir DIR` (another skills folder); `--dry-run`; `--uninstall`.
- **Safe to repeat.** Running it again updates the copies, or says they are up to date. It refuses a target it did not make (a file, a symbolic link, or another skill with the same name) and never touches other skills or `~/.buzz-agents`.
- **Codex's folder.** If Codex does not list the skill after a restart, run `install.sh --codex-dir ~/.agents/skills`, then `install.sh --uninstall --codex`.

### A copy installed by a skill manager

If the skill was installed by another tool as one folder that both skills folders link to (for example `~/.cc-switch/skills/buzz-agent-team`), `install.sh` refuses those links. Update that folder in place instead, and nothing else of that tool:

```sh
src=/path/to/buzz/local/agent-team/setup/buzz-agent-team
dst=~/.cc-switch/skills/buzz-agent-team
diff -rq "$src" "$dst"                                  # what will change
rsync -a --delete --dry-run --itemize-changes "$src/" "$dst/"   # the same, as rsync sees it
rsync -a --delete "$src/" "$dst/"                       # update: only that folder changes
diff -rq "$src" "$dst" && echo "up to date"
"$dst/scripts/agent-team.sh" version                    # the installed version
```

### The launcher

`run-buzz-acp.sh`, the program that starts one agent, is part of the skill since 5.4.0: `scripts/run-buzz-acp.sh`. It changes together with the skill, so the skill brings the copy that fits it. Agents are started with the launcher on `PATH`, where each team's own command looks for it. One command puts the skill's copy there:

```sh
"$dst/scripts/agent-team.sh" launcher --dry-run          # what it would write
"$dst/scripts/agent-team.sh" launcher                    # install it, or replace the one PATH finds
```

- **Where:** it replaces the `run-buzz-acp.sh` that `PATH` finds now. When there is none, it installs it into `~/.local/bin` and says so if that folder is not on `PATH`. `--dir DIR` names another folder.
- **The earlier file is kept** beside the new one as `run-buzz-acp.sh.bak-<UTC time>`. The same file is left as it is. A symbolic link is refused.
- **Agents that already run are not affected.** The launcher has become the harness by then; they get the new one at their next start.
- **It is the only command that writes there.** `preflight`, `status`, `create` and `upgrade` only say when the launcher a start would use is not the skill's: `preflight` as a `note` line with the command as its fix, the others as one line that starts `Launcher:`.
- **A launcher named in the settings** (`agent-team.sh settings --launcher <path>`, or `AGENT_TEAM_LAUNCHER`) still wins for this skill's own `start`. A team's own command uses the one on `PATH`.

## Versions

The skill has one version number, `MAJOR.MINOR.PATCH`. It is the one line of `buzz-agent-team/VERSION`; `SKILL.md` repeats it as `metadata.version`, and `CHANGELOG.md` says what each version changed.

```sh
agent-team.sh version                             # this skill folder's version
agent-team.sh status                              # the same, and the version recorded in each team folder
agent-team.sh status shop                         # one team's recorded version beside this skill's
~/.buzz-agents/shop/team.sh version               # the same from the team folder, without the skill
```

- **Three copies, one number each.** The source here, the installed skill folder and every team folder each hold a `VERSION` file, so you can see which copy is behind. `install.sh` prints the source's version beside the installed one and records it in its marker.
- **A team folder's `VERSION`** is the version of the skill that created the folder or last upgraded it, and so the version its `team.sh`, each `start.sh` and `restart.sh`, `acp-models.py`, `workspace-settings.py`, `workspace-browser.py` and the agents' generated files come from. `create` writes it for a new team folder only. `upgrade` replaces it as its last step, so an upgrade that is cut short leaves the earlier version there, and shows the change in its plan as `VERSION: <recorded> -> <this skill's>`; when that is the plan's only line, nothing else in the team differs. A team made before 1.0.0 has none until it is upgraded.
- **A skill folder without a valid `VERSION`** is refused by `install.sh`, and its `create` and `upgrade` stop before they write anything.
- **What each number means:**
  - **Major:** a team made by the earlier version must be upgraded before it starts (the format of the team folder changed), or a command or option was removed or changed its meaning.
  - **Minor:** something new: a command, an option, a role, a file in the team folder. A team made earlier still starts as it is, and `upgrade` gives it the new files.
  - **Patch:** a fix or a change of wording.

### This folder is a Git repository

`local/agent-team/setup/` is a repository of its own, inside a folder the Buzz checkout ignores, so nothing here reaches the Buzz repository. Its remote, `origin`, is a repository on GitHub (`git remote -v` shows it); pushing needs `--follow-tags` or `git push origin v<version>` for a new version's tag to go with it.

- **`main`** holds released versions only: every commit that changes the version is tagged `v<version>`, and what you install comes from a tag.
- **Unfinished work** lives on a branch until its tests pass, then is merged into `main` with a new version.

To release a version:

1. Edit `buzz-agent-team/VERSION` and `metadata.version` in `buzz-agent-team/SKILL.md`, and add the entry at the top of `CHANGELOG.md`. A test fails when the three disagree.
2. Run the tests (see [Test](#test)).
3. Commit, then `git tag -a v<version> -m "buzz-agent-team <version>"`.
4. Install it (above), then run `agent-team.sh upgrade <team> --dry-run` for each team, with its agents stopped, and the same without `--dry-run`.

`git status --short` printing nothing and `git describe --tags` printing a bare tag such as `v1.0.0` mean the folder is exactly that version.

## Use

- **Claude Code:** type `/buzz-agent-team`, or ask "set up a new set of Buzz agents for ~/code/shop".
- **Codex:** type `$buzz-agent-team` (or pick it with `/skills`), or ask the same. Restart Codex if a newly installed skill does not appear.

The skill asks, in this order: the backend of each agent (the same for both, or different), then runs preflight and lists the models; the model of each agent; your community address and public key; the workspace; the channel; which agents; their names; an optional brief; each ownership proof; how the agents join the channel; and your go-ahead after the dry run. It gives you the `start` commands to run in your own terminal.

### The two jobs

A team has two agents with two jobs; this README calls them by their jobs. Options name their roles, `agent` and `supervisor` (`--agent-model`, `--supervisor-model`). Each has a folder in the team folder, and a command line names an agent by its folder:

- **The workspace agent's folder is named after the team,** exactly as written: for a team called `shop`, `~/.buzz-agents/shop/shop/`, recorded in `team.conf` as `agent_folder=shop`. When the team's name is one a team folder uses for something else (`supervisor`, `reviewer`, `models`, `wall`, `team.sh`, `team.conf`, `acp-models.py`, `workspace-settings.py`, `workspace-browser.py`, `VERSION`, `brief.md`, ignoring case, or a name starting with a dot), the folder is `agent/`, and `create` says so. `agent` also names the workspace agent on any command line: `team.sh start shop` and `team.sh start agent` are the same.
- **The channel supervisor's folder is `supervisor/`.** A reviewer's own team has `reviewer/`.
- **Menus, the check and `status` name an agent by its display name** (`Shop: provider?`); where a line shows the name to type, it is the folder name (`shop: Shop, the workspace agent`).


- **The workspace agent** (named after the project) is the project's agent in the workspace: a supervisor in subagent mode. It plans the work, dispatches bounded work to worker subagents, reviews their evidence, and keeps `PROJECT.md` and the tracker. It has every tool of its adapter. It takes a turn when you or its channel supervisor mention it. It starts workers or changes files only for a bounded run you accepted, and it checks that the accepting message is signed by you, also when the channel supervisor relays it.
- **The channel supervisor** (`supervisor`, "<Project> Supervisor") takes a turn on every ordinary message in every channel it is a member of, and talks with anyone there (since 5.3.0; before that, without a mention only in its team's channel). It runs brainstorms to a decision, proposes todos, brings decisions to you, and hands work you accepted to the workspace agent by mentioning it and naming your accepting message. It does small things itself: reading the project, looking at a picture someone posts in Buzz, a quick command, a small change you asked for.
- **Every agent has every tool of its adapter.** All agents run the stock adapter in bypass-permissions, so no person approves a tool call. What each one may do is a rule in its prompt, which nothing enforces: the channel supervisor acts only for you, and checks that the asking message is signed by you, before it changes a file, runs a command that changes something, uses a connected service to change something, or creates or changes a channel; the reviewer never changes the work it reviews.
- **The channel supervisor manages channels,** with the Buzz CLI (`buzz channels`). It can create Buzz channels, temporary (the relay archives one once it has had no message for the time set) or permanent, and change a channel's name, description, visibility, lifetime, topic, purpose, members and archive state. Its prompt tells it never to delete or leave a channel. The relay decides what it may do in each channel: it is the owner of the channels it creates; where it is a member or a bot, as in the project's channel, it can only set the topic and purpose and add people. Acting only when you ask is a rule in its prompt; nothing checks who asked, and it listens to anyone in its channel.
- **Who starts whose turn.** The workspace agent's env file names the channel supervisor's public key (`BUZZ_ACP_RESPOND_TO=allowlist`, `BUZZ_ACP_RESPOND_TO_ALLOWLIST`); with no channel supervisor known on this machine, it says `owner-only`. The channel supervisor's rules take no turn for its own team's agents, so a mention starts a turn in one direction only, from the channel supervisor to the workspace agent. `status` and `team.sh check` say whom each agent answers.
- **The harness adds same-owner agents.** In both modes the harness also lets through an agent whose Buzz profile carries a proof from the same owner (`is_owner_or_sibling` in `crates/buzz-acp/src/lib.rs`). So another of your agents, the reviewer included, can also start the workspace agent's turn by mentioning it.
- **What that means.** What anyone writes in the channel reaches the channel supervisor, which has every tool, and through it the workspace agent. Only their prompts keep someone else's message from making them act: the channel supervisor acts only on your signed request, and the workspace agent starts work only on your own accepting message. The harness enforces neither.
- **Before 5.0.0** the channel supervisor and the reviewer ran a restricted runtime, with read-only tools; **before 3.0.0** the jobs were the other way round: the agent in `assistant/` was the discussion partner and the supervisor the workspace supervisor. **Before 4.0.0** the workspace agent's folder was `assistant/` and its options were `--assistant-*`. `upgrade` converts such a team (see [Upgrade a team](#upgrade-a-team)).

### Backends, sign-in and models

- **A backend per agent.** The workspace agent and the channel supervisor each run on Claude or on Codex: `create --backend B`, or `--agent-backend B --supervisor-backend B`. The choice is saved per agent (`agent.conf` and the env file agree) and `status` shows it. `start <name> --backend B` changes it for one run, for all agents or a named one; in a terminal, `start` asks. Starting an agent that already runs on another backend stops with a message: stop it first. `upgrade` changes the saved choice.
- **Subscription sign-in only.** Each agent signs in through your own subscription: Claude through `claude auth login` (your Claude subscription, not Console) and Codex through `codex login` (Sign in with ChatGPT), both run by you in your own terminal. The env files say `BUZZ_SIGN_IN=subscription`, and the launcher then removes every API key, token, endpoint and provider variable Claude Code or Codex documents, refuses an env file that sets one, refuses a Claude settings file that adds one (or an `apiKeyHelper`) and a Codex configuration with another provider, and asks the CLI the agent will run how it is signed in: Claude must say `claude.ai`, Codex `Logged in using ChatGPT`. `preflight` does the same checks per role.
- **A model per agent.** `create --agent-model ID --supervisor-model ID` (or `--model ID` for both). Each agent keeps one model per backend (`model_claude=` and `model_codex=` in `agent.conf`), so a backend switch picks that backend's model and never sends a Claude model to Codex. `start --model ID` changes it for one run; `upgrade --agent-model ID` changes the saved one. A Claude agent's model is passed to its adapter as `ANTHROPIC_MODEL`, which wins over a `model` in your Claude settings.
- **A model and an effort for the workspace agent's workers.** The workspace agent starts worker subagents for bounded work. Their model and reasoning effort are the agent's unless you choose others: `create` or `upgrade` with `--worker-model NAME` and `--worker-effort LEVEL` save them for the workspace agent's backend in that run (`worker_model_claude=`, `worker_effort_claude=`, `worker_model_codex=`, `worker_effort_codex=` in its `agent.conf`; `default` clears one), and `start --worker-model NAME --worker-effort LEVEL` sets them for one run. `status` shows them. The channel supervisor and the reviewer have no workers.
  - **How they are applied:** at each start they are named in the agent's system prompt for that run, `prompt.run.md` in its folder: its `prompt.md` followed by a section, "Your workers for this run", that asks it to start each worker on that model and at that level. With neither chosen, the agent gets `prompt.md`, and the file of an earlier run is removed. `prompt.md` itself is never changed by a start. Nothing is written into the project folder and nothing is exported for them; values your shell exports for `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` and `CLAUDE_CODE_SUBAGENT_EFFORT` are removed, so that none overrides the prompt. It is an instruction the agent is trusted to follow, on Claude and on Codex alike; nothing enforces it.
  - **Which models:** on Claude, `opus`, `sonnet`, `haiku` or `fable`: the subagent tool takes a model only as one of these names when the agent starts a worker, and anything else is refused. On Codex, a model the retrieved list offers (each model once; `model[level]` gives their level too).
  - **The Claude effort rule.** Claude applies the level a session runs at, `CLAUDE_CODE_EFFORT_LEVEL` (the agent's own), to its workers whatever level the agent names, so a level for the workers works only while the agent has none of its own. A start then does not ask for one and says why; `--worker-effort` beside a level of the agent's own is refused (start it with `--effort default`); `create` and `upgrade` refuse to save both. The section then names no level.
  - Measured with the installed Claude adapter (`test-workspace-settings.py`): a model and an effort named on the subagent call reach the worker's requests, and `CLAUDE_CODE_EFFORT_LEVEL` wins over the effort. On Codex, passing a model and an effort when it starts a worker was read in Codex's source and documentation, and not run.
- **The model list.** `agent-team.sh models --backend B --role R` opens one session with the stock adapter and lists the models it offers, without a model turn, in at most 30 seconds. The list is kept under `~/.buzz-agents/models/` and the model checks use it; without a list, the documented values apply (Claude Code's aliases and full model names; for Codex, the bundled catalog of the Codex CLI the agents on Codex run). A model outside them is refused. A list kept from the restricted runtime of a version before 5.0.0 is not used. On Codex the list, the menu and the catalog come from the Codex CLI the agents on Codex run (see the next point).
- **Cost.** Every running agent uses your subscription allowance. The channel supervisor takes a model turn on every ordinary message in every channel it is a member of, even when it stays silent, so a lower-cost model or a lower reasoning effort suits it, and each channel you add it to adds to that.
- **Codex needs:** `@agentclientprotocol/codex-acp@1.13.1` under your user npm prefix, which every agent on Codex runs.
- **A newer Codex CLI for the newest models.** The stock adapter runs the Codex CLI it bundles, unless `CODEX_PATH` names another program. Adapter 1.13.1 bundles Codex 0.156.1, which lists `gpt-6.2-astra` but cannot run it with a ChatGPT sign-in: every turn on it ends with HTTP 400, while the start check passes, `team.sh status` says running and the harness log records nothing. With Codex 0.171.0 the model works. So when `~/.local/share/buzz-agent-team/node_modules/.bin/codex` is there and your shell has no `CODEX_PATH` of its own, `team.sh` starts each agent on Codex with `CODEX_PATH` set to it, and so does `agent-team.sh start`; the model lists and menus of `team.sh`, `agent-team.sh models`, `create`, `upgrade` and `start` come from it too. A `CODEX_PATH` your shell exports is left as it is and wins. `AGENT_TEAM_CODEX_CLI` names another file (a full path), and `none` means the adapter's own. Install it in your own terminal:

  ```sh
  npm install --prefix "$HOME/.local/share/buzz-agent-team" --save-exact @openai/codex@0.171.0
  ```

  That folder is where versions before 5.0.0 installed the engine of the restricted runtime, and on a machine that ran them this Codex may be there already. Keep the folder: 5.0.0 said you may delete it, which was wrong.
- **Why the adapter stays 1.13.1.** Adapter 2.10.0 bundles Codex 0.171.0 and passes the two live checks of `test-codex-adapter.py`, but the harness cannot talk to it: `buzz-acp models --agent-command <that adapter> --agent-args ""` fails with `Agent reported error (code -32602): Invalid params`. The launcher refuses any adapter but 1.13.1 for this reason. Adapter 1.13.1 with Codex 0.171.0 passes both live checks, `buzz-acp models` lists `gpt-6.2-astra` with every effort level, and a real request on that model is answered (measured on 2026-11-24).

### The live view and conversations at a time

- **The live view.** Buzz Desktop shows you what each agent does, and you can cancel a turn or switch its model from there. The harness publishes the agent's activity as frames encrypted to you, and takes those controls, and a third one that publishes project announcements, from you only. It finds your public key in the agent's stored proof. It is the team's choice, for every agent: on unless you turn it off. `create` and `upgrade` take `--observer` and `--no-observer`; `team.conf` saves it as `observer=yes` or `observer=no`, and a team without the line has it on. Each env file says `BUZZ_ACP_RELAY_OBSERVER=true` (or `false`). Buzz Desktop switches it on for the agents it creates; whether it shows the live view for an agent it did not create was not tested.
- **Conversations at a time.** The harness runs as many adapter processes as `BUZZ_ACP_AGENTS` says (1 to 32). With one, a turn waits until the turn before it ends, also when the two are in different conversations; with more, turns for different conversations run at the same time. The channel supervisor runs 3: its env file says `BUZZ_ACP_AGENTS=3`, and its `agent.conf` saves `parallel=3`. `create` and `upgrade` take `--supervisor-parallel N`, from 1 to 8. Buzz Desktop uses 10.
- **The workspace agent and the reviewer run one**, with no option: the workspace agent must not run two jobs on the same files at once, and the reviewer is only mentioned now and then.
- **An agent is still one process.** The launcher becomes the harness, which starts its adapter processes and stops them when it stops; `agent.pid`, `stop` and `status` follow that one process.
- **Shown.** `team.sh check` and `status` print one `live view` line per agent, read from `team.conf`: on, or off with the option that changes it. For the channel supervisor they print `3 conversations at a time: three adapter processes`, and so does the line that says it started.
- **Only read.** Both are harness settings, read in its source (`crates/buzz-acp/src/config.rs`, `lib.rs`); that the launcher passes both lines of the env file to the harness was read in `run-buzz-acp.sh`.

### What each tool asks you to approve

- **Claude Code:** each run of the script is a shell command, which Claude Code asks you to approve in its default mode. With its Bash sandbox on, you also add `~/.buzz-agents` as a working folder (`/add-dir`) and allow the network for `models` and `finish`. Sources: https://code.claude.com/docs/en/permissions and https://code.claude.com/docs/en/sandboxing.
- **Codex:** in its default `workspace-write` sandbox, Codex asks before a command writes outside the workspace (`settings`, `create`, `proof`, `upgrade`, `models` and the team command `team.sh` write under `~/.buzz-agents`) or uses the network (`models`, `finish`). Source: https://learn.chatgpt.com/docs/agent-approvals-security.
- **In both tools,** whether agents started from a session keep running after it ends is not documented. Start them in your own terminal.

## The script

```sh
agent-team.sh preflight --backend claude          # what is missing, with one fix line per item
agent-team.sh models --backend claude             # the models your sign-in offers (no model turn)
agent-team.sh create --workspace ~/code/shop --channel <channel uuid> --supervisor-backend codex --agent-model claude-opus-5-5
# Buzz Desktop: Settings > Security > "Authorize external identity": paste each public key, copy the proof.
agent-team.sh proof shop shop                     # the workspace agent, by its folder; paste its proof, then Enter
agent-team.sh proof shop supervisor
agent-team.sh finish shop --dry-run               # prints the community steps; runs nothing
agent-team.sh finish shop                         # check, display names, channel membership
~/.buzz-agents/shop/team.sh check                 # the team's own command: environment and sign-in; starts nothing
~/.buzz-agents/shop/team.sh                       # start: asks which agents, then the provider and model of each
~/.buzz-agents/shop/team.sh status
~/.buzz-agents/shop/team.sh restart               # the agents that run, again as they run: asks nothing
~/.buzz-agents/shop/team.sh stop
```

## The team's own command

Every team folder holds `team.sh`, written by `create` and refreshed by `upgrade`. It is the command you start a team with. It names no skill and finds everything from its own location, so a team folder runs without the skill and can be moved.

```sh
cd ~/code/shop                                    # the agents work in the folder you run it from
T=~/.buzz-agents/shop/team.sh
$T check                                          # is everything a start needs in place?
$T                                                # in a terminal: which agents, then provider and model of each
$T start supervisor --backend codex               # the same by option, for this run
$T start --supervisor-model sonnet --yes          # --yes asks nothing: saved choices for the rest
$T start --supervisor-effort low --agent-effort xhigh   # a reasoning effort per agent, for this run
$T start shop --worker-model sonnet --worker-effort low   # the workspace agent's workers, for this run
$T start shop                                     # the workspace agent only, by its folder (or: agent)
$T start shop --browser                           # give the agents a browser (--no-browser takes it away)
$T start --workspace ~/code/other                 # another project folder for this run
$T status
$T restart                                        # the agents that run, again as they run: asks nothing
$T restart --all                                  # every agent with a run on record, the stopped ones too
$T stop
$T version                                        # the version of the skill that wrote this folder's files
```

### One agent at a time

Every agent folder holds `start.sh`, written by `create` and refreshed by `upgrade`. It starts that one agent and no other, through `team.sh`, so the check, the sandbox settings and the launcher are the same. In a terminal it asks that agent's provider, model and reasoning effort, and for the workspace agent the model and effort of its workers, as the team command does; Enter keeps the saved one.

```sh
cd ~/code/shop                                    # the project folder, as for the team command
~/.buzz-agents/shop/shop/start.sh                 # the workspace agent only
~/.buzz-agents/shop/supervisor/start.sh           # the channel supervisor only
~/.buzz-agents/shop/shop/start.sh --yes           # no questions: its saved provider, model and effort
~/.buzz-agents/shop/shop/start.sh --model claude-opus-5-5   # this model, for this run
~/.buzz-agents/shop-reviewer/reviewer/start.sh    # a reviewer is a team of its own
```

- **Options, for one run:** `--yes` (ask nothing), `--model ID`, `--backend claude|codex`, `--effort LEVEL`, `--worker-model NAME` and `--worker-effort LEVEL` (the workspace agent's workers; `default` means none), `--browser` and `--no-browser` (the browser of the project folder), `--workspace DIR`, `--no-wall` (do not put the settings of its backend into the project folder), `--check` (check this agent, start nothing) and `--verbose`. An option that answers a question skips that question. An agent name, `--all` or another agent's option is refused: the command starts its own agent only. Without a terminal it asks nothing.
- **Stop and status** stay with the team command: `team.sh stop supervisor`, `team.sh status`. Status prints whom each agent answers and its start command.
- **Each team is started on its own.** Starting the agents of `shop` does not start `shop-reviewer`, and the reverse.

### Restart: the same run again

A restart starts an agent again as its last run was. It asks nothing and changes no choice, so it is the quick way to bring an agent back after a change to its tools, a stuck turn or an upgrade of the team folder.

```sh
~/.buzz-agents/shop/shop/restart.sh               # the workspace agent, again as its last run was
~/.buzz-agents/shop/supervisor/restart.sh         # the channel supervisor
~/.buzz-agents/shop/team.sh restart               # every agent of the team that runs now
~/.buzz-agents/shop/team.sh restart supervisor    # one agent, running or stopped
~/.buzz-agents/shop/team.sh restart --all         # every agent with a run on record, the stopped ones included
```

- **What it repeats:** the provider, the model, the reasoning effort, the project folder and, for the workspace agent, the model and the reasoning effort of its workers. They are those of the agent's last run, whatever is saved in `agent.conf` and whatever folder you run the command from. So it needs no `cd`.
- **How it works:** it hands the run on record to the start as the options that would give that run, so the same check applies. An agent that runs is stopped first, because the launcher refuses to check an agent that runs; then come the check and the start. The agent is down for those few seconds.
- **The record:** `agent.pid` in the agent folder while the agent runs, and after it ended by itself. A stop keeps that file as `agent.last`, and a start removes it. So `restart.sh` and `team.sh restart <agent>` also start a stopped agent again as it last ran, also after an upgrade of the team folder, which carries the file over: `team.sh stop`, `agent-team.sh upgrade shop`, `team.sh restart --all`.
- **Which agents:** without a name, `team.sh restart` takes the agents that run and those that ended by themselves, and leaves a stopped one stopped. A name or `--all` takes stopped agents too.
- **No option changes a choice.** `--force` ends an agent that does not stop in time, as for `stop`, and `--verbose` prints the launcher's own check. Anything else is refused: to change a provider, a model, an effort or the folder, stop the agent and start it with `start.sh` and the option.
- **When it cannot finish:** a recorded choice that is refused now (a model the provider no longer offers, a project folder that is gone) stops it before anything is stopped. When the check fails after the stop, or an agent ends right after starting, the other agents of the restart are still started, each agent keeps the record of its last run, and the message names the command that starts it again.
- **No record:** an agent that was never started, or that was last stopped by the `team.sh` of a version before 5.2.0, has none. Start it with `start.sh`. To upgrade a running team made before 5.2.0 without choosing anything again, stop it with this version's `agent-team.sh stop <team>`, which keeps each record, then upgrade and run `team.sh restart --all`.
- **Two things follow the project folder as it is now,** not the last run. An agent gets the browser when the file of its provider names it now; a restart writes nothing for it and says so when that differs from the last run. And the settings of its provider are put into the project folder again, unless the last run had none (`--no-wall`).
- **Not measured:** a restart of a real agent. The offline suite drives it with stand-ins for the launcher, the harness and the adapters; the stand-in launcher refuses to check a running agent, as the real one does.

- **The project folder** the agents work in is the folder the command is run from, or the one `--workspace DIR` names. It is never the team folder, a folder inside it or a folder around it, because the secret keys are there and an agent reads its project folder: such a `--workspace` is refused, and run from such a folder the command uses the project folder saved in `team.conf` (`team.sh workspace DIR` changes it). A team works in one project folder at a time: while one agent runs, another starts only in the same folder. The check notes a folder that has no `PROJECT.md`.

- **The check**, which every start runs first:
  - `run-buzz-acp.sh`, `buzz-acp` and `buzz` are on `PATH`, and so is each agent's adapter;
  - the project folder exists and is not around the keys;
  - each agent has its key, settings file, prompt and stored proof, and a record in format 5; the check also says whom it answers, whether it has the live view, and for the channel supervisor how many conversations it runs at a time;
  - for an agent on Codex, the Codex CLI its adapter will run (one `codex` line: the program, its version, and whether it comes from `~/.local/share/buzz-agent-team`, your shell's `CODEX_PATH` or the adapter itself). The adapter's own is a note, not a problem, with the line that installs a newer one as its fix;
  - the launcher accepts each agent's settings, with its subscription sign-in.
  Each missing item gets one line with its fix. `--verbose` also prints the launcher's own report.
- **The choices at start:** which agents; for each one its provider (Claude or Codex), its model and its reasoning effort; for the workspace agent then `<Name>: model for its workers on <provider>?` (on Claude the four names; on Codex the agent's own model menu, each model once) and `<Name>: reasoning effort for its workers?`. Enter keeps the saved choice, or the same as the agent when none is saved. Last, once for all the agents it starts, `A browser for the agents in this project folder (headless Chrome, signed in to nothing)? [y/N]` (see [The browser of the project folder](#the-browser-of-the-project-folder)). The check prints one `workers` line saying what the workers get, named in the agent's prompt for this run, or "the same as <Name>", and one `browser` line for each agent. A choice lasts for that run; `agent-team.sh upgrade` changes the saved one. Without a list, a Claude model is checked against the documented names and a Codex model is passed as typed.
- **The model menu shows what the provider offers now.** Before an agent's model menu, the command asks that provider's adapter for its list, with `acp-models.py` in the team folder: one session with the adapter that agent runs, no model turn, your subscription sign-in, at most 30 seconds, one attempt. Credential and endpoint variables are removed first, as the launcher does for an agent.
  - The list is kept where the earlier one was: `models/` in the team folder, or in the folder above it (the lists `agent-team.sh models` writes, shared by the teams beside this one). The menu shows its retrieval time.
  - When it cannot be retrieved (not signed in, no network, no answer in time, no `python3`), the command says why and offers the kept list with its date.
  - A model given by option that the kept list does not offer is looked up the same way before it is refused, so a model newer than the kept list starts.
  - A start that asks nothing (`--yes`, or no terminal) and names no model retrieves nothing. `AGENT_TEAM_MODELS_TIMEOUT` shortens the wait; `AGENT_TEAM_PYTHON=none` never retrieves.
- **`default` is not a Claude model here.** The Claude adapter's list has an entry `default`, but the launcher hands a model to Claude Code as a model name, and Claude Code then refuses every turn ("There's an issue with the selected model (default)"): the agent runs and stays silent. So the menu leaves it out, and `team.sh`, `start.sh`, `create`, `upgrade` and `settings` refuse it, as a choice and as a saved model. For the runtime default, save no model.
- **What holds each agent to the project folder:**
  - Every agent runs the stock adapter with nothing in front of it, in the same project folder. A rule in its prompt tells it to stay inside the project folder, and the settings of its backend back most of that rule. They are in the project folder, so they hold every agent started there on that backend:

    | | An agent on Claude | An agent on Codex |
    | --- | --- | --- |
    | Where the settings are | `<project folder>/.claude/settings.json`, plain Claude Code settings | the stock adapter sets Codex's workspace-write sandbox on every turn; `<project folder>/.codex/rules/buzz.rules`, the buzz rule |
    | File tools outside the project folder | refused | (Codex has no separate file tools) |
    | A shell command writing outside | refused, except a temporary folder | refused, except temporary folders |
    | A shell command reading outside | refused in user folders; system folders stay readable | allowed: workspace-write does not limit reads |
    | Network in a shell command | no direct network; a plain `buzz` command runs outside the sandbox | none; a plain `buzz` command runs with the network (the buzz rule); another command that needs it asks to run outside the sandbox, and Codex's own reviewer decides |
    | Left to the prompt rule | a command it runs again outside the sandbox; a `buzz` command given a file outside the project folder | what it reads; a command its reviewer lets run outside the sandbox |

    The Claude column was measured with `test-workspace-settings.py`. On Codex the network of a `buzz` command, with and without the buzz rule, was measured with `test-codex-adapter.py --also-buzz-rule`; the rest of the Codex column is read from the code of the stock adapter (`@agentclientprotocol/codex-acp` 1.13.1) and Codex's documentation.

  - **The Claude settings**, kept in place by `workspace-settings.py` (`workspace-settings.py show` prints them; `show codex` prints the buzz rule):

    ```json
    {
      "permissions": {
        "blockReadsOutsideWorkingDirectories": true,
        "blockWritesOutsideWorkingDirectories": true
      },
      "sandbox": {
        "enabled": true,
        "autoAllowBashIfSandboxed": true,
        "excludedCommands": ["buzz *"]
      }
    }
    ```

  - **When they are written:** by `create`, before anything else in the project folder; by `team.sh` before a start, so a project folder the team is new to gets them first; and by `upgrade`, each when an agent of the team runs on that backend. An existing `.claude/settings.json` keeps everything else it holds, and the earlier file is kept beside it as `settings.json.bak-<UTC time>`. A file that is not valid JSON, or a `.claude` that is a symbolic link, stops the start with the reason and is left alone. `team.sh check` only reports.
  - **They apply to every Claude Code session started in that folder, your own included.** To run an agent in a folder without them, start it with `team.sh start --no-wall`: nothing is written, and only the prompt rule holds it. Settings already in a folder stay and apply until you edit the file.
  - **What widens them:** folders your own Claude settings add as working folders (`permissions.additionalDirectories` in `~/.claude/settings.json`) count as inside the project folder.
  - **What they can break:** a tool installed under your home folder does not run inside the Claude sandbox. The workspace agent's prompt lets it run such a tool outside the sandbox.
  - **The Codex sandbox and the buzz rule.** The stock Codex adapter sends its mode's sandbox with every turn, so `sandbox_mode` in a `.codex/config.toml` would not change what an agent's turns run under; `team.sh` pins the adapter's workspace-write mode (`INITIAL_AGENT_MODE=agent`) whatever your shell exports. In that sandbox a command has no network, and an agent posts to Buzz with the `buzz` command. So `workspace-settings.py` keeps one line in `<project folder>/.codex/rules/buzz.rules`, the buzz rule: `prefix_rule(pattern = ["buzz"], decision = "allow")`. With it a plain `buzz` command runs with the network, and Codex's own reviewer is not asked; a line that combines `buzz` with anything else (`;`, `&&`, a pipe, `sh -c`, a variable set in front) stays in the sandbox without the network. Without it, a `buzz` command has no network, and asking to run it outside the sandbox sends it to Codex's own reviewer, which decides. An existing `buzz.rules` keeps what it holds: the line is added at its end, and the earlier file is kept beside it as `buzz.rules.bak-<UTC time>`; a symbolic link (the file, `.codex/` or `.codex/rules/`) or a file that cannot be read as text stops the start and is left alone. `--no-wall` writes no rule, and the check then notes that each `buzz` command goes through Codex's reviewer. The rule applies to every Codex session started in that folder, your own included.
  - `test-workspace-settings.py` drives the installed Claude adapter over ACP as the harness does (bypassPermissions, every permission request allowed), with a local model that tries reads and writes inside and outside the project folder. It asserts what the settings hold and prints what they leave to the prompt rule.
- **Reasoning effort:** how hard the model thinks on each turn; a higher level costs more of your allowance and takes longer.
  - On Claude the levels are `low`, `medium`, `high`, `xhigh` and `max`. The agent gets its level as `CLAUDE_CODE_EFFORT_LEVEL`, which Claude Code takes over your own saved level.
  - On Codex the level is part of the model name, `model[level]`, which the adapter sends as the model and its reasoning effort. The levels on offer are the ones the retrieved list has for that model, and a level needs a model.
  - With none set, Claude Code uses your own saved level for that model, or the model's default, and Codex uses the default of your Codex configuration. A level your shell exports as `CLAUDE_CODE_EFFORT_LEVEL` is then left as it is, and it applies to the workspace agent's workers too; the check says so.
  - Saved per agent and provider in `agent.conf` (`effort_claude=`, `effort_codex=`) by `agent-team.sh create` or `upgrade` with `--effort`, `--agent-effort`, `--supervisor-effort` or `--reviewer-effort`; `default` clears it, or sets none for one run of `team.sh`. Both starts apply it.
- **Moving a team:** stop its agents, copy the whole folder privately (it holds the secret keys), install the commands above on the new machine and sign in there, then go to the project folder and run the team folder's `team.sh check`. The settings files keep the paths they were written with; `team.sh` passes the team folder's current paths and the project folder to the launcher at every start, and the launcher takes those over the file.
- **With the skill's own commands:** `agent-team.sh start`, `stop` and `status` still exist and use the same `agent.pid` and `agent.log`, so both see the same running agents. They read the paths in the settings files, so use `team.sh` for a folder that was moved.

### The browser of the project folder

The agents can have a browser: the Playwright tool server (`@playwright/mcp`), a headless Chrome that starts with a new, empty profile each session, so it is signed in to nothing. It belongs to the project folder, not to one agent: every agent started there reads the folder's tool-server file of its backend, so every agent on that backend has it.

- **Where it is named.** In the project folder's own tool-server file, which the adapter's CLI reads itself: `.mcp.json` (key `mcpServers.playwright`) on Claude, `.codex/config.toml` (table `[mcp_servers.playwright]`) on Codex. Nothing goes through the launcher or the harness. `workspace-browser.py show` prints the entry: command `npx`, arguments `-y @playwright/mcp@0.0.86 --headless --isolated --output-dir .browser-output`.
- **On or off.** An agent has the browser in a run when the file of its provider names a server called `playwright`. `create` or `upgrade` with `--browser` names it for each backend the team's agents are saved on, and `--no-browser` takes it out of both files; without either they leave the project folder as it is. `team.sh start --browser` and `--no-browser` do the same at a start, for the backends of the agents it starts and with any agent; in a terminal the start asks once, and the default is yes only when the file of every started agent's backend names it. Enter, `--yes` and no terminal keep each file as it is and write nothing. An existing file keeps everything else it holds, and the earlier file is kept beside it as `<file>.bak-<UTC time>`. A server called `playwright` that you wrote with other settings is yours: it is left as you wrote it, and `--no-browser` leaves it in the Codex file too (it says so).
- **At a start with it on,** `team.sh` fetches the package once (`npx -y @playwright/mcp@0.0.86 --version`, at most 60 seconds), because a session that starts while npx downloads it gets no browser tools at first. A failure is a note, and the agents start all the same. The check notes a missing Google Chrome. The prompt of each agent that has it gets a section for that run, "Your browser for this run", and its `agent.pid` and `browser` check line say so. When the server called `playwright` is yours ("with your own settings"), the section does not say that the browser is signed in to nothing or where its files go: it says that you set the browser up yourself, that it may be signed in somewhere and may save files in a place of its own, and that the agent does nothing in it that the task does not call for.
- **What it can do.** It opens and operates pages on the web and on `127.0.0.1`. A file it saves without a name goes to `.browser-output/` in the project folder, and a named file is saved relative to the project folder. It refuses a named file outside the project folder, and every `file:` address, inside the project too: to look at a project file as a page, the agent serves the project folder on `127.0.0.1`, with a command run outside the Claude sandbox.
- **On Codex,** a browser action that changes something (a navigation) goes to Codex's own automatic reviewer, which allows or denies it; no permission request reaches the Buzz harness. Screenshots and snapshots are not reviewed.
- **Its limits.** The browser reads the open web, and the sandbox settings do not hold it. Playwright's `--allowed-origins` and `--blocked-origins` are not a security boundary, by Playwright's own help, and the skill sets neither. On Claude the agent's file tool can rewrite `.mcp.json`; a sandboxed shell command cannot. Your own Claude Code session in that folder asks you once to approve the server. `.mcp.json` and `.browser-output/` appear in the project folder; the skill does not touch Git ignore files.
- **Measured** offline with the real adapters and a loopback model (`test-workspace-settings.py --also-browser`, `test-codex-adapter.py --also-browser`); see the [changelog](CHANGELOG.md) for what was measured and what was only read.

## An independent reviewer

A third role, made as a one-agent team of its own, for the same project folder and channel as an existing team or alone:

```sh
agent-team.sh models --backend codex --role reviewer
agent-team.sh create --workspace ~/code/shop --channel <channel uuid> --name shop-reviewer --roles reviewer \
  --reviewer-name "Shop Reviewer" --reviewer-backend codex --reviewer-model <id>
agent-team.sh proof shop-reviewer reviewer        # its one proof
agent-team.sh finish shop-reviewer --dry-run      # then without --dry-run
agent-team.sh upgrade shop --dry-run              # refreshes the first team's channel supervisor rules; then without --dry-run
cd ~/code/shop && ~/.buzz-agents/shop-reviewer/team.sh
```

| | Workspace agent | Channel supervisor | Reviewer |
| --- | --- | --- | --- |
| Folder | `<team>/<team>/` (or `<team>/agent/`) | `<team>/supervisor/` | `<team>/reviewer/` |
| Takes a turn | when the owner or its channel supervisor mentions it | on every ordinary message in every channel it is a member of, and when mentioned; never for its own team's agents, and for another local agent only when mentioned | when anyone mentions it |
| Tools | everything the adapter offers, worker subagents | everything the adapter offers | everything the adapter offers |
| What its prompt allows | work you accepted, in a bounded run | for anyone: reading, looking up, a quick command that changes nothing; for you, on your signed request: a small change, a channel | reading, checks such as the tests; it never changes the work it reviews |
| Prompt | `templates/agent.md` | `templates/supervisor.md` | `templates/reviewer.md` |

- The reviewer runs the stock adapter of its backend, as the other agents do, on Claude or on Codex. Only its prompt keeps it from changing files: it has every tool.
- It answers anyone who mentions it, other agents included. Its prompt tells it to mention another agent only when asked, and the channel supervisor's refreshed rules take no turn for its ordinary messages; nothing else bounds an exchange of mentions between agents, so watch the first runs.
- It can run the project's tests and other checks, and look at a picture or a page.

### Upgrade a team

A team in an earlier team folder format is refused by `create` and `start`, `preflight NAME` marks it as a problem, and `team.sh` (of this version) does not start it: format 1 (made before 20 November), format 2 (made by 1.0.0 or 2.0.0), format 3 (made by 3.0.0) and format 4 (made by 4.0.0 to 4.3.0). `status` lists it and says what to do. Stop its agents, then:

```sh
agent-team.sh upgrade shop --dry-run      # the plan: what is replaced, added, removed, not carried
agent-team.sh upgrade shop --agent-model claude-opus-5-5 --supervisor-model sonnet
agent-team.sh upgrade shop                # a second run says "up to date"
~/.buzz-agents/shop/team.sh restart --all # then: every agent again as it last ran (stopped by 5.2.0 or later)
```

- **A team made by 5.0.0** (format 5, without the 5.1.0 lines) gets the live view and the channel supervisor's conversations at a time. The env files are rewritten with the new lines, keeping everything else as an upgrade keeps it; `team.conf` gets `observer=` (written first, so that the next run finishes an upgrade cut short with the same choice), the channel supervisor's `agent.conf` gets `parallel=`, the team's files are replaced, and `VERSION` is written last. The plan names, per agent, `live view: off -> on (BUZZ_ACP_RELAY_OBSERVER=true)`, and for the channel supervisor `conversations at a time: 1 -> 3 (BUZZ_ACP_AGENTS=3: three adapter processes)`. `--no-observer` and `--supervisor-parallel N` choose otherwise in the same run. A team in an earlier format goes straight to 5.1.0.
- **From format 4 the channel supervisor and the reviewer leave the restricted runtime.** Each one's `runtime/` is moved aside, whole, as `runtime.bak-<UTC time>` in its folder, as 2.0.0 kept a team's `wall/`. Its env file names the stock adapter, in bypass-permissions; whom it answers, its subscription rules, keys, proofs, names, backends, models and efforts stay. The three prompts are rewritten (each earlier file kept), the team's files replaced, the buzz rule written when an agent is saved on Codex, `team.conf` gets `format=5`, and `VERSION` is written last. The plan says, per agent, that it gets every tool from now on and that what it may do is a rule in its prompt, which nothing enforces; it names a saved model the stock adapter does not offer, which is kept and used as saved. A reviewer that is a team of its own upgrades the same way. Keep `~/.local/share/buzz-agent-team`, the folder of the restricted runtime: its Codex CLI is the one agents on Codex need for the newest models (see [Backends, sign-in and models](#backends-sign-in-and-models)).
- **From format 3 the workspace agent's folder moves.** `assistant/` becomes `<team>/` (or `agent/`, as above), by one rename; then its env file's paths, `agent.conf` and `start.sh` are rewritten there, and `team.conf` gets `format=4` and `agent_folder=`. Keys, proofs, display names, backends, models, efforts, the allowlist and the rules stay as they are. The plan says which folder it becomes and what the agent's start command is from now on. An upgrade cut short after the move, or between the two renames of a folder, is finished by the next run. A team in format 2 or 1 gets the same move in the same run.
- **From format 2 the two jobs swap as well.** The agent in `assistant/` becomes the workspace agent and the supervisor the channel supervisor (see [The two jobs](#the-two-jobs)). Each agent keeps its folder, `identity.key`, stored proof, display name, saved backend, saved models and saved effort, and gets the other job's files: its env file, its prompt, and `subscriptions.toml` added (the supervisor) or removed (the workspace agent).
- **The plan says, per agent,** the job it had, the job it has from now on, and the saved model it keeps. That model was chosen for the earlier job: the cheaper one usually sat on the agent that took a turn on every message, which now has the tools. `--agent-model` and `--supervisor-model` (and the backend and effort options) set new ones in the same run.
- **Buzz profiles:** each agent's description in `agent.conf` follows its new job; Buzz shows the earlier one until `finish` runs again.
- **A team with a supervisor only** (made with `--roles supervisor`, which 3.0.0 no longer makes) keeps it: it becomes a channel supervisor, and the plan says so. For a workspace agent in a channel that has a channel supervisor, make a team with `--roles agent`.

It writes subscription-only env files for the chosen backends (`--backend`, `--agent-backend`, `--supervisor-backend`), the current prompts and the channel supervisor's subscription rules, refreshes the team's own files, and sets the team folder's `VERSION` to the skill's version. `identity.key`, the stored proof and the workspace's `PROJECT.md` stay byte-identical. Every replaced or removed file is kept beside itself as `<file>.bak-<UTC time>`. It refuses while an agent runs. Each agent folder is rebuilt beside itself and swapped in; an interrupted run is finished or undone by the next one. The same command changes the saved backend or model of a current team.

### Settings

`settings` keeps public defaults in `~/.buzz-agents/settings.conf` (mode 600): the paths of the key generator and the launcher, and the community address, your public key and a default Claude model. `create` uses them when no option gives a value, and options always win. A gateway address is no longer stored. `settings` refuses anything that is or holds a secret.

### Agent folders

For each agent, `create` makes a folder (mode 700) in `~/.buzz-agents/<workspace name>/`: the workspace agent's is named after the workspace (`agent_folder=` in `team.conf`; `agent/` when that name is taken, see [The two jobs](#the-two-jobs)), the channel supervisor's is `supervisor/`, a reviewer's `reviewer/`. Each holds:

| File | Holds |
| --- | --- |
| `identity.key` | The agent's new secret key (mode 600). Nothing else holds it. |
| `.env.buzz-acp.local` | Settings for `run-buzz-acp.sh` (mode 600): community, your public key, key file, proof, `BUZZ_SIGN_IN=subscription`, one model per backend, workspace, prompt file, the stock adapter, `BUZZ_ACP_PERMISSION_MODE=bypass-permissions`, routing (for the workspace agent: whom it answers, by public key; for the channel supervisor: anyone, with its subscription rules; for the reviewer: anyone who mentions it), the live view (`BUZZ_ACP_RELAY_OBSERVER`) and the conversations at a time (`BUZZ_ACP_AGENTS`). No secret key, API key or gateway. |
| `prompt.md` | The core role instructions used by the harness. |
| `prompt.run.md` | For a start that names the workspace agent's workers' model or effort, or in which the agent has the browser: `prompt.md` followed by the sections that apply (mode 600). The launcher gets it instead of `prompt.md` for that run; a start with none of them removes it. |
| `agent.conf` | Public facts: role (`agent`, `supervisor` or `reviewer`), display name, public key, backend, one model per backend, and the reasoning effort and, for the workspace agent, its workers' model and effort per backend when they are set; for the channel supervisor, the conversations it runs at a time (`parallel=`). |
| `subscriptions.toml` | The channel supervisor only: the rules that decide which messages start a turn. |
| `agent.log`, `agent.pid` | Written when the agent starts; `agent.pid` also names the backend, the model, the project folder and the effort the agent runs with, since 4.2.0 its workers' model and effort, and since 4.3.0 whether it has the browser, since 5.0.0 for every agent (a pid file written by 4.1.0 or 4.2.0 is still read). |
| `agent.last` | Since 5.2.0: the record of the agent's last run after it was stopped, the lines of `agent.pid`, which a stop keeps under this name. `restart` reads it; a start removes it. |
| `start.sh` | That agent's own start command (mode 700), a copy of `templates/agent-start.sh`. It holds no setting and no secret, and finds its agent from the name of its folder. |
| `restart.sh` | Since 5.2.0: that agent's own restart command (mode 700), a copy of `templates/agent-restart.sh`. It starts the agent again as its last run was, through `team.sh restart`. |

Beside the agent folders, the team folder holds `team.conf` (the project folder, channel, community, owner, the workspace agent's folder and the live view, `observer=`), `team.sh` (the team's own command), `acp-models.py` (asks an adapter for its model list, for the model menu), `workspace-settings.py` (puts the sandbox settings and the buzz rule into the project folder), `workspace-browser.py` (names or takes out the browser in the project folder), `VERSION` (the version of the skill that created or last upgraded the folder, mode 600) and, when you gave one, `brief.md`.

The channel supervisor's rules take no turn for its own team's agents, and none for any other local agent unless it mentions it (an author filter, written from the public keys of every agent under `~/.buzz-agents`). Since 5.3.0 the rule without a mention holds in every channel the channel supervisor is a member of, so the filter names the agents of every local team, whatever channel each team was made for. When a team gets new agents, `create` names every other channel supervisor to refresh with `upgrade`; until then that one takes turns for the new agents' ordinary messages in a channel they share. An agent that is not local, such as one Buzz Desktop runs, is not in the filter: its ordinary messages start the channel supervisor's turn like a person's. Two channel supervisors in one channel both answer a person's message there.

### Proofs

- **What `proof` accepts:** the proof as Buzz Desktop gives it, the unquoted form `[auth,<owner>,,<signature>]`, or a `BUZZ_AUTH_TAG=` line.
- **What it checks:** the format, the owner, the time limits and, with `python3`, the signature against the agent's key. `--force` only replaces a different proof already stored; `--no-signature-check` skips only the signature check, with a warning.
- **If a proof you just copied is refused with `signature: FAILED`:** check that you pasted this agent's public key into Desktop and copy the proof again; if the same proof is still refused, store it with `--no-signature-check`; after `start`, if `agent.log` shows `BUZZ_AUTH_TAG verification failed`, copy a new proof and store it with `--force`.

### Channel, start and stop

- **`finish`:** `--channel-step add` (default: through your Buzz desktop pairing, made once with `buzz --relay <community> auth desktop pair`), `join` or `skip`; `--role bot` (default) or `member`.
- **`start`:** checks every agent's launcher configuration and sign-in first, then runs each agent in the background, from its folder, with `CLAUDE_AGENT_ACP_PROTOCOL=v1`. It refuses an agent without a proof and never starts a second copy.
- **`stop`:** sends SIGTERM only to processes `start` started, waits up to 30 seconds, and reports failure if one is still running; `stop --force` then sends SIGKILL. It keeps the record of the run as `agent.last`, for a restart.

Needed on `PATH`: `buzz`, `buzz-acp`, and `claude-agent-acp` or `codex-acp`; Python 3 for the team's helpers.

## What stays manual

- Signing in to Claude or ChatGPT in your own terminal.
- Authorizing each key in Buzz Desktop and pasting the proof back.
- Pairing the CLI with Buzz Desktop once, or adding the agents to the channel in Buzz Desktop.
- Checking that no other member of the channel already uses the new display names.
- Starting the agents in your own terminal.
- Reviewing the prompts and selecting the project’s tracker.

## Test

```sh
AGENT_TEAM_TEST_DIR=/tmp/agent-team-test \
AGENT_TEAM_KEYGEN=/path/to/buzz/target/debug/buzz-admin \
AGENT_TEAM_REAL_BUZZ=/path/to/buzz/target/release/buzz \
  /bin/bash test-agent-team.sh
```

`test-team-sh.sh` covers the team's own command with the same three variables (the real launcher is optional and runs with `--check` only): what `create` and `upgrade` install, the version a team folder records (a new team, a team made before versions, another version of the skill, a skill folder without a valid one), the check, the questions, the options, start, stop and status, each agent's own `start.sh`, restart (the team's and each agent's own `restart.sh`: a running agent, a stopped one, across an upgrade, and each way it can fail), the workspace agent's workers (the questions, the options, the prompt of a run and its exact section, the four Claude names, the Claude effort rule, what create and upgrade save, a 4.1.0 pid file), the model list retrieved at start (a list, a sign-in error, an adapter that does not answer, no credential passed on), the refusal of `default` as a Claude model, what holds each agent (the env of each role, the sandbox settings, the buzz rule at a start, with two providers, with `--no-wall`, and each case of `workspace-settings.py codex`), the browser of the project folder (each case of `workspace-browser.py`; the options for any agent, the one question, both providers' files in one start, the check lines, the section of each run, the pid file, the fetch with a failing or missing `npx`, the Chrome note), and a team folder copied to another path. `test-agent-team.sh` also covers the prompts (the "Your workspace" section pinned by hash in all three), the env of each role, and the upgrade of every earlier format, format 4 included: the runtime moved aside, the env files, the prompts, the format, `VERSION` last, a second run, the interrupted cases and the plan's wording. Both suites also cover the live view and the conversations at a time (the env lines of each role with and without each option, what `create` and `upgrade` save, the refusals, the check, status and start lines), the upgrade of a team made by 5.0.0 (its dry run, a second run, `VERSION` last), and the Codex CLI of an agent on Codex (`CODEX_PATH` at a start or not, the `codex` line in each of its three cases, the model list retrieved with that Codex, the preflight line).

It needs `python3` on `PATH`. `python3 test-workspace-settings.py` runs two sessions of an agent on the stock Claude adapter (the workspace agent) under the sandbox settings with the installed Claude ACP adapter and a loopback model (`--also-without` adds one without the settings, which must leak; `--verbose` prints every action), then two in which the loopback model starts one worker with the subagent tool, naming a model and an effort on the call, and shows which reach the worker's requests (`--also-without` adds one that names nothing, where the worker runs as the main session). `python3 test-codex-adapter.py` runs live checks of the stock Codex adapter, each opt-in, with the Codex CLI it bundles, or with the one `AGENT_TEAM_CODEX_CLI` names (a full path), so that they can be run for adapter 1.13.1 with a newer Codex; each result line names the Codex it drove: `--also-buzz-rule` drives it with a loopback model and a stand-in `buzz`, with the buzz rule exactly as `workspace-settings.py codex` writes it, and asserts that a plain `buzz` command reaches the network, that the five lines that combine `buzz` with something else do not, that Codex's reviewer is not asked, and that without the rule a plain `buzz` command does not reach the network. `--also-browser` on `test-workspace-settings.py` and on `test-codex-adapter.py` runs the browser through the real Claude adapter and the stock Codex adapter, with the entry as `workspace-browser.py` writes it: the tools are offered, a loopback page opens, an unnamed screenshot lands in `.browser-output/`, and a named file outside the project folder and a `file:` address are refused. They need `npx` and Google Chrome, and use the network only when npx's cache lacks the package.

- **What they use:** throwaway keys, stand-ins for `buzz`, the harness and the adapters' sign-in, a loopback model endpoint. `HOME` and the agents' root point into the test folder.
- **What they never do:** sign in, read a credential, contact a community or a real model. The two `--also-browser` checks use the npm cache of the user running them (`npm_config_cache`, else `~/.npm`), and npx fetches `@playwright/mcp@0.0.86` into it once when it is not there; the offline suites use a stand-in for `npx`.
