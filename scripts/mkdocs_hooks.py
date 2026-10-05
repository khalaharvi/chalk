"""MkDocs hooks for the Chalk site (mkdocs.yml: hooks).

Pages that document settings and commands are generated from the files
Chalk itself reads, so they cannot drift from the code:

  <!-- generated: config-reference -->  every key in share/templates/config,
                                         with its comment and default
  <!-- generated: env-reference -->     the machine-level settings in
                                         CHALK_ENV_DEFAULTS (lib/config.sh)
  <!-- generated: usage -->             the usage text in bin/chalk

The build also checks the template against CHALK_CONFIG_DEFAULTS in
lib/config.sh. A key missing from either, or a default that differs, is
logged as a warning, which `mkdocs build --strict` turns into a failure.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

log = logging.getLogger("mkdocs.hooks.chalk")

# Kept in lib/config.sh so that old configs still load; not documented.
LEGACY_KEYS = {"CHALK_MEMORY"}

# Section titles for the template's blank-line separated groups, by the
# first key in each group. A new group gets a generic title until it is
# named here.
GROUP_TITLES = {
    "CHALK_BASE_BRANCH": "Repository",
    "CHALK_TEST_CMD": "The rubric",
    "CHALK_BUDGET_USD": "Loops, spend and verdicts",
    "CHALK_IMAGE": "Sandbox",
    "CHALK_TEXTBOOK": "Checks and submission",
    "CHALK_PERMISSION_MODE": "Permissions",
    "CHALK_MODEL": "Model",
}

KEY_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
ASSOC_ENTRY = re.compile(r'^\s*\[([A-Z][A-Z0-9_]*)\]=(.*)$')


def _root(config) -> Path:
    return Path(config.config_file_path).resolve().parent


def parse_template(path: Path) -> list[list[dict]]:
    """Groups of {key, default, lines} from a KEY=value file with comments.

    A comment block directly above a key describes it. A blank line ends a
    group; a comment block with no key under it (the file header) is
    dropped.
    """
    groups: list[list[dict]] = [[]]
    pending: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            pending = []
            if groups[-1]:
                groups.append([])
            continue
        if raw.startswith("#"):
            pending.append(raw[2:] if raw.startswith("# ") else raw[1:])
            continue
        match = KEY_LINE.match(raw)
        if match:
            groups[-1].append(
                {"key": match[1], "default": match[2], "lines": pending}
            )
            pending = []
    return [group for group in groups if group]


def parse_assoc(path: Path, name: str) -> dict[str, dict]:
    """The entries of `declare -gA NAME=( ... )` with the comments above them."""
    entries: dict[str, dict] = {}
    inside = False
    pending: list[str] = []
    variables = dict(
        re.findall(r'^([A-Z][A-Z0-9_]*)="([^"]*)"$', path.read_text(encoding="utf-8"), re.M)
    )
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not inside:
            inside = raw.startswith(f"declare -gA {name}=(")
            continue
        if raw.strip() == ")":
            break
        stripped = raw.strip()
        if stripped.startswith("#"):
            pending.append(stripped.lstrip("#").strip())
            continue
        match = ASSOC_ENTRY.match(raw)
        if match:
            value = match[2].strip().strip('"')
            value = re.sub(r"\$([A-Z_]+)", lambda m: variables.get(m[1], m[0]), value)
            entries[match[1]] = {"default": value, "lines": pending}
            pending = []
    return entries


def _describe(lines: list[str]) -> str:
    """Comment lines as Markdown: prose joined, indented lines kept as a block."""
    out: list[str] = []
    prose: list[str] = []
    block: list[str] = []

    def flush_prose():
        if prose:
            out.append(" ".join(prose))
            prose.clear()

    def flush_block():
        if block:
            out.append("```text\n" + "\n".join(block) + "\n```")
            block.clear()

    for line in lines:
        if line.startswith(" "):
            flush_prose()
            block.append(line.strip())
        else:
            flush_block()
            prose.append(line.strip())
    flush_prose()
    flush_block()
    return "\n\n".join(out)


def _default(value: str) -> str:
    return f"`{value}`" if value else "none"


def config_reference(root: Path) -> str:
    groups = parse_template(root / "share/templates/config")
    out: list[str] = []
    for group in groups:
        title = GROUP_TITLES.get(group[0]["key"], "More settings")
        out.append(f"## {title}\n")
        for entry in group:
            key = entry["key"]
            out.append(f"### `{key}` {{#{key.lower()}}}\n")
            out.append(f"Default: {_default(entry['default'])}\n")
            out.append(_describe(entry["lines"]) + "\n")
    return "\n".join(out)


def env_reference(root: Path) -> str:
    """One list item per comment in CHALK_ENV_DEFAULTS, naming the keys
    under it with their defaults."""
    entries = parse_assoc(root / "lib/config.sh", "CHALK_ENV_DEFAULTS")
    items: list[str] = []
    keys: list[str] = []
    meaning = ""

    def flush():
        if keys:
            names = ", ".join(f"`{k}` (default {_default(entries[k]['default'])})" for k in keys)
            items.append(f"- {names}: {meaning}" if meaning else f"- {names}")

    for key, entry in entries.items():
        if entry["lines"]:
            flush()
            keys = []
            meaning = " ".join(entry["lines"])
        keys.append(key)
    flush()
    return "\n".join(items) + "\n"


def usage(root: Path) -> str:
    text = (root / "bin/chalk").read_text(encoding="utf-8")
    match = re.search(r"cat <<USAGE\n(.*?)\nUSAGE\n", text, re.S)
    if not match:
        raise ValueError("bin/chalk: no usage text between 'cat <<USAGE' and 'USAGE'")
    lines = match[1].splitlines()
    if lines and lines[0].startswith("chalk $CHALK_VERSION"):
        lines = lines[1:]
    return "```text\n" + "\n".join(lines).strip("\n") + "\n```\n"


def check_config(root: Path) -> None:
    """Warns where share/templates/config and lib/config.sh disagree."""
    template = {
        entry["key"]: entry["default"]
        for group in parse_template(root / "share/templates/config")
        for entry in group
    }
    defaults = parse_assoc(root / "lib/config.sh", "CHALK_CONFIG_DEFAULTS")
    for key in sorted(set(defaults) - set(template) - LEGACY_KEYS):
        log.warning("lib/config.sh accepts %s, but share/templates/config does not document it", key)
    for key in sorted(set(template) - set(defaults)):
        log.warning("share/templates/config documents %s, which lib/config.sh does not accept", key)
    for key in sorted(set(template) & set(defaults)):
        if template[key] != defaults[key]["default"]:
            log.warning(
                "default of %s differs: share/templates/config has '%s', lib/config.sh has '%s'",
                key, template[key], defaults[key]["default"],
            )


GENERATORS = {
    "config-reference": config_reference,
    "env-reference": env_reference,
    "usage": usage,
}


def on_pre_build(config, **kwargs):
    check_config(_root(config))


def on_page_markdown(markdown, page, config, files, **kwargs):
    root = _root(config)

    def replace(match):
        return GENERATORS[match[1]](root)

    return re.sub(
        r"^<!-- generated: (" + "|".join(GENERATORS) + r") -->$",
        replace,
        markdown,
        flags=re.M,
    )
