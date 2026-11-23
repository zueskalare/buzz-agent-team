# Buzz agent team setup

One skill, for Claude Code and for Codex, that sets up a set of Buzz agents for one workspace and one channel in chat. You install it once. Then you ask Claude Code or Codex for a new set of agents, and the skill walks you through every step: it checks what is missing, asks one question at a time, lists the models your sign-in offers, runs the steps, shows the public keys, takes the proofs you copy from Buzz Desktop, and tells you how to start the agents.

- `buzz-agent-team/`: the skill folder, complete on its own. Copying it into a tool's skills folder gives a working skill.
  - `VERSION`: the skill's version, one line (see [Versions](#versions)).
  - `SKILL.md`: the guided flow, for both tools.
  - `scripts/agent-team.sh`: the script that does every step (Bash 3.2 or later, mode 755). `agent-team.sh help` lists every command and option.
  - `scripts/workspace-settings.py`: puts the sandbox settings of the workspace agent on Claude into its project folder, and checks them (see What holds each agent). `create` and `upgrade` also copy it into each team folder, where `team.sh` runs it before a start.
  - `scripts/acp-models.py`: lists the models an ACP adapter offers, without a model turn (used by `agent-team.sh models`; `create` and `upgrade` also copy it into each team folder, where `team.sh` runs it before a model menu).
  - `templates/`: the role prompts. `agent.md` holds the workspace agent's rules and `supervisor.md` the channel supervisor's (see [The two jobs](#the-two-jobs)). `project.md` seeds the shared project record and `subscriptions.toml` configures which messages reach the channel supervisor. `legacy/` holds the pre-20-November prompts; nothing uses them any more.
  - `templates/team.sh`: the team's own command. `create` and `upgrade` copy it into each team folder, where it checks, starts, stops and reports that folder's agents without this skill (see The team's own command).
  - `templates/agent-start.sh`: one agent's own start command. `create` and `upgrade` copy it into each agent folder as `start.sh` (see One agent at a time).
  - `runtime/` contains the restricted Claude and Codex runtimes and their typed Buzz tools, installed into the folder of each channel supervisor and each reviewer.
- `install.sh`: copies the skill folder into Claude Code's and Codex's skills folders.
- `CHANGELOG.md`: what changed in each version.
- `test-agent-team.sh`, `test-team-sh.sh`, `test-workspace-settings.py`, `test-partner-runtime.py`, `test-codex-partner.py`: offline tests (see Test).

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

The launcher on `PATH` is updated the same way, keeping the old one beside it:

```sh
cp -p ~/.local/bin/run-buzz-acp.sh ~/.local/bin/run-buzz-acp.sh.bak-$(date -u +%Y%m%dT%H%M%SZ)
install -m 700 /path/to/buzz/local/buzz-acp/run-buzz-acp.sh ~/.local/bin/run-buzz-acp.sh
cmp /path/to/buzz/local/buzz-acp/run-buzz-acp.sh ~/.local/bin/run-buzz-acp.sh && echo "launcher up to date"
```

## Versions

The skill has one version number, `MAJOR.MINOR.PATCH`. It is the one line of `buzz-agent-team/VERSION`; `SKILL.md` repeats it as `metadata.version`, and `CHANGELOG.md` says what each version changed.

```sh
agent-team.sh version                             # this skill folder's version
agent-team.sh status                              # the same, and the version recorded in each team folder
agent-team.sh status shop                         # one team's recorded version beside this skill's
~/.buzz-agents/shop/team.sh version               # the same from the team folder, without the skill
```

- **Three copies, one number each.** The source here, the installed skill folder and every team folder each hold a `VERSION` file, so you can see which copy is behind. `install.sh` prints the source's version beside the installed one and records it in its marker.
- **A team folder's `VERSION`** is the version of the skill that created the folder or last upgraded it, and so the version its `team.sh`, each `start.sh`, `acp-models.py`, `workspace-settings.py` and the agents' generated files come from. `create` writes it for a new team folder only. `upgrade` replaces it as its last step, so an upgrade that is cut short leaves the earlier version there, and shows the change in its plan as `VERSION: <recorded> -> <this skill's>`; when that is the plan's only line, nothing else in the team differs. A team made before 1.0.0 has none until it is upgraded.
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

- **The workspace agent's folder is named after the team,** exactly as written: for a team called `shop`, `~/.buzz-agents/shop/shop/`, recorded in `team.conf` as `agent_folder=shop`. When the team's name is one a team folder uses for something else (`supervisor`, `reviewer`, `models`, `wall`, `team.sh`, `team.conf`, `acp-models.py`, `workspace-settings.py`, `VERSION`, `brief.md`, ignoring case, or a name starting with a dot), the folder is `agent/`, and `create` says so. `agent` also names the workspace agent on any command line: `team.sh start shop` and `team.sh start agent` are the same.
- **The channel supervisor's folder is `supervisor/`.** A reviewer's own team has `reviewer/`.
- **Menus, the check and `status` name an agent by its display name** (`Shop: provider?`); where a line shows the name to type, it is the folder name (`shop: Shop, the workspace agent`).


- **The workspace agent** (named after the project) is the project's agent in the workspace: a supervisor in subagent mode. It plans the work, dispatches bounded work to worker subagents, reviews their evidence, and keeps `PROJECT.md` and the tracker. It has every tool of its adapter. It takes a turn when you or its channel supervisor mention it. It starts workers or changes files only for a bounded run you accepted, and it checks that the accepting message is signed by you, also when the channel supervisor relays it.
- **The channel supervisor** (`supervisor`, "<Project> Supervisor") takes a turn on every ordinary message in its channel and talks with anyone there. It runs brainstorms to a decision, proposes todos, brings decisions to you, and hands work you accepted to the workspace agent by mentioning it and naming your accepting message. It reads the project folder and cannot edit files or run commands.
- **Who starts whose turn.** The workspace agent's env file names the channel supervisor's public key (`BUZZ_ACP_RESPOND_TO=allowlist`, `BUZZ_ACP_RESPOND_TO_ALLOWLIST`); with no channel supervisor known on this machine, it says `owner-only`. The channel supervisor's rules take no turn for its own team's agents, so a mention starts a turn in one direction only, from the channel supervisor to the workspace agent. `status` and `team.sh check` say whom each agent answers.
- **The harness adds same-owner agents.** In both modes the harness also lets through an agent whose Buzz profile carries a proof from the same owner (`is_owner_or_sibling` in `crates/buzz-acp/src/lib.rs`). So another of your agents, the reviewer included, can also start the workspace agent's turn by mentioning it.
- **What that means.** What anyone writes in the channel can reach the agent that has every tool, through the channel supervisor. Starting work still needs your own accepting message. That is a rule in the workspace agent's prompt; the harness does not enforce it.
- **Before 3.0.0** the jobs were the other way round: the agent in `assistant/` was the discussion partner and the supervisor the workspace supervisor. **Before 4.0.0** the workspace agent's folder was `assistant/` and its options were `--assistant-*`. `upgrade` converts such a team (see [Upgrade a team](#upgrade-a-team)).

### Backends, sign-in and models

- **A backend per agent.** The workspace agent and the channel supervisor each run on Claude or on Codex: `create --backend B`, or `--agent-backend B --supervisor-backend B`. The choice is saved per agent (`agent.conf` and the env file agree) and `status` shows it. `start <name> --backend B` changes it for one run, for all agents or a named one; in a terminal, `start` asks. Starting an agent that already runs on another backend stops with a message: stop it first. `upgrade` changes the saved choice.
- **Subscription sign-in only.** Each agent signs in through your own subscription: Claude through `claude auth login` (your Claude subscription, not Console) and Codex through `codex login` (Sign in with ChatGPT), both run by you in your own terminal. The env files say `BUZZ_SIGN_IN=subscription`, and the launcher then removes every API key, token, endpoint and provider variable Claude Code or Codex documents, refuses an env file that sets one, refuses a Claude settings file that adds one (or an `apiKeyHelper`) and a Codex configuration with another provider, and asks the CLI the agent will run how it is signed in: Claude must say `claude.ai`, Codex `Logged in using ChatGPT`. `preflight` does the same checks per role.
- **A model per agent.** `create --agent-model ID --supervisor-model ID` (or `--model ID` for both). Each agent keeps one model per backend (`model_claude=` and `model_codex=` in `agent.conf`), so a backend switch picks that backend's model and never sends a Claude model to Codex. `start --model ID` changes it for one run; `upgrade --agent-model ID` changes the saved one. A Claude agent's model is passed to its adapter as `ANTHROPIC_MODEL`, which wins over a `model` in your Claude settings.
- **The model list.** `agent-team.sh models --backend B --role R` opens one session with the adapter that role runs and lists the models it offers, without a model turn, in at most 30 seconds. The list is kept under `~/.buzz-agents/models/` and the model checks use it; without a list, the documented values apply (Claude Code's aliases and full model names; for Codex, the bundled catalog of the Codex CLI that role runs: the restricted runtime's private engine for the channel supervisor, or the CLI the stock `codex-acp` bundles for the workspace agent, which is older and offers fewer models). A model outside them is refused.
- **Cost.** Every running agent uses your subscription allowance. The channel supervisor takes a model turn on every ordinary message in its channel, even when it stays silent, so a lower-cost model or a lower reasoning effort suits it.
- **Codex needs:** `@agentclientprotocol/codex-acp@1.13.1` under your user npm prefix, and the restricted runtime's engine: `npm install --prefix "$HOME/.local/share/buzz-agent-team" --save-exact @openai/codex@0.171.0 @modelcontextprotocol/sdk@1.32.2 zod@4.6.7`.

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
$T start shop                                     # the workspace agent only, by its folder (or: agent)
$T start --workspace ~/code/other                 # another project folder for this run
$T status
$T stop
$T version                                        # the version of the skill that wrote this folder's files
```

### One agent at a time

Every agent folder holds `start.sh`, written by `create` and refreshed by `upgrade`. It starts that one agent and no other, through `team.sh`, so the check, the sandbox settings and the launcher are the same. In a terminal it asks that agent's provider, model and reasoning effort, as the team command does; Enter keeps the saved one.

```sh
cd ~/code/shop                                    # the project folder, as for the team command
~/.buzz-agents/shop/shop/start.sh                 # the workspace agent only
~/.buzz-agents/shop/supervisor/start.sh           # the channel supervisor only
~/.buzz-agents/shop/shop/start.sh --yes           # no questions: its saved provider, model and effort
~/.buzz-agents/shop/shop/start.sh --model claude-opus-5-5   # this model, for this run
~/.buzz-agents/shop-reviewer/reviewer/start.sh    # a reviewer is a team of its own
```

- **Options, for one run:** `--yes` (ask nothing), `--model ID`, `--backend claude|codex`, `--effort LEVEL`, `--workspace DIR`, `--no-wall` (the workspace agent on Claude: do not put the sandbox settings into the project folder), `--check` (check this agent, start nothing) and `--verbose`. An option that answers a question skips that question. An agent name, `--all` or another agent's option is refused: the command starts its own agent only. Without a terminal it asks nothing.
- **Stop and status** stay with the team command: `team.sh stop supervisor`, `team.sh status`. Status prints whom each agent answers and its start command.
- **Each team is started on its own.** Starting the agents of `shop` does not start `shop-reviewer`, and the reverse.

- **The project folder** the agents work in is the folder the command is run from, or the one `--workspace DIR` names. It is never the team folder, a folder inside it or a folder around it, because the secret keys are there and an agent reads its project folder: such a `--workspace` is refused, and run from such a folder the command uses the project folder saved in `team.conf` (`team.sh workspace DIR` changes it). A team works in one project folder at a time: while one agent runs, another starts only in the same folder. The check notes a folder that has no `PROJECT.md`.

- **The check**, which every start runs first:
  - `run-buzz-acp.sh`, `buzz-acp` and `buzz` are on `PATH`, and so is each agent's adapter;
  - the project folder exists and is not around the keys;
  - each agent has its key, settings file, prompt and stored proof, and a record in format 3; the check also says whom it answers;
  - the launcher accepts each agent's settings, with its subscription sign-in.
  Each missing item gets one line with its fix. `--verbose` also prints the launcher's own report.
- **The choices at start:** which agents; for each one its provider (Claude or Codex), its model and its reasoning effort. Enter keeps the saved choice. A choice lasts for that run; `agent-team.sh upgrade` changes the saved one. Without a list, a Claude model is checked against the documented names and a Codex model is passed as typed.
- **The model menu shows what the provider offers now.** Before an agent's model menu, the command asks that provider's adapter for its list, with `acp-models.py` in the team folder: one session with the adapter that agent runs, no model turn, your subscription sign-in, at most 30 seconds, one attempt. Credential and endpoint variables are removed first, as the launcher does for an agent.
  - The list is kept where the earlier one was: `models/` in the team folder, or in the folder above it (the lists `agent-team.sh models` writes, shared by the teams beside this one). The menu shows its retrieval time.
  - When it cannot be retrieved (not signed in, no network, no answer in time, no `python3`), the command says why and offers the kept list with its date.
  - A model given by option that the kept list does not offer is looked up the same way before it is refused, so a model newer than the kept list starts.
  - A start that asks nothing (`--yes`, or no terminal) and names no model retrieves nothing. `AGENT_TEAM_MODELS_TIMEOUT` shortens the wait; `AGENT_TEAM_PYTHON=none` never retrieves.
- **`default` is not a Claude model here.** The Claude adapter's list has an entry `default`, but the launcher hands a model to Claude Code as a model name, and Claude Code then refuses every turn ("There's an issue with the selected model (default)"): the agent runs and stays silent. So the menu leaves it out, and `team.sh`, `start.sh`, `create`, `upgrade` and `settings` refuse it, as a choice and as a saved model. For the runtime default, save no model.
- **What holds each agent to the project folder:**
  - The channel supervisor and the reviewer run a restricted runtime: they read only the project folder, and they cannot edit files or run commands.
  - The workspace agent runs the stock adapter with nothing in front of it. A rule in its prompt tells it to stay inside the project folder, and sandbox settings back most of that rule:

    | | Workspace agent on Claude | Workspace agent on Codex |
    | --- | --- | --- |
    | Where the settings are | `<project folder>/.claude/settings.json`, plain Claude Code settings | none written: the stock adapter sets Codex's workspace-write sandbox on every turn, over any Codex config file |
    | File tools outside the project folder | refused | (Codex has no separate file tools) |
    | A shell command writing outside | refused, except a temporary folder | refused, except temporary folders |
    | A shell command reading outside | refused in user folders; system folders stay readable | allowed: workspace-write does not limit reads |
    | Network in a shell command | no direct network; a plain `buzz` command runs outside the sandbox | none; a command that needs it asks to run outside the sandbox, and Codex's own reviewer decides |
    | Left to the prompt rule | a command it runs again outside the sandbox; a `buzz` command given a file outside the project folder | what it reads; a command its reviewer lets run outside the sandbox |

    The Claude column was measured with `test-workspace-settings.py`. The Codex column is read from the code of the stock adapter (`@agentclientprotocol/codex-acp` 1.13.1) and Codex's documentation; no Codex session was run to confirm it.

  - **The Claude settings**, kept in place by `workspace-settings.py` (`workspace-settings.py show` prints them):

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

  - **When they are written:** by `create`, before anything else in the project folder; by `team.sh` before a start, so a project folder the team is new to gets them first; and by `upgrade`. An existing `.claude/settings.json` keeps everything else it holds, and the earlier file is kept beside it as `settings.json.bak-<UTC time>`. A file that is not valid JSON, or a `.claude` that is a symbolic link, stops the start with the reason and is left alone. `team.sh check` only reports.
  - **They apply to every Claude Code session started in that folder, your own included.** To run the workspace agent in a folder without them, start it with `team.sh start --no-wall`: nothing is written, and only the prompt rule holds it. Settings already in a folder stay and apply until you edit the file.
  - **What widens them:** folders your own Claude settings add as working folders (`permissions.additionalDirectories` in `~/.claude/settings.json`) count as inside the project folder.
  - **What they can break:** a tool installed under your home folder does not run inside the Claude sandbox. The workspace agent's prompt lets it run such a tool outside the sandbox.
  - **Why no Codex file:** the stock Codex adapter sends its mode's sandbox with every turn, so `sandbox_mode` in a `.codex/config.toml` would not change what the workspace agent's turns run under. `team.sh` pins the adapter's workspace-write mode (`INITIAL_AGENT_MODE=agent`) whatever your shell exports.
  - `test-workspace-settings.py` drives the installed Claude adapter over ACP as the harness does (bypassPermissions, every permission request allowed), with a local model that tries reads and writes inside and outside the project folder. It asserts what the settings hold and prints what they leave to the prompt rule.
- **Reasoning effort:** how hard the model thinks on each turn; a higher level costs more of your allowance and takes longer.
  - On Claude the levels are `low`, `medium`, `high`, `xhigh` and `max`. The agent gets its level as `CLAUDE_CODE_EFFORT_LEVEL`, which Claude Code takes over your own saved level.
  - On Codex the level is part of the model name, `model[level]`, which the adapter sends as the model and its reasoning effort. The levels on offer are the ones the retrieved list has for that model, and a level needs a model.
  - With none set, Claude Code uses your own saved level for that model, or the model's default, and Codex uses the default of your Codex configuration. A level your shell exports as `CLAUDE_CODE_EFFORT_LEVEL` is then left as it is; the check says so.
  - Saved per agent and provider in `agent.conf` (`effort_claude=`, `effort_codex=`) by `agent-team.sh create` or `upgrade` with `--effort`, `--agent-effort`, `--supervisor-effort` or `--reviewer-effort`; `default` clears it, or sets none for one run of `team.sh`. Both starts apply it.
- **Moving a team:** stop its agents, copy the whole folder privately (it holds the secret keys), install the commands above on the new machine and sign in there, then go to the project folder and run the team folder's `team.sh check`. The settings files keep the paths they were written with; `team.sh` passes the team folder's current paths and the project folder to the launcher at every start, and the launcher takes those over the file.
- **With the skill's own commands:** `agent-team.sh start`, `stop` and `status` still exist and use the same `agent.pid` and `agent.log`, so both see the same running agents. They read the paths in the settings files, so use `team.sh` for a folder that was moved.

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
| Takes a turn | when the owner or its channel supervisor mentions it | on every ordinary message in its channel, and when mentioned; never for its own team's agents | when anyone mentions it |
| Tools | everything the adapter offers, worker subagents | reads the project folder, Buzz tools | reads the project folder, Buzz tools |
| Edits, commands, web | all | none, enforced by its runtime | none, enforced by its runtime |
| Prompt | `templates/agent.md` | `templates/supervisor.md` | `templates/reviewer.md` |

- The reviewer runs the same restricted runtime as the channel supervisor, copied into its own folder, on Claude or on Codex.
- It answers anyone who mentions it, other agents included. Its prompt tells it to mention another agent only when asked, and the channel supervisor's refreshed rules take no turn for its ordinary messages; nothing else bounds an exchange of mentions between agents, so watch the first runs.
- It cannot run tests or other commands. It reviews what it can read.

### Upgrade a team

A team in an earlier team folder format is refused by `create` and `start`, `preflight NAME` marks it as a problem, and `team.sh` (of this version) does not start it: format 1 (made before 20 November), format 2 (made by 1.0.0 or 2.0.0) and format 3 (made by 3.0.0). `status` lists it and says what to do. Stop its agents, then:

```sh
agent-team.sh upgrade shop --dry-run      # the plan: what is replaced, added, removed, not carried
agent-team.sh upgrade shop --agent-model claude-opus-5-5 --supervisor-model sonnet
agent-team.sh upgrade shop                # a second run says "up to date"
```

- **From format 3 the workspace agent's folder moves.** `assistant/` becomes `<team>/` (or `agent/`, as above), by one rename; then its env file's paths, `agent.conf` and `start.sh` are rewritten there, and `team.conf` gets `format=4` and `agent_folder=`. Keys, proofs, display names, backends, models, efforts, the allowlist and the rules stay as they are. The plan says which folder it becomes and what the agent's start command is from now on. An upgrade cut short after the move, or between the two renames of a folder, is finished by the next run. A team in format 2 or 1 gets the same move in the same run.
- **From format 2 the two jobs swap as well.** The agent in `assistant/` becomes the workspace agent and the supervisor the channel supervisor (see [The two jobs](#the-two-jobs)). Each agent keeps its folder, `identity.key`, stored proof, display name, saved backend, saved models and saved effort, and gets the other job's files: its env file, its prompt, and `runtime/` and `subscriptions.toml` added (the supervisor) or removed (the workspace agent).
- **The plan says, per agent,** the job it had, the job it has from now on, and the saved model it keeps. That model was chosen for the earlier job: the cheaper one usually sat on the agent that took a turn on every message, which now has the tools. `--agent-model` and `--supervisor-model` (and the backend and effort options) set new ones in the same run.
- **Buzz profiles:** each agent's description in `agent.conf` follows its new job; Buzz shows the earlier one until `finish` runs again.
- **A team with a supervisor only** (made with `--roles supervisor`, which 3.0.0 no longer makes) keeps it: it becomes a channel supervisor, and the plan says so. For a workspace agent in a channel that has a channel supervisor, make a team with `--roles agent`.

It writes subscription-only env files for the chosen backends (`--backend`, `--agent-backend`, `--supervisor-backend`), the current prompts, the channel supervisor's runtime and its subscription rules, refreshes the team's own files, and sets the team folder's `VERSION` to the skill's version. `identity.key`, the stored proof and the workspace's `PROJECT.md` stay byte-identical. Every replaced or removed file is kept beside itself as `<file>.bak-<UTC time>`. It refuses while an agent runs. Each agent folder is rebuilt beside itself and swapped in; an interrupted run is finished or undone by the next one. The same command changes the saved backend or model of a current team.

### Settings

`settings` keeps public defaults in `~/.buzz-agents/settings.conf` (mode 600): the paths of the key generator and the launcher, and the community address, your public key and a default Claude model. `create` uses them when no option gives a value, and options always win. A gateway address is no longer stored. `settings` refuses anything that is or holds a secret.

### Agent folders

For each agent, `create` makes a folder (mode 700) in `~/.buzz-agents/<workspace name>/`: the workspace agent's is named after the workspace (`agent_folder=` in `team.conf`; `agent/` when that name is taken, see [The two jobs](#the-two-jobs)), the channel supervisor's is `supervisor/`, a reviewer's `reviewer/`. Each holds:

| File | Holds |
| --- | --- |
| `identity.key` | The agent's new secret key (mode 600). Nothing else holds it. |
| `.env.buzz-acp.local` | Settings for `run-buzz-acp.sh` (mode 600): community, your public key, key file, proof, `BUZZ_SIGN_IN=subscription`, one model per backend, workspace, prompt file, routing (for the workspace agent: whom it answers, by public key). No secret key, API key or gateway. |
| `prompt.md` | The core role instructions used by the harness. |
| `agent.conf` | Public facts: role (`agent`, `supervisor` or `reviewer`), display name, public key, backend, one model per backend. |
| `runtime/`, `subscriptions.toml` | The channel supervisor only: its restricted runtimes and the rules that decide which messages start a turn. A reviewer has `runtime/` too. |
| `agent.log`, `agent.pid` | Written when the agent starts; `agent.pid` also names the backend, and with `team.sh` the model, the agent runs on. |
| `start.sh` | That agent's own start command (mode 700), a copy of `templates/agent-start.sh`. It holds no setting and no secret, and finds its agent from the name of its folder. |

Beside the agent folders, the team folder holds `team.conf` (the project folder, channel, community, owner and the workspace agent's folder), `team.sh` (the team's own command), `acp-models.py` (asks an adapter for its model list, for the model menu), `workspace-settings.py` (puts the workspace agent's sandbox settings into the project folder), `VERSION` (the version of the skill that created or last upgraded the folder, mode 600) and, when you gave one, `brief.md`.

The channel supervisor's rules take no turn for its own team's agents, and none for other local agents of its channel unless they mention it (an author filter, written from public keys). When another team joins the same channel, `create` says which earlier channel supervisor to refresh with `upgrade`.

### Proofs

- **What `proof` accepts:** the proof as Buzz Desktop gives it, the unquoted form `[auth,<owner>,,<signature>]`, or a `BUZZ_AUTH_TAG=` line.
- **What it checks:** the format, the owner, the time limits and, with `python3`, the signature against the agent's key. `--force` only replaces a different proof already stored; `--no-signature-check` skips only the signature check, with a warning.
- **If a proof you just copied is refused with `signature: FAILED`:** check that you pasted this agent's public key into Desktop and copy the proof again; if the same proof is still refused, store it with `--no-signature-check`; after `start`, if `agent.log` shows `BUZZ_AUTH_TAG verification failed`, copy a new proof and store it with `--force`.

### Channel, start and stop

- **`finish`:** `--channel-step add` (default: through your Buzz desktop pairing, made once with `buzz --relay <community> auth desktop pair`), `join` or `skip`; `--role bot` (default) or `member`.
- **`start`:** checks every agent's launcher configuration and sign-in first, then runs each agent in the background, from its folder, with `CLAUDE_AGENT_ACP_PROTOCOL=v1`. It refuses an agent without a proof and never starts a second copy.
- **`stop`:** sends SIGTERM only to processes `start` started, waits up to 30 seconds, and reports failure if one is still running; `stop --force` then sends SIGKILL.

Needed on `PATH`: `buzz`, `buzz-acp`, and `claude-agent-acp` or `codex-acp`. A channel supervisor or a reviewer also needs Python 3 and Node.js.

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
AGENT_TEAM_REAL_LAUNCHER=/path/to/buzz/local/buzz-acp/run-buzz-acp.sh \
AGENT_TEAM_REAL_BUZZ=/path/to/buzz/target/release/buzz \
  /bin/bash test-agent-team.sh
```

`test-team-sh.sh` covers the team's own command with the same three variables (the real launcher is optional and runs with `--check` only): what `create` and `upgrade` install, the version a team folder records (a new team, a team made before versions, another version of the skill, a skill folder without a valid one), the check, the questions, the options, start, stop and status, each agent's own `start.sh`, the model list retrieved at start (a list, a sign-in error, an adapter that does not answer, no credential passed on), the refusal of `default` as a Claude model, and a team folder copied to another path.

It needs `python3` and `node` on `PATH`. `python3 test-workspace-settings.py` runs two sessions of an agent on the stock Claude adapter (the workspace agent) under the sandbox settings with the installed Claude ACP adapter and a loopback model (`--also-without` adds one without the settings, which must leak; `--verbose` prints every action). `python3 test-partner-runtime.py` exercises the restricted Claude runtime's tool policy (the channel supervisor's and the reviewer's), its sign-in passthrough and its model with the installed Claude ACP adapter, a loopback model, a simulated Buzz CLI and a disposable home. `python3 test-codex-partner.py` does the same for the restricted Codex runtime with its private engine.

- **What they use:** throwaway keys, stand-ins for `buzz`, the harness and the adapters' sign-in, a loopback model endpoint. `HOME` and the agents' root point into the test folder.
- **What they never do:** sign in, read a credential, contact a community or a real model.
