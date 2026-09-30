#!/usr/bin/env python3
"""Fails when the app could ship with English showing on a Dutch or German iPhone.

iOS 1.3.0 removed a half-finished Dutch localization (56 of 71 strings). This makes that state
unbuildable in CI. It reads the String Catalogs, the .stringsdata files the compiler writes next
to every object file, and the built .app, and never writes anything. It reports:

  A. strings the code uses that a catalog lacks, catalog keys the code no longer uses, keys
     added to a catalog by hand, a table (Localizable, AppShortcuts) the code uses that has no
     catalog in that target, a localized string inside #if DEBUG (an export for translation
     skips it) and NSLocalizedString (the compiler does not extract it). Xcode adds new strings
     only when a build runs in the IDE; a command-line build never does.
  B. every key without shouldTranslate=false has a translated nl and de value, in every plural
     case and substitution, with the same format specifiers per argument position as English,
     no em or en dash, App Shortcut phrases that keep ${applicationName}, a plural for every
     count, no two keys that differ only in case, and the terms in scripts/l10n/terms.json.
     InfoPlist.xcstrings covers every usage description and display name in the built
     Info.plist (from INFOPLIST_KEY_* and from Info.plist itself), with the English it was
     translated from, left in state "new" so it never overrides the plist for English.
  C. English prose that never reaches a catalog: a string literal the compiler did not extract
     (so it is a plain String) that reads like a sentence or a label. Log calls, identifiers,
     raw values and dictionary keys are skipped; the rest goes in scripts/l10n/allowlist.txt.
  D. the built bundles contain nl.lproj and de.lproj for every catalog, so a catalog that fell
     out of its target's Resources phase is caught as well.
  E. every catalog is in Xcode's own format (scripts/l10n/catalog.py), so an IDE build does not
     rewrite it.

Standard library only; runs with the macOS system python3 (3.9).

Usage: scripts/l10n/check.py --objroot DIR --symroot DIR [--github]
The usual way in is scripts/l10n.sh check; docs/localization.md explains the loop.
"""
import argparse
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog  # noqa: E402

LANGS = ("nl", "de")
REQUIRED_PLURAL_CASES = {"one", "other"}  # CLDR categories for nl and de
DASHES = ("\u2014", "\u2013")  # em dash, en dash
CONFIG = "Debug-iphonesimulator"

# target -> (source folder, product path relative to the build products folder)
TARGETS = {
    "LifeDashboardCompanion": ("LifeDashboardCompanion", "LifeDashboardCompanion.app"),
    "LifeDashboardWidget": (
        "LifeDashboardWidget", "LifeDashboardCompanion.app/PlugIns/LifeDashboardWidget.appex"),
}
INFOPLIST_LOCALIZABLE = re.compile(
    r"^(NS\w+UsageDescription|CFBundleDisplayName|CFBundleName|CFBundleSpokenName|NSHumanReadableCopyright)$")
ALLOWLIST = "scripts/l10n/allowlist.txt"
TERMS = "scripts/l10n/terms.json"
CATEGORIES = {"wire", "brand", "diagnostic", "debug-name", "no-plural", "manual-key"}
# A count followed by a word: "%lld records" must vary by plural, "Step %lld of %lld" need not.
COUNTED_NOUN = re.compile(r"%(?:\d+\$)?(?:ll|l)?d [a-z]")

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
problems = []
allow = []
terms = {}


def problem(path, msg, line=None):
    entry = (os.path.relpath(path, REPO) if os.path.isabs(path) else path, line, msg)
    if entry not in problems:  # the same file compiles once per architecture
        problems.append(entry)


# --- format specifiers --------------------------------------------------------------------

SPEC = re.compile(r"%(?:(\d+)\$)?([-+ #0']*\d*(?:\.\d+)?)(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp])"
                  r"|%#@(\w+)@|%%")


def spec_types(text):
    """{position: type} for one string; positions count from 1, as in %1$@."""
    out, pos = {}, 0
    for m in SPEC.finditer(text):
        if m.group(0) == "%%":
            continue
        if m.group(5):
            out["sub:" + m.group(5)] = "sub"
            continue
        pos += 1
        n = int(m.group(1)) if m.group(1) else pos
        conv, length = m.group(4), m.group(3) or ""
        if conv == "@":
            t = "object"
        elif conv in "dDiuUxXoOcC":
            t = "int64" if length in ("l", "ll", "q", "z", "t", "j") else "int"
        elif conv in "fFeEgGaA":
            t = "double"
        else:
            t = conv
        out[n] = t
    return out


