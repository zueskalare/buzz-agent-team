# Changelog

Versions of the buzz-agent-team skill, newest first. The version is the one line of `buzz-agent-team/VERSION`, and each one is the Git tag `v<version>` of this repository. What the three numbers mean is in the [README](README.md#versions).

## 4.2.0 (2026-11-23)

The workspace agent's workers, the subagents it starts for bounded work, can get a model and a reasoning effort of their own. They are named in the agent's system prompt for that run, on Claude and on Codex alike. The team folder format does not change: a team made by 4.1.0 keeps starting as it is, and its workers get the same as the agent until you choose otherwise.

- **What is asked, and when.** In a terminal, `team.sh` and the workspace agent's `start.sh` ask two more questions for the workspace agent only, after its own reasoning effort: `<Name>: model for its workers on <provider>?` and `<Name>: reasoning effort for its workers?`. Enter keeps the saved choice, or the same as the agent when none is saved. `--yes`, or no terminal, asks nothing and uses the saved ones. The channel supervisor and the reviewer have no workers and are asked nothing.
- **Options.** `--worker-model NAME` and `--worker-effort LEVEL` set them for one run (`default` means none), with `team.sh start` or the workspace agent's `start.sh`; they are refused, in one line, when the workspace agent is not started. `agent-team.sh create` and `upgrade` take the same options and save them for the workspace agent's backend in that run, as `worker_model_claude=`, `worker_effort_claude=`, `worker_model_codex=` and `worker_effort_codex=` in its `agent.conf`; `default` clears a saved one, and `upgrade` carries them. Both `status` commands show the saved ones, and what a running agent's workers were started with.
- **Into the system prompt, for that run.** A start that has a worker model or a worker effort gives the launcher `prompt.run.md` in the agent's folder as its system prompt: its `prompt.md` followed by one section, "Your workers for this run", which asks it to start each worker on that model and at that level, and to use others only when the owner asks for them in the task. With neither chosen, the launcher gets `prompt.md` as before, and the file of an earlier run is removed. `prompt.md` itself is never changed by a start. `agent-team.sh start` does the same with the saved ones.
- **Nothing is written into the project folder and nothing is exported** for the workers. Values your shell exports for `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` and `CLAUDE_CODE_SUBAGENT_EFFORT` are removed for every agent, so that none overrides the prompt.
- **An instruction, not a rule that is enforced.** The agent is trusted to pass the model and the level when it starts a worker, as it is trusted with its other prompt rules. Nothing checks that it does.
- **The four Claude names.** On Claude the subagent tool takes a worker's model only as `opus`, `sonnet`, `haiku` or `fable`, not as a full model name, so the question offers exactly these and anything else is refused, by option, by answer and when saving. On Codex the model is one the retrieved list offers, each once, and `model[level]` gives their level too.
- **The Claude effort rule.** Claude applies the level a session runs at, `CLAUDE_CODE_EFFORT_LEVEL` (the agent's own), to its workers whatever level the agent names for them, so a level for the workers works only while the agent has none of its own for that run. When it has one, the workers' question is not asked and one line says they run at that level and why; `--worker-effort` beside it is refused, saying to start the agent with `--effort default`; `create` and `upgrade` refuse to save both, with the same reason. The section then names no level. When your shell exports `CLAUDE_CODE_EFFORT_LEVEL` and the agent has no level, the check's note now says it applies to the workers too.
- **The prompt.** "Supervise the run" in the workspace agent's prompt says: "When the owner chose a model or a reasoning effort for your workers, a section at the end of these instructions names them." `agent-team.sh upgrade <team>` puts it into an existing team's prompt.
- **Shown.** The check prints one `workers` line for the workspace agent: what its workers get, named in its prompt for this run, or "the same as <Name>". `agent.pid` records the two values on two more lines; a pid file written by 4.1.0 is still read.
- **What was measured and what was read.** On Claude it was measured with the installed Claude adapter (`test-workspace-settings.py`, a loopback model, no worker variable set): a worker started with `model: "haiku"` and `effort: "low"` on the subagent call sent its requests on that model and at that level, while the main session's did not; with `CLAUDE_CODE_EFFORT_LEVEL` set, the worker's requests carried that level instead. On Codex the same section is used; that the agent can pass a model and a reasoning effort when it spawns a worker was read in Codex's source and documentation, and not run.

## 4.1.0 (2026-11-23)

The channel supervisor can create and manage Buzz channels, so a channel can be made for a short-lived purpose or for good. The team folder format does not change: a team made by 4.0.0 keeps starting as it is.

- **What the channel supervisor can do.** Its Buzz tools gain `list_channels`, `get_channel`, `list_channel_members`, `create_channel`, `update_channel`, `set_channel_topic`, `set_channel_purpose`, `add_channel_member`, `remove_channel_member`, `archive_channel` and `unarchive_channel`. A new channel is a stream unless the call says forum, and private unless it says open. `ttl_seconds` (60 seconds to one year) makes it temporary: the relay archives it after that long without a message. `update_channel` changes a channel's name, description, visibility or lifetime, and `permanent: true` makes a temporary channel permanent. Each tool runs `buzz channels …` with a fixed argument list, and a name, description, topic or purpose goes as one `--flag=value` argument.
- **What it cannot do.** There is no tool to delete a channel, to leave one, or to change its join role, auto-join or add policy. `add_channel_member` adds a member, a bot or a guest, never an owner or an admin.
- **The reviewer gets none of them.** `runtime/buzz-tools` reads the agent's role from `agent.conf` in its folder and registers the channel tools only for `role=supervisor`. Another role, or a file that is missing or unreadable, gets none. On Codex, `runtime/codex-acp` now enables them; they exist only where `buzz-tools` registers them. On Claude, `runtime/restricted-claude` already allowed the whole `buzz` server and is unchanged.
- **The relay still decides.** The channel supervisor is the owner of the channels it creates, so it can change them. In a channel where it is a member or a bot, as in the project's channel, the relay lets it set the topic and purpose and add people, and refuses the rest: renaming, the description, visibility and lifetime, archiving and removing members. So the project's channel keeps its settings and members unless the owner raises the channel supervisor's role there. (Read in the relay's source, not tested against a relay.)
- **Acting only for the owner is a prompt rule.** A new section of its prompt, "Channels", tells it to create or change a channel only when the owner asks, in a message signed by the owner; to make a channel private unless the owner says open, and temporary when its purpose is short-lived; to add the owner and the people the owner names; and to post the channel's name in the thread. The tools do not enforce any of it, and the channel supervisor listens to anyone in its channel.
- **An existing team.** `agent-team.sh upgrade <team>` puts the new `runtime/buzz-tools`, `runtime/codex-acp` and prompt into it, keeping each earlier file as `<file>.bak-<time>`. Until then its channel supervisor runs with the 4.0.0 tools and prompt.
- **Tests.** `test-codex-partner.py` runs `runtime/buzz-tools` with a recording stand-in for `buzz`, for a channel supervisor, a reviewer, a folder without `agent.conf`, one whose `agent.conf` cannot be read and one whose first `role=` line is not `supervisor`: the tools each one gets, the exact arguments of every call, and the values each tool refuses. It and `test-partner-runtime.py` also check that a channel supervisor's model sees the channel tools, on Codex and on Claude.

## 4.0.0 (2026-11-23)

The workspace agent is no longer called "assistant". Its folder is named after the team, and its role is called `agent`. A team made by 3.0.0 does not start until it is upgraded (team folder format 4).

What a 3.0.0 user sees change, after `agent-team.sh upgrade <team>`:

- **The folder.** `~/.buzz-agents/shop/assistant/` becomes `~/.buzz-agents/shop/shop/`, named after the team as written. `team.conf` records it as `agent_folder=shop`. When the team's name is one a team folder uses for something else (`supervisor`, `reviewer`, `models`, `wall`, `team.sh`, `team.conf`, `acp-models.py`, `workspace-settings.py`, `VERSION`, `brief.md`, ignoring case, or a name starting with a dot), the folder is `agent/` instead, and `create` says so.
- **The start command.** `~/.buzz-agents/shop/assistant/start.sh` becomes `~/.buzz-agents/shop/shop/start.sh`. The supervisor's stays `~/.buzz-agents/shop/supervisor/start.sh`.
- **The name on a command line.** An agent is named by its folder: `team.sh start shop`, `team.sh stop supervisor`, `agent-team.sh proof shop shop`. `agent` works for the workspace agent too. `assistant` is refused, with the new name.
- **The options.** `--assistant-backend`, `--assistant-model`, `--assistant-effort` and `--assistant-name` are now `--agent-backend`, `--agent-model`, `--agent-effort` and `--agent-name`; `--roles assistant,supervisor` and `--roles assistant` are now `--roles agent,supervisor` and `--roles agent`. The old spellings are refused with one line that names the new one. `--supervisor-*` and `--reviewer-*` are unchanged.
- **The role word.** Menus, the check, `status` and messages name an agent by its display name, with no role word: `Shop: provider?`, `Shop Supervisor: provider?`. Where a line shows the name to type, it is the folder name: `shop: Shop, the workspace agent`. `agent.conf` says `id=agent` and `role=agent`, and the workspace agent's prompt template is `templates/agent.md`, with the same text.
- **Kept model lists** are named `<backend>-agent.list`. A list kept by 3.0.0 as `<backend>-assistant.list` is no longer read: `agent-team.sh models --role agent` retrieves it again, and `team.sh` asks the provider before a model menu.
- **Nothing else changed.** Who answers whom, the allowlist, the channel supervisor's rules, the prompts, what holds each agent to the project folder, and each agent's key, proof, display name, backend, models and effort stay as they were.

How the upgrade does it:

- One rename moves `assistant/` to its new name; then its env file (its paths), `agent.conf` and `start.sh` are rewritten there, each earlier file kept as `<file>.bak-<time>`. `team.conf` gets `format=4` and `agent_folder=` (and `external_assistant=` becomes `external_agent=`), then `VERSION` is written last.
- The plan names the folder move and the new start command. An upgrade cut short after the move, or between the two renames of a folder, is finished by the next run. A team in format 2 or 1 goes straight to format 4.

## 3.0.0 (2026-11-22)

The two agents of a team swap their jobs. The agent named after the project (id `assistant`) becomes the workspace agent, with all the tools. The agent named "<Project> Supervisor" (id `supervisor`) becomes the channel supervisor, which talks with everyone in the channel. A team made by 2.0.0 does not start until it is upgraded (team folder format 3).

What changes for a 2.0.0 team, after `agent-team.sh upgrade <team>`:

- **The assistant, "<Project>", is the workspace agent.** It runs the stock adapter with all its tools and worker subagents, in `bypass-permissions`, as the supervisor did. It gets the supervisor's prompt rules, the "Your workspace" rule word for word, the sandbox settings in the project folder on Claude, and the workspace-write mode pin on Codex. It plans the work, dispatches worker subagents, reviews their evidence, and keeps `PROJECT.md` and the tracker.
- **It answers the owner and its channel supervisor.** Its env file says `BUZZ_ACP_RESPOND_TO=allowlist` and names the channel supervisor's public key in `BUZZ_ACP_RESPOND_TO_ALLOWLIST`. With no channel supervisor known on this machine it says `owner-only`.
- **The supervisor, "<Project> Supervisor", is the channel supervisor.** It runs the restricted runtime in its own folder (it reads the project folder; no edits, no commands, no web) and takes a turn on every ordinary message in its channel, as the discussion partner did. It runs brainstorms to a decision, proposes todos, brings decisions to the owner, and hands work the owner accepted to the workspace agent by mentioning it.
- **The channel supervisor still takes no turn for its own team's agents.** So a mention starts a turn in one direction only, from the channel supervisor to the workspace agent, and the two cannot set each other off.
- **Each agent keeps its folder, key, proof, display name, backend, models and effort.** Its saved model was chosen for its earlier job: the cheaper model usually sat on the discussion partner, which is now the workspace agent. The upgrade plan names each agent's new job and the model it keeps; `--assistant-model` and `--supervisor-model` pick new ones in the same run.
- **Files move with the jobs.** The runtime and `subscriptions.toml` move from the assistant's folder to the supervisor's. Each replaced or removed file is kept beside itself as `<file>.bak-<time>`. Each agent's profile description follows its new job; Buzz shows the old one until `finish` runs again.
- **Security.** The agent with every tool now takes a turn when an agent that listens to anyone in the channel mentions it. Before, its env file named only the owner. Starting work still needs the owner's own accepting message, signed by the owner. That is a rule in the workspace agent's prompt, and the harness does not enforce it. (Read in the harness's source, not tested: its owner-only mode also admits an agent whose Buzz profile carries a proof from the same owner. So in 2.0.0 the discussion partner may already have been able to reach the supervisor by mentioning it, and a reviewer of the same owner can reach the workspace agent the same way. 3.0.0 names the channel supervisor in the env file, so that path no longer depends on the profile.)

Changed:

- `create --roles supervisor` is refused. Its counterpart is `--roles assistant`: a workspace agent for a channel that already has a channel supervisor in another team. `--supervisor-name` names that channel supervisor, or the first one found on this machine is used; `team.conf` records it as `external_supervisor`.
- `create` and `start` refuse a team in format 2, as they refuse format 1, and name `upgrade`; `preflight NAME` marks it as a problem. `status` lists such a team and says what to do. `team.sh` refuses to start an agent whose record is not format 3.
- `agent-team.sh status`, `team.sh check` and `team.sh status` say whom each agent answers.
- `models` without `--role` lists the workspace agent's models (`assistant`), on the stock adapter as before.
- The prompts: `templates/assistant.md` is the workspace agent's, `templates/supervisor.md` the channel supervisor's. Their placeholders are `{{SUPERVISOR_NAME}}` and `{{WORKSPACE_AGENTS}}`. `project.md` and one sentence of `reviewer.md` name the new jobs.

## 2.0.0 (2026-11-22)

What holds the supervisor to its project folder changed: from programs placed in front of its adapter, to a rule in its prompt backed by plain settings. A team made by 1.0.0 keeps running as it is until it is upgraded.

Changed:

- **The wall programs are removed** (`wall/claude-agent-acp`, `wall/walled-claude`, `wall/bin/buzz`). The supervisor runs the stock adapter with nothing in front of it, in the permission mode its own settings file names.
- **A rule in the supervisor's prompt** tells it to stay inside the project folder, to run a command outside the sandbox only for a tool installed elsewhere or for network access the task needs, and to give a `buzz` command only files inside the project folder.
- **Sandbox settings in the project folder, for a supervisor on Claude:** `<project folder>/.claude/settings.json`. Its file tools refuse paths outside the project folder, its shell commands run in Claude Code's sandbox, and a plain `buzz` command runs outside the sandbox. `create` writes them before anything else in the project folder, `team.sh` before a start, and `upgrade` for the saved project folder. An existing file keeps everything else it holds; the earlier file is kept beside it. The new `scripts/workspace-settings.py` does this, and each team folder gets a copy.
- **A supervisor on Codex starts without `--no-wall`.** The stock adapter runs every turn in Codex's workspace-write sandbox by itself, and `team.sh` pins that mode (`INITIAL_AGENT_MODE=agent`). No Codex file is written, because the adapter replaces what a config file says about the sandbox.
- **`--no-wall` has a new meaning:** do not put the sandbox settings into the project folder at this start. Settings already in the folder stay and apply.
- **`wall_read` in `team.conf` is no longer used.** `team.sh check` says so when it finds one.
- **`upgrade` of a 1.0.0 team** removes `wall/` (kept as `wall.bak-<time>`), adds `workspace-settings.py`, and adds the sandbox settings to the saved project folder for a supervisor on Claude.
- `test-wall.py` is replaced by `test-workspace-settings.py`, which measures the settings with the installed Claude adapter.

No longer held, compared with 1.0.0, and asked of the supervisor by the prompt rule instead:

- A command the supervisor runs again outside the sandbox. 1.0.0 refused it.
- A `buzz` command given a file outside the project folder. 1.0.0 refused it.
- Folders your own Claude settings add as working folders count as inside the project folder. 1.0.0 did not load your settings for the supervisor.
- On Codex, what the supervisor reads: workspace-write does not limit reads. 1.0.0 refused to start a supervisor on Codex without `--no-wall`.

New side effect: the settings file applies to every Claude Code session started in that project folder, your own included.

## 1.0.0 (2026-11-22)

The first numbered version, and the first one kept in Git. Apart from the version itself, the skill is the copy that was installed on 2026-11-22.

New with the version:

- `buzz-agent-team/VERSION` holds the version, and `SKILL.md` repeats it as `metadata.version`.
- `agent-team.sh version` (also `--version` and `-V`) prints it. `agent-team.sh status` prints it with the version recorded in each team folder, and `agent-team.sh status <team>` prints one team's recorded version beside it.
- A team folder records the version of the skill that created it or last upgraded it, in its own `VERSION` file (mode 600). `create` writes it for a new team folder only. `upgrade` replaces it as its last step and shows the change in its plan as `VERSION: <recorded> -> <this skill's>`. `team.sh version` and `team.sh status` print it.
- `create` and `upgrade` stop before they write anything when the skill folder has no valid `VERSION`.
- `install.sh` refuses a skill folder without a valid `VERSION`, prints the version beside the installed one, and records it in its marker.

What 1.0.0 holds, built from 19 to 22 November 2026 before the skill had versions:

- **The setup script** `agent-team.sh`: `preflight`, `settings`, `create`, `proof`, `verify-proof`, `finish`, `upgrade`, `models`, `start`, `stop`, `status`.
- **Three roles:** a discussion partner and a supervisor in one team, and an independent reviewer as a team of its own.
- **Claude or Codex per agent,** signed in through the user's own subscription only, with one model and one reasoning effort per agent and provider.
- **The team's own command** `team.sh` in each team folder, each agent's own `start.sh`, and a model menu that asks the provider's adapter for its list at start.
- **The workspace wall:** the partner and the reviewer run a restricted runtime, and a supervisor on Claude runs behind `wall/`. A supervisor on Codex has no wall.
- **Team folder format 2.** A team made before 20 November 2026 (format 1) is brought to it by `upgrade`.
