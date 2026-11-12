---
applyTo: "**/docx_template_migrator/**,**/skills/docx-template-migrator*/**,**/presets/*.json"
---

# DOCX Template Migrator — coding rules

When working on the `docx_template_migrator` engine, its presets, or any wrapping skill:

- The engine MUST remain config-driven. Do not hard-code project-specific values (control IDs, NFCU references, theme metadata, template paragraph indices) in `core.py` or `cli.py`. All such values belong in a preset JSON.
- Preserve the original migration algorithm guarantees:
  - Configuration-steps ordering: each image stays inline next to its caption paragraph; consecutive `Normal` paragraphs are compressed to fit the template's slot budget.
  - Screenshots extracted from `word/media/` sorted by image number; inserted inline at 6.0 inches wide.
  - Removable template tables removed in reverse index order.
- Reference URLs MUST originate from the selected theme entry in the config. Never insert URLs synthesized at runtime or from web calls.
- The CLI MUST never modify or delete source files; all writes go to the explicit `--output` directory.
- When adding a new preset, validate parity by running the engine against a known source and diffing paragraph count, table count, media count, and paragraph text against the expected output.
- Keep `presets/*.json` and `skills/docx-template-migrator/presets/*.json` in sync — the skill folder vendors a copy for distribution.
- Update `references/config_schema.md` and `config_schema.json` whenever the `MigrationConfig` shape changes.
- Tests live under `Advanced Controls/automation/tests/` and must be hermetic (no network, no shared state).