# --- catalog walking ----------------------------------------------------------------------

def leaves(loc, path=""):
    """(path, value, state) for every translatable leaf of one localization."""
    if "stringUnit" in loc:
        u = loc["stringUnit"]
        yield path, u.get("value", ""), u.get("state")
    if "stringSet" in loc:
        s = loc["stringSet"]
        for i, v in enumerate(s.get("values", [])):
            yield f"{path}[{i}]", v, s.get("state")
    for kind, cases in loc.get("variations", {}).items():
        for case, sub in cases.items():
            yield from leaves(sub, f"{path}/{kind}.{case}")
    for name, sub in loc.get("substitutions", {}).items():
        yield from leaves(sub, f"{path}/sub.{name}")


def english_for(entry, key, path):
    """The English text a translated leaf must match: the same variation path when English has
    it, else English's 'other' case at that level, else the key itself."""
    en = entry.get("localizations", {}).get("en")
    if not en:
        return key
    by_path = {p: v for p, v, _ in leaves(en)}
    if path in by_path:
        return by_path[path]
    other = re.sub(r"(plural|device)\.\w+$", r"\1.other", path)
    return by_path.get(other, by_path.get("", key))


def check_entry(cat_path, key, entry, is_app_shortcut):
    for text in [key] + [v for _, v, _ in leaves(entry.get("localizations", {}).get("en", {}))]:
        if any(d in text for d in DASHES):
            problem(cat_path, f"English {key!r} contains an em or en dash")
            break
    if entry.get("shouldTranslate") is False:
        # The catalog's own escape hatch is reviewed in the same place as the code's.
        table = os.path.splitext(os.path.basename(cat_path))[0]
        if not allowed_key(table, key, "brand"):
            problem(cat_path, f"{key!r} is marked Don't Translate: list it in {ALLOWLIST} as brand with a reason")
        return
    if re.search(r"[a-z]\(s\)", key):
        problem(cat_path, f"{key!r} counts with '(s)': make it a plural (Vary by Plural in Xcode)")
    if entry.get("extractionState") == "stale":
        problem(cat_path, f"stale key, the code no longer uses it: {key!r} (scripts/l10n.sh prune)")
        return
    table = os.path.splitext(os.path.basename(cat_path))[0]
    if entry.get("extractionState") == "manual" and not allowed_key(table, key, "manual-key"):
        problem(cat_path, f"{key!r} was added by hand, not found in the code: the code should use it as a literal")
    en_loc = entry.get("localizations", {}).get("en", {})
    if COUNTED_NOUN.search(key) and "plural" not in en_loc.get("variations", {}) \
            and "substitutions" not in en_loc and not allowed_key(table, key, "no-plural"):
        problem(cat_path, f"{key!r} counts something: vary it by plural in en, nl and de, "
                          f"or list it in {ALLOWLIST} as no-plural with a reason")
    locs = entry.get("localizations", {})
    en = locs.get("en", {})
    en_plural = "plural" in en.get("variations", {})
    for lang in LANGS:
        loc = locs.get(lang)
        if not loc:
            problem(cat_path, f"{lang} missing for {key!r}")
            continue
        plural = loc.get("variations", {}).get("plural")
        if en_plural and plural is None and "substitutions" not in loc:
            problem(cat_path, f"{lang} for {key!r} is not split into plural cases like English")
        if plural is not None and not REQUIRED_PLURAL_CASES <= set(plural):
            problem(cat_path, f"{lang} plural for {key!r} lacks {sorted(REQUIRED_PLURAL_CASES - set(plural))}")
        en_subs, subs = set(en.get("substitutions", {})), set(loc.get("substitutions", {}))
        if en_subs != subs:
            problem(cat_path, f"{lang} substitutions for {key!r} are {sorted(subs)}, English has {sorted(en_subs)}")
        for name, sub in loc.get("substitutions", {}).items():
            cases = sub.get("variations", {}).get("plural", {})
            if not REQUIRED_PLURAL_CASES <= set(cases):
                problem(cat_path, f"{lang} substitution {name} of {key!r} lacks plural cases")
        for path, value, state in leaves(loc):
            where = f"{lang}{path}"
            if state != "translated":
                problem(cat_path, f"{where} for {key!r} is {state or 'missing'!r}, not translated")
            if not value.strip():
                problem(cat_path, f"{where} for {key!r} is empty")
            if any(d in value for d in DASHES):
                problem(cat_path, f"{where} for {key!r} contains an em or en dash: {value!r}")
            # A sentence left in English but marked translated. Single words and names (Webhook,
            # MQTT, Health Connect) are often the same in nl and de; three words hardly ever are.
            words = re.findall(r"[A-Za-z]{2,}", SPEC.sub(" ", value))
            if value == english_for(entry, key, path) and len(words) >= 3:
                problem(cat_path, f"{where} for {key!r} is the English text; translate it, or mark the key "
                                  f"Don't Translate if it is a name")
            check_terms(cat_path, key, lang, value)
            if is_app_shortcut:
                if value.count("${applicationName}") != 1:
                    problem(cat_path, f"{where} phrase for {key!r} needs ${{applicationName}} exactly once")
                continue
            want, got = spec_types(english_for(entry, key, path)), spec_types(value)
            optional_case = re.search(r"plural\.(zero|one)$", path)
            if got != want and not (optional_case and all(want.get(k) == t for k, t in got.items())):
                problem(cat_path, f"{where} for {key!r} has format {fmt(got)}, English has {fmt(want)}")


