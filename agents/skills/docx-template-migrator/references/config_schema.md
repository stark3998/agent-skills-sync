# Migration Config Reference

A migration config is a JSON document with three concerns: (1) how to parse the legacy doc, (2) what theme metadata + reference URLs to inject, and (3) where in the destination template to write each value.

See the JSON Schema at [config_schema.json](./config_schema.json) and the worked example at `presets/nfcu_advanced_controls.json` (one level up).

## Top-level fields

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `legacy_section_headings` | object | yes | Map of legacy heading text → canonical section key (`description`, `impact`, `risk`, `permissions`, `resources`, `steps`, `exception`, or `null` to ignore). |
| `description_prefix` | string | no | Heading prefix used to locate the legacy "Description" section. Defaults to `"Description:"`. |
| `themes` | object | yes | Map of theme name → theme entry (see below). |
| `theme_keywords` | array | yes | Ordered routing rules used to pick a theme from the legacy filename + description. First match wins. |
| `default_theme` | string | yes | Theme used if no `theme_keywords` rule matches. |
| `control_type_rules` | array | no | Optional `{label, keywords}` rules for inferring the control type label from the description. |
| `default_control_type` | string | no | Fallback control type label. |
| `metadata_static` | object | no | Static values written into the metadata table (`version`, `status`, `last_updated`, `owner`). |
| `title_table_text` | string | no | Format string for the title-bar table; supports `{title}` and `{domain}`. |
| `output_name_template` | string | no | Format string for the output filename; supports `{stem}`. |
| `default_exception_text` | string | no | Paragraph text written above the exception bullets. |
| `default_exception_bullets` | array | no | List of bullet strings written into the exception section. |
| `layout` | object | yes | Index map for the destination template (see below). |

## Theme entry

```json
{
  "domain": "AI Runtime Security / AI Governance",
  "platforms": "Microsoft Foundry, Azure Policy, Microsoft Sentinel",
  "mitre": "ML Model Evasion, Prompt Injection",
  "owasp": "LLM01: Prompt Injection",
  "regulatory": "EU AI Act Article 9, NIST AI RMF GOVERN 1.2",
  "rationale": "This is an advanced control because ...",
  "capabilities": ["Capability one ...", "Capability two ...", "Capability three ..."],
  "official_refs": ["Title — https://learn.microsoft.com/..."],
  "research_refs": ["Title — https://atlas.mitre.org/"]
}
```

## Theme keyword rule

```json
{ "theme": "copilot-audit", "keywords": ["audit", "copilot studio"], "match": "all" }
```

`match` is `"any"` (default) or `"all"`. Keyword comparison is case-insensitive against the lowercased filename concatenated with the legacy description.

## Layout block

The layout block is a flat record of zero-based indices into `Document(template).paragraphs` and `Document(template).tables`. Required keys (with NFCU defaults) are documented in `config_schema.json`. The most important ones:

- `title_paragraphs` — paragraphs that hold the document title (typically `[0, 1, 2]`).
- `description_paragraph` — paragraph that holds the long description.
- `metadata_table_index` + `metadata_rows` — table index and row map for the structured metadata table.
- `config_heading_paragraph`, `config_slot_range`, `list_donor_paragraph` — bounds and donor paragraph for the configuration-flow region. Slots between `config_slot_range` are cleared and reused for legacy text + screenshots.
- `official_refs_range`, `research_refs_range` — paragraph ranges populated from the theme's reference lists.
- `exception_intro_paragraph`, `exception_bullet_paragraphs` — exception section.
- `removable_table_indices` — tables to remove from the template (rendered in reverse order so indices stay valid).

## Discovering layout indices for a new template

```python
from docx import Document
doc = Document("Template.docx")
for i, p in enumerate(doc.paragraphs):
    print(i, repr(p.text[:80]), p.style.name)
for i, t in enumerate(doc.tables):
    print(i, "rows=", len(t.rows), "first=", t.rows[0].cells[0].text[:60])
```

Capture each anchor heading's index in the layout block, then copy the NFCU preset and adjust ranges as needed.
