# Agent and Skill Sync

This repository mirrors personal agent, skill, hook, and VS Code prompt customizations so they can be versioned and synced across machines.

## Layout

| Repo path | Local path |
| --- | --- |
| `claude/agents/` | `%USERPROFILE%\.claude\agents\` |
| `claude/skills/` | `%USERPROFILE%\.claude\skills\` |
| `agents/skills/` | `%USERPROFILE%\.agents\skills\` |
| `agents/hooks/` | `%USERPROFILE%\.agents\hooks\` |
| `vscode-user/prompts/` | `%APPDATA%\Code\User\prompts\` |

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