def fmt(types):
    return "{" + ", ".join(f"{k}:{v}" for k, v in sorted(types.items(), key=str)) + "}" if types else "none"


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# --- A: catalogs in sync with the code ----------------------------------------------------

def stringsdata_for(objroot, target):
    files, sources = [], set()
    # Exact path, not a recursive glob: build/l10n (the local default) sits inside build/.
    pattern = f"{objroot}/LifeDashboardCompanion.build/{CONFIG}/{target}.build/Objects-normal/*/*.stringsdata"
    for f in sorted(glob.glob(pattern, recursive=True)):
        src = load(f).get("source", "")
        # A file deleted since the last local build leaves its .stringsdata behind; its strings
        # would count as used and hide a dead key.
        if src.startswith("/") and not os.path.exists(src):
            continue
        if src.endswith(".swift"):
            real = os.path.realpath(src)
            if real.startswith(objroot + os.sep):
                files.append(f)  # generated (asset and string symbols)
                continue
            if not real.startswith(REPO + os.sep):
                problem(objroot, f"{objroot} holds a build of another checkout ({real}): build this one")
                return None, set()
            # The compiler leaves an unchanged .stringsdata or .o alone; the newest file it wrote
            # for this source (.swiftdeps is always rewritten) tells when it last compiled it.
            built = max(os.path.getmtime(p) for p in glob.glob(glob.escape(f[:-len("stringsdata")]) + "*"))
            if os.path.getmtime(real) > built:
                problem(real, "changed after the last build: build again, line numbers and strings are stale")
                return None, set()
        files.append(f)
        if src.endswith(".swift"):
            sources.add(os.path.realpath(src))
    return files, sources


def tables_in(files):
    tables = {}
    for f in files:
        for table, entries in load(f)["tables"].items():
            tables.setdefault(table, set()).update(e["key"] for e in entries)
    return tables


