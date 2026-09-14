#!/usr/bin/env python3
"""Check every shipped UI translation and its format arguments before building."""
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("cs", "de", "fr", "fr-CA", "bg", "sk")


def units(node):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for value in node.values():
        if isinstance(value, dict):
            yield from units(value)


def arguments(text):
    # Positional references may move to suit a language's word order.
    return Counter(re.findall(r"%(?:\d+\$)?(lld|llu|ld|lu|@|d|u|f)", text.replace("%%", "")))


def validate():
    errors = []
    count = 0
    for filename in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
        catalog = json.loads((ROOT / "Resources" / filename).read_text())
        for key, entry in catalog["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            if filename == "InfoPlist.xcstrings" and not key.startswith("NS"):
                continue  # Product names and internal drag identifiers.
            count += 1
            expected = arguments(key) if filename == "Localizable.xcstrings" else Counter()
            for language in LANGUAGES:
                translations = list(units(entry.get("localizations", {}).get(language, {})))
                if not translations:
                    errors.append(f"{filename}: {language}: missing {key!r}")
                for unit in translations:
                    if unit.get("state") != "translated" or not unit.get("value"):
                        errors.append(f"{language}: unfinished {key!r}")
                    if arguments(unit.get("value", "")) != expected:
                        errors.append(f"{language}: mismatched format arguments in {key!r}")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Validated {count} interface strings in all {len(LANGUAGES)} translated locales.")


if __name__ == "__main__":
    validate()
