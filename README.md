# Agent and Skill Sync

This repository mirrors personal agent, skill, hook, and VS Code prompt customizations so they can be versioned and synced across machines.

## Layout

| Repo path | Local path |
| --- | --- |
| `claude/agents/` | `%USERPROFILE%\.claude\agents\` |
| `claude/skills/` | `%USERPROFILE%\.claude\skills\` |
| `agents/skills/` | `%USERPROFILE%\.agents\skills\` |
| `agents/hooks/` | `%USERPROFILE%\.agents\hooks\` |
| `copilot/agents/` | `%USERPROFILE%\.copilot\agents\` (Copilot custom agents, `*.agent.md`) |
| `copilot/instructions/` | `%USERPROFILE%\.copilot\instructions\` (`*.instructions.md`) |
| `copilot/skills/` | `%USERPROFILE%\.copilot\skills\` |
| `copilot/hooks/` | `%USERPROFILE%\.copilot\hooks\` |
| `copilot/copilot-instructions.md` | `%USERPROFILE%\.copilot\copilot-instructions.md` |
| `copilot/mcp-config.json` | `%USERPROFILE%\.copilot\mcp-config.json` (Copilot CLI/app MCP servers) |
| `github/hooks/` | `%USERPROFILE%\.github\hooks\` |
| `vscode-user/prompts/` | `%APPDATA%\Code\User\prompts\` (legacy Local harness, removed Feb 2027) |
| `vscode-user/mcp.json` | `%APPDATA%\Code\User\mcp.json` (VS Code MCP servers) |

Copilot (VS Code, Copilot CLI, and the Copilot app) now reads user-level customizations from `~/.copilot/`. Old `*.chatmode.md` files should be renamed to `*.agent.md` and moved to `~/.copilot/agents/`.

MCP config files are synced as-is. Keep secrets out of them by using `${input:...}` variables or environment variables, never literal tokens.

## Export From This Machine

Run this after editing agents or skills locally:

```powershell
pwsh ./scripts/export-from-machine.ps1
git status
git add .
git commit -m "Sync agent and skill customizations"
git push
```

## Import On Another Machine

Clone the repo, review the contents, then run:

```powershell
pwsh ./scripts/import-to-machine.ps1
```

By default, import overwrites files that are present in the repo but does not delete extra local files. To make a destination exactly match the repo, pass `-Prune` after reviewing the diff.

## Safety Notes

- Do not store credentials, tokens, session state, backups, downloads, telemetry, or generated runtime files here.
- Keep secrets in the appropriate system keychain, Key Vault, or app-specific secure storage.
- Review `git status` before every commit, especially after adding new skill assets.