def sync_target(objroot, target, folder, tmp):
    files, sources = stringsdata_for(objroot, target)
    if files is None:
        return None, set()
    if not sources:
        problem(objroot, f"no .stringsdata for the Swift files of {target}: build it first, with "
                         f"SWIFT_EMIT_LOC_STRINGS=YES")
        return None, set()
    used = tables_in(files)
    catalogs = {os.path.splitext(os.path.basename(p))[0]: p
                for p in glob.glob(f"{REPO}/{folder}/**/*.xcstrings", recursive=True)}
    for table in sorted(used):
        if table not in catalogs:
            problem(f"{folder}/{table}.xcstrings",
                    f"{target} uses {len(used[table])} strings from table {table} but has no {table}.xcstrings")
    for table, path in sorted(catalogs.items()):
        if table == "InfoPlist":
            continue
        before = load(path)["strings"]
        if not catalog.is_canonical(path):
            problem(path, "not in Xcode's own format: write catalogs with scripts/l10n.sh or Xcode, "
                          "not by hand (scripts/l10n/catalog.py)")
        twins = {}
        for k in before:
            twins.setdefault(k.lower(), []).append(k)
        pairs_ok = [sorted(p) for p in terms.get("case_pairs_ok", [])]
        for group in twins.values():
            if len(group) > 1 and sorted(group) not in pairs_ok:
                problem(path, f"keys that differ only in case: {group}: use one spelling in the code")
        # Extraction broken (setting off, Xcode changed the layout) looks like "every key is
        # dead". Refuse to judge the catalog then, instead of passing or asking to delete it all.
        if len(before) >= 20 and len(used.get(table, ())) < len(before) / 2:
            problem(path, f"the build extracted {len(used.get(table, ()))} strings for {table}, the catalog has "
                          f"{len(before)}: extraction looks broken, not the catalog")
            continue
        work = os.path.join(tmp, target, os.path.basename(path))  # sync matches tables by basename
        os.makedirs(os.path.dirname(work), exist_ok=True)
        shutil.copy(path, work)
        subprocess.run(["xcrun", "xcstringstool", "sync", work, "--stringsdata", *files],
                       check=True, stdout=subprocess.DEVNULL)
        after = load(work)["strings"]
        missing = sorted(set(after) - set(before))
        dead = sorted(k for k in before if k not in after or after[k].get("extractionState") == "stale"
                      and before[k].get("extractionState") != "stale")
        for k in missing:
            problem(path, f"used in code but not in the catalog: {k!r}")
            if any(d in k for d in DASHES):
                problem(path, f"English {k!r} contains an em or en dash")
        for k in dead:
            problem(path, f"no longer used in code, remove it: {k!r}")
        for key, entry in after.items():
            if key not in missing and key not in dead:
                check_entry(path, key, entry, table == "AppShortcuts")
    return used, sources


# --- B: Info.plist ------------------------------------------------------------------------

def check_infoplist(symroot, target, folder, product):
    plist_path = f"{symroot}/{CONFIG}/{product}/Info.plist"
    if not os.path.exists(plist_path):
        problem(plist_path, f"built Info.plist of {target} not found: build first")
        return
    with open(plist_path, "rb") as f:
        built = plistlib.load(f)
    wanted = {k: v for k, v in built.items() if INFOPLIST_LOCALIZABLE.match(k) and isinstance(v, str)}
    cat_path = f"{REPO}/{folder}/InfoPlist.xcstrings"
    if not os.path.exists(cat_path):
        # A target whose only such keys are its names (the widget: the brand) needs none.
        if any(k not in ("CFBundleDisplayName", "CFBundleName") for k in wanted):
            problem(cat_path, f"{target} has {sorted(wanted)} in its Info.plist but no InfoPlist.xcstrings")
        return
    strings = load(cat_path)["strings"]
    for key, value in sorted(wanted.items()):
        entry = strings.get(key)
        if entry is None:
            problem(cat_path, f"missing {key} (it is in the built Info.plist: {value!r})")
            continue
        if entry.get("shouldTranslate") is False:
            continue
        en_unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
        if en_unit.get("value") != value:
            problem(cat_path, f"{key}: Info.plist now says {value!r}, the catalog's English is {en_unit.get('value')!r}; "
                              f"update it and the nl and de translations")
        # A translated English entry would replace the Info.plist text for English users, and
        # then an edit to the plist alone would no longer show.
        if en_unit.get("state") != "new":
            problem(cat_path, f"{key}: leave the English entry in state 'new', as the export writes it")
    for key in sorted(set(strings) - set(wanted)):
        problem(cat_path, f"{key} is not in the built Info.plist any more, remove it")
    for key, entry in strings.items():
        if key in wanted:
            check_entry(cat_path, key, entry, False)


