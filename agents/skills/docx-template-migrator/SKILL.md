---
name: docx-template-migrator
description: Migrate legacy Microsoft Word (.docx) documents into a revised template while preserving inline screenshots with captions in original sequence, replacing structured metadata, and populating reference sections from a configurable theme library. USE FOR migrate docx into a new template, mass-convert legacy Word documents, copy template and replace text, preserve inline screenshots and captions in source order, populate metadata table from legacy doc, populate reference URLs from a theme map, NFCU advanced controls migration, batch DOCX template re-skin, generate revised control documents from legacy controls. DO NOT USE FOR free-form document authoring, PDF generation, OCR, document validation/QA review, or any non-DOCX format.
---

# DOCX Template Migrator Skill

Migrates one or more legacy `.docx` documents into a copy of a revised template, preserving the original configuration-step sequence with inline images and captions, and populating structured metadata + reference sections from a JSON config.

This is a generalization of the working NFCU advanced-controls converter. It accepts any template + preset combination so the same engine can be reused across projects.

## When to invoke

- The user asks to "migrate", "convert", "re-skin", "re-template", or "copy into the new template" one or more `.docx` files.
- The user has a destination template `.docx` and a folder of legacy `.docx` source files.
- The user wants screenshots preserved inline (not all clustered at the top) with their original captions.
- The user wants reference URLs populated from a curated map keyed by control/topic theme.

Do NOT invoke for: PDF generation, free-form document authoring, OCR/text-recognition, generic Word automation, or document validation/review (a separate workflow).

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `template` | yes | Path to the destination DOCX template. |
| `source` | yes | Path to a single `.docx` file OR a folder of `.docx` files. |
| `output` | yes | Output directory for migrated documents. |
| `preset` | one-of | Name of a bundled preset under `presets/` (e.g. `nfcu_advanced_controls`). |
| `config` | one-of | Path to a custom migration config JSON. Schema: `references/config_schema.json`. |
| `pattern` | optional | Glob pattern when `source` is a directory (default `*.docx`). |

Provide either `preset` or `config`, not both.

## Usage

Install dependencies once:

```bash
pip install -r requirements.txt
```

Run a batch migration with the bundled NFCU preset:

```bash
python scripts/migrate.py \
  --template /path/to/Template_v1.1.docx \
  --source /path/to/legacy_folder \
  --output /path/to/output_folder \
  --preset nfcu_advanced_controls
```

Run with a custom config:

```bash
python scripts/migrate.py \
  --template Template.docx \
  --source legacy.docx \
  --output ./out \
  --config ./my_config.json
```

## Output

For each source file the skill writes a migrated `.docx` into the output directory. The CLI prints one line per file:

```
OK:   <source>.docx -> <output>.docx [<theme>, <N> blocks]
```

Warnings (e.g. missing image references) are printed to stderr but do not fail the run. Missing required slots, theme not found, or template-not-found cause a non-zero exit.

## Authoring a custom config

A migration config has three sections:

1. **Source parsing** — `legacy_section_headings` (map legacy headings to canonical section keys: `description`, `impact`, `risk`, `permissions`, `resources`, `steps`, `exception`), `description_prefix`.
2. **Theme + content selection** — `themes` (per-theme metadata + reference URLs + capabilities + rationale), `theme_keywords` (ordered keyword rules; first match wins), `default_theme`, `control_type_rules`, `metadata_static`.
3. **Template layout** — `layout` block with zero-based paragraph and table indices in the destination template (heading paragraphs, list ranges, metadata table row map, removable table indices, etc.).

See `references/config_schema.json` for the full JSON Schema and `presets/nfcu_advanced_controls.json` for a complete worked example.

To discover the indices for a new template, open the template in Python:

```python
from docx import Document
doc = Document("Template.docx")
for i, p in enumerate(doc.paragraphs):
    print(i, repr(p.text[:80]), p.style.name)
for i, t in enumerate(doc.tables):
    print(i, t.rows[0].cells[0].text[:60])
```

## Algorithm summary

1. Parse the legacy document into ordered blocks: each Configuration-Steps paragraph becomes a `text` block (with style preserved) and each inline drawing becomes an `image` block; consecutive `Normal` paragraphs are grouped to fit the available template slots.
2. Copy the template and clear the configurable paragraph/table slots.
3. Inject metadata (control id, title, control type, domain, MITRE/OWASP/regulatory tags, version/owner) into the metadata table per the layout map.
4. Populate impact, risk, permissions, resources, references, and exception sections from the parsed sections + the selected theme.
5. Render the configuration flow into a single section, inserting screenshots inline with their captions in source order.
6. Remove unused template tables listed in `removable_table_indices`.
7. Save the document.

## Safety

- The skill never deletes source files.
- It writes only to the explicitly provided `output` directory.
- It does not make network calls; reference URLs come from the config and are inserted as plain text.
- Image bytes are extracted into the system temp directory and re-injected into the output DOCX.
