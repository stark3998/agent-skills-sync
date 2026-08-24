"""Thin shim for the Claude Skill that imports and runs the engine CLI.

Resolves the engine package whether it is installed (``docx_template_migrator``
on ``sys.path``) or vendored alongside this skill via the parent automation
folder.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _ensure_engine_on_path() -> None:
    here = Path(__file__).resolve()
    # Look for the engine package walking up to a few parents.
    candidates = [
        here.parents[1] / "engine",                      # vendored beside scripts
        here.parents[2],                                 # sibling of skill folder
        here.parents[3] / "automation",                  # NFCU layout
    ]
    for candidate in candidates:
        if (candidate / "docx_template_migrator").is_dir():
            sys.path.insert(0, str(candidate))
            return


def main() -> int:
    _ensure_engine_on_path()
    try:
        from docx_template_migrator.cli import main as cli_main
    except ImportError as exc:
        print(
            "ERROR: docx_template_migrator package not found. "
            "Install it with `pip install -e <engine_folder>` or vendor it next to this skill.",
            file=sys.stderr,
        )
        print(f"Detail: {exc}", file=sys.stderr)
        return 2
    return cli_main()


if __name__ == "__main__":
    sys.exit(main())
