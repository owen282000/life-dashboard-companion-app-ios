"""Reads and writes String Catalogs (.xcstrings) byte for byte the way Xcode does.

Xcode and `xcodebuild -exportLocalizations` decide which keys a catalog holds and in which
order. Anything else that edits a catalog (writing a translation, removing a stale key) goes
through here, so the file never changes in ways Xcode would undo at the next build.
"""
import json
import re
from collections import OrderedDict

# Xcode writes an empty object as "{", an empty line and "}" at the parent's indentation.
_EMPTY = re.compile(r"^( *)(.*)\{\}", re.M)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


def dumps(data):
    text = json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : "))
    return _EMPTY.sub(lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}", text)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        f.write(dumps(data))  # no newline at the end, as Xcode writes it


def is_canonical(path):
    with open(path, encoding="utf-8") as f:
        return f.read() == dumps(load(path))


def unit(value, state="translated"):
    return OrderedDict([("stringUnit", OrderedDict([("state", state), ("value", value)]))])


def plural(one, other):
    return OrderedDict([("variations", OrderedDict([("plural", OrderedDict([
        ("one", unit(one)), ("other", unit(other))]))]))])


def set_localization(entry, lang, localization):
    """Adds or replaces one language, keeping Xcode's order of languages (alphabetical)."""
    locs = entry.setdefault("localizations", OrderedDict())
    locs[lang] = localization
    entry["localizations"] = OrderedDict(sorted(locs.items()))
