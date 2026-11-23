# Changelog

Versions of the buzz-agent-team skill, newest first. The version is the one line of `buzz-agent-team/VERSION`, and each one is the Git tag `v<version>` of this repository. What the three numbers mean is in the [README](README.md#versions).

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