def check_configs_agree():
    """CI checks the Debug build; the App Store gets Release. INFOPLIST_KEY_* is set per
    configuration in project.pbxproj, so a text changed in one of them would slip past."""
    pbx_path = f"{REPO}/LifeDashboardCompanion.xcodeproj/project.pbxproj"
    with open(pbx_path, encoding="utf-8") as f:
        pbx = f.read()
    seen = {}
    for name, body in re.findall(r"/\* (\w+) \*/ = \{\s*isa = XCBuildConfiguration;\s*buildSettings = \{(.*?)\n\t\t\t\};",
                                 pbx, re.S):
        bundle = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", body)
        for key, value in re.findall(r"INFOPLIST_KEY_(\w+) = (.*?);\n", body):
            if bundle and INFOPLIST_LOCALIZABLE.match(key):
                seen.setdefault((bundle.group(1), key), {})[name] = value
    for (bundle, key), values in sorted(seen.items()):
        if len(set(values.values())) > 1:
            problem(pbx_path, f"INFOPLIST_KEY_{key} of {bundle} differs between {sorted(values)}: "
                              f"the Release text would ship untranslated")


# --- C: prose that bypasses the catalog ---------------------------------------------------

LOG_CALL = re.compile(r"(?:[Ll]ogger\.\w+|\bLogger|\bos_log|\bprint|\bdebugPrint|\bfatalError|"
                      r"\bprecondition\w*|\bassert\w*|\bNSLog)\($")
ID_LABEL = re.compile(r"\b(forKey|systemName|systemImage|named|withIdentifier|withName|identifier|subsystem|"
                      r"category|kind|forHTTPHeaderField|forResource|ofType)\s*:\s*$")
PLACEHOLDER = re.compile(r"%arg|%(?:\d+\$)?(?:ll|l)?[@dfs]|\$\{\w+\}")


