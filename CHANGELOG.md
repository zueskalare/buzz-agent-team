# Changelog

Versions of the buzz-agent-team skill, newest first. The version is the one line of `buzz-agent-team/VERSION`, and each one is the Git tag `v<version>` of this repository. What the three numbers mean is in the [README](README.md#versions).

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
