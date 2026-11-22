# Changelog

Versions of the buzz-agent-team skill, newest first. The version is the one line of `buzz-agent-team/VERSION`, and each one is the Git tag `v<version>` of this repository. What the three numbers mean is in the [README](README.md#versions).

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