def enclosing_calls(text, pos):
    """Names of the calls whose parentheses enclose pos, innermost first."""
    calls, depth, i = [], 0, pos - 1
    while i >= 0 and pos - i < 6000:
        c = text[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                if c == "(":
                    m = re.search(r"([\w.]+)\s*$", text[max(0, i - 80):i])
                    calls.append((m.group(1) if m else "") + "(")
            else:
                depth -= 1
        i -= 1
    return calls


def without_interpolations(line):
    """The line with every \\( ... ) replaced by %arg, nested parentheses and strings included."""
    out, i = [], 0
    while i < len(line):
        if line.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(line) and depth:
                depth += {"(": 1, ")": -1}.get(line[i], 0)
                i += 1
            out.append("%arg")
        else:
            out.append(line[i])
            i += 1
    return "".join(out)


def looks_like_prose(literal):
    bare = PLACEHOLDER.sub("0", literal).strip()
    if not re.search(r"[A-Za-z]{2,}", bare):
        return False
    if re.search(r"\s", bare):
        # Two words or more; code-ish text (JSON, key=value, paths) is not prose.
        return not re.search(r"[{}=<>;_]|://", bare)
    return bool(re.fullmatch(r"[A-Z][a-z]+[:.!?]?", bare))


def load_allowlist():
    path = f"{REPO}/{ALLOWLIST}"
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = [p.strip() for p in line.split(" | ")]
            if len(parts) != 4 or not parts[3]:
                problem(ALLOWLIST, "entry needs 'file or key:Table | literal, key or * | category | reason'", n)
                continue
            if parts[2] not in CATEGORIES:
                problem(ALLOWLIST, f"category {parts[2]!r} is not one of {sorted(CATEGORIES)}", n)
                continue
            if parts[1] == "*" and not ui_free(parts[0]):
                problem(ALLOWLIST, f"{parts[0]} shows UI, so it cannot be allowlisted whole: list its literals", n)
                continue
            entries.append({"file": parts[0], "literal": parts[1], "category": parts[2], "reason": parts[3],
                            "line": n, "hits": 0})
    return entries


def ui_free(rel):
    """A file may be allowlisted whole only when nothing in it can reach the screen."""
    path = f"{REPO}/{rel}"
    if not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return not re.search(r"import SwiftUI|\bText\(|String\(localized:|LocalizedStringResource|LocalizedStringKey", text)


def allowed_key(table, key, category):
    for a in allow:
        if a["file"] == f"key:{table}" and a["literal"] == key and a["category"] == category:
            a["hits"] += 1
            return True
    return False


def check_terms(cat_path, key, lang, value):
    """Register and word choices from scripts/l10n/terms.json, so a Dutch or German string
    written months later still says "je"/"du" and uses the glossary's words."""
    for rule in terms.get("forbidden", {}).get(lang, []):
        if key in rule.get("except_keys", []):
            continue
        if re.search(rule["pattern"], value):
            problem(cat_path, f"{lang} for {key!r}: {rule['reason']} ({value!r})")
    for label in terms.get("labels", []):
        if label["en"].lower() in key.lower() and label[lang].lower() not in value.lower():
            problem(cat_path, f"{lang} for {key!r} names the {label['en']!r} button, so it must say "
                              f"{label[lang]!r} as that button does ({value!r})")


def debug_lines(text):
    """Line numbers inside #if DEBUG ... #endif (nested #if blocks followed)."""
    inside, stack = set(), []
    for n, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            stack.append(stripped == "#if DEBUG")
        elif stripped.startswith("#else") or stripped.startswith("#elseif"):
            if stack:
                stack[-1] = False
        elif stripped.startswith("#endif"):
            if stack:
                stack.pop()
        elif any(stack):
            inside.add(n)
    return inside


def check_sources(objroot, sources_by_target):
    """Localized strings the export cannot see, and strings the compiler does not extract."""
    for target in sources_by_target:
        for f in stringsdata_for(objroot, target)[0] or []:
            d = load(f)
            src = d.get("source", "")
            if not src.endswith(".swift") or not os.path.realpath(src).startswith(REPO + os.sep):
                continue
            with open(src, encoding="utf-8") as fh:
                inside = debug_lines(fh.read())
            for entries in d["tables"].values():
                for e in entries:
                    if e["location"]["startingLine"] in inside:
                        problem(os.path.realpath(src), f"{e['key']!r} is localized inside #if DEBUG, where an export "
                                f"for translation does not see it: define it outside the #if",
                                e["location"]["startingLine"])
    for src in sorted(set().union(*sources_by_target.values())):
        with open(src, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if "NSLocalizedString(" in line and not line.strip().startswith("//"):
                    problem(src, "NSLocalizedString is not extracted by the compiler: use String(localized:)", n)


def check_bypass(objroot, sources_by_target, tmp):
    compiled, shortcut_phrases = set(), set()
    for target in sources_by_target:
        for f in stringsdata_for(objroot, target)[0] or []:
            d = load(f)
            src = os.path.realpath(d["source"]) if d["source"].startswith("/") else d["source"]
            for table, entries in d["tables"].items():
                for e in entries:
                    compiled.add((src, e["location"]["startingLine"], e["location"]["startingColumn"]))
                    shortcut_phrases.update(e.get("values", []) if table == "AppShortcuts" else [])
    sources = sorted(set().union(*sources_by_target.values()))
    out = os.path.join(tmp, "potential")
    subprocess.run(["xcrun", "xcstringstool", "extract", "--all-potential-swift-keys", "--SwiftUI",
                    "--modern-localizable-strings", "-o", out, *sources], check=True, stdout=subprocess.DEVNULL)
    potential = agreed = localized_lw = 0
    for f in glob.glob(f"{out}/*.stringsdata"):
        d = load(f)
        src = os.path.realpath(d["source"])
        with open(src, encoding="utf-8") as fh:
            text = fh.read()
        lines = text.split("\n")
        starts = [0]
        for ln in lines:
            starts.append(starts[-1] + len(ln) + 1)
        for table, entries in d["tables"].items():
            for e in entries:
                loc = e["location"]
                where = (src, loc["startingLine"], loc["startingColumn"])
                if table != "__PotentialKeys":
                    localized_lw += 1
                    agreed += where in compiled
                else:
                    potential += 1
                if where in compiled:
                    continue
                key = e["key"]
                if key.replace("%arg", "${applicationName}") in shortcut_phrases:
                    continue
                pos = starts[loc["startingLine"] - 1] + loc["startingColumn"] - 1
                before = lines[loc["startingLine"] - 1][:loc["startingColumn"] - 1]
                after = text[pos:pos + len(key) + 8]
                if not looks_like_prose(key):
                    continue
                if any(LOG_CALL.search(c) for c in enclosing_calls(text, pos)):
                    continue
                if ID_LABEL.search(before) or re.search(r"\[\s*$|\bcase\b[^:]*=\s*$", before):
                    continue
                if re.match(r'"(?:[^"\\]|\\.)*"\s*:(?!:)', after) and not re.search(r"\?\s*$", before):
                    continue  # dictionary key (payload, JSON)
                rel = os.path.relpath(src, REPO)
                shown = key.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
                hit = next((a for a in allow if a["file"] == rel and a["literal"] in ("*", shown.strip())
                            and a["category"] not in ("no-plural", "manual-key")), None)
                if hit:
                    hit["hits"] += 1
                    continue
                problem(rel, f"English text that is not localized: \"{shown}\" (use a LocalizedStringKey or "
                             f"LocalizedStringResource, or allowlist it in {ALLOWLIST} with a reason)",
                        loc["startingLine"])
    # The extractor leaves Text(verbatim:) out entirely, so a sentence written there is found
    # with a plain pattern.
    for src in sources:
        with open(src, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                for m in re.finditer(r'verbatim:\s*"((?:[^"\\]|\\.)*)"', without_interpolations(line)):
                    lit = m.group(1)
                    rel = os.path.relpath(src, REPO)
                    if looks_like_prose(lit) and not any(
                            a["file"] == rel and a["literal"] in ("*", lit) and not a.update(hits=a["hits"] + 1)
                            for a in allow):
                        problem(rel, f"English text in Text(verbatim:) is never translated: \"{lit}\"", n)
    # If Xcode changes the extractor, this detector must fail loudly, not go quiet.
    if potential == 0 or localized_lw == 0 or agreed < 0.9 * localized_lw:
        problem("scripts/l10n/check.py", f"prose check is blind: {potential} literals, {agreed}/{localized_lw} localized ones "
                     f"matched the compiler's locations. Did Xcode change xcstringstool?")


# --- D: the built bundles -----------------------------------------------------------------

def check_bundle(symroot, target, folder, product, used):
    bundle = f"{symroot}/{CONFIG}/{product}"
    for path in sorted(glob.glob(f"{REPO}/{folder}/**/*.xcstrings", recursive=True)):
        table = os.path.splitext(os.path.basename(path))[0]
        if table == "InfoPlist" or table in (used or {}):
            for lang in LANGS:
                if not glob.glob(f"{bundle}/{lang}.lproj/{table}.strings*"):
                    problem(path, f"{product} has no {lang}.lproj/{table}.strings: is the catalog in the "
                                  f"{target} target's Copy Bundle Resources phase?")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--objroot", required=True)
    ap.add_argument("--symroot", required=True)
    ap.add_argument("--github", action="store_true", help="also print GitHub Actions annotations")
    args = ap.parse_args()
    objroot, symroot = os.path.realpath(args.objroot), os.path.realpath(args.symroot)
    tmp = tempfile.mkdtemp(prefix="l10n-")
    allow.extend(load_allowlist())
    if os.path.exists(f"{REPO}/{TERMS}"):
        terms.update(load(f"{REPO}/{TERMS}"))
    try:
        sources = {}
        for target, (folder, product) in TARGETS.items():
            used, sources[target] = sync_target(objroot, target, folder, tmp)
            check_infoplist(symroot, target, folder, product)
            check_bundle(symroot, target, folder, product, used)
        check_configs_agree()
        if all(sources.values()):
            check_sources(objroot, sources)
            check_bypass(objroot, sources, tmp)
            # Every entry must still match something, so the list only ever shrinks by itself.
            for a in allow:
                if a["hits"] == 0:
                    problem(ALLOWLIST, f"entry matches nothing any more, remove it: {a['file']} | {a['literal']}",
                            a["line"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for path, line, msg in problems:
        print(f"{path}:{line}: error: {msg}" if line else f"{path}: error: {msg}")
        if args.github:
            print(f"::error file={path}{',line=' + str(line) if line else ''}::{msg}")
    if problems:
        print(f"\n{len(problems)} localization problem(s). New or changed strings: run scripts/l10n.sh sync, "
              f"write nl and de (docs/localization.md), then scripts/l10n.sh check again.")
        return 1
    print("Localizations complete: every string in nl and de, nothing English left outside the catalogs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
