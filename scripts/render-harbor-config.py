#!/usr/bin/env python3
"""Render Harbor's official harbor.yml.tmpl without requiring PyYAML."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def replace_top_level(text: str, key: str, value: str) -> str:
    pattern = rf"(?m)^{re.escape(key)}:\s*.*$"
    rendered, count = re.subn(pattern, f"{key}: {value}", text, count=1)
    if count != 1:
        raise SystemExit(f"missing top-level key in Harbor template: {key}")
    return rendered


def replace_section_value(text: str, section: str, key: str, value: str) -> str:
    lines = text.splitlines()
    in_section = False
    section_indent = 0
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(section)}:\s*$", line):
            in_section = True
            section_indent = len(line) - len(line.lstrip())
            continue
        if not in_section:
            continue
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped and not stripped.startswith("#") and indent <= section_indent:
            break
        if re.match(rf"^\s+{re.escape(key)}:\s*.*$", line):
            prefix = line[: len(line) - len(stripped)]
            lines[index] = f"{prefix}{key}: {value}"
            return "\n".join(lines) + "\n"
    raise SystemExit(f"missing key {section}.{key} in Harbor template")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--admin-password", required=True)
    parser.add_argument("--database-password", required=True)
    parser.add_argument("--data-volume", required=True)
    parser.add_argument("--log-location", required=True)
    args = parser.parse_args()

    text = Path(args.template).read_text()
    text = replace_top_level(text, "hostname", args.hostname)
    text = replace_section_value(text, "http", "port", args.port)
    text = replace_top_level(text, "harbor_admin_password", args.admin_password)
    text = replace_section_value(text, "database", "password", args.database_password)
    text = replace_top_level(text, "data_volume", args.data_volume)
    text, count = re.subn(
        r"(?m)^(\s+location:)\s*/var/log/harbor\s*$",
        rf"\1 {args.log_location}",
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("missing default log.local.location in Harbor template")
    Path(args.output).write_text(text)


if __name__ == "__main__":
    main()
