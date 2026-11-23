#!/usr/bin/env python3
"""Audit UI/catalog coverage and exercise the compiled catalog with production L10n.

Run from any directory. --static-only needs Python/git only. Runtime checks need
full Xcode; all products, caches and preferences live in a temporary directory.
This is a lexical audit, not a Swift type checker; dynamic consumers are reported
for review rather than silently treated as covered.
"""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CATALOG = "OfflineMusic/Localizable.xcstrings"
PERMISSIONS = "OfflineMusic/InfoPlist.xcstrings"
LANGUAGES = ("de", "en", "es", "fr", "it", "pt-BR", "nl", "pl", "tr", "ja", "ko", "zh-Hans")
SINGLE_PLURAL_LANGUAGES = {"ja", "ko", "zh-Hans"}
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|h|l|L|z|t|j)?([@diuoxXfFeEgGaAcCsSp])")
CONSUMER = re.compile(r"\b(Text|Label|Button|Section|Picker|Toggle|Menu|Link|ProgressView|TextField|LabeledContent|ContentUnavailableView|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog|searchable|LocalizedStringKey|L10n\.(?:text|format|count))\s*\(")
GERMAN = re.compile(r"[äöüÄÖÜß]|\b(?:Die|Der|Das|Keine?|Nicht|Bitte|Titel|Datei|Dateien|Kopplung|Verbindung|erneut|werden|wurde|konnte|dein(?:e[msnr]?)?|ausgewählt|hinzugefügt|Sekunden|Minuten|fehlgeschlagen|gespeichert)\b")


@dataclass
class Literal:
    start: int
    end: int
    value: str
    expressions: tuple


def swift_literals(source):
    """Read quoted/raw/multiline Swift strings, nested interpolation and comments.

    The returned mask retains punctuation/code while hiding comments and string
    contents. Nested strings in interpolations are independently discoverable.
    """
    mask = list(source)
    literals = []

    def hide(start, end):
        for pos in range(start, end):
            if source[pos] != "\n":
                mask[pos] = " "

    def code(pos, nested=False):
        depth = 1
        while pos < len(source):
            if source.startswith("//", pos):
                end = source.find("\n", pos)
                end = len(source) if end < 0 else end
                hide(pos, end)
                pos = end
            elif source.startswith("/*", pos):
                start, count = pos, 1
                pos += 2
                while pos < len(source) and count:
                    if source.startswith("/*", pos):
                        count += 1
                        pos += 2
                    elif source.startswith("*/", pos):
                        count -= 1
                        pos += 2
                    else:
                        pos += 1
                hide(start, pos)
            elif source[pos] == '"' or (source[pos] == "#" and re.match(r'#+"', source[pos:])):
                pos = string(pos)
            elif nested and source[pos] == "(":
                depth += 1
                pos += 1
            elif nested and source[pos] == ")":
                depth -= 1
                if depth == 0:
                    return pos + 1
                pos += 1
            else:
                pos += 1
        return pos

    def string(start):
        pos = start
        while source[pos] == "#":
            pos += 1
        hashes = source[start:pos]
        quote = '"""' if source.startswith('"""', pos) else '"'
        pos += len(quote)
        endmark, escape = quote + hashes, "\\" + hashes
        value, expressions = [], []
        while pos < len(source):
            if source.startswith(endmark, pos):
                pos += len(endmark)
                break
            if source.startswith(escape + "(", pos):
                expr_start = pos + len(escape) + 1
                pos = code(expr_start, nested=True)
                expressions.append(source[expr_start:pos - 1])
                value.append("%@")
            elif source.startswith(escape, pos):
                pos += len(escape)
                if pos < len(source):
                    value.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0"}.get(source[pos], source[pos]))
                    pos += 1
            else:
                value.append(source[pos])
                pos += 1
        literals.append(Literal(start, pos, "".join(value), tuple(expressions)))
        hide(start, pos)
        return pos

    code(0)
    return sorted(literals, key=lambda item: item.start), "".join(mask)


def units(node, path=()):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield path, node["stringUnit"]
        for key, value in node.items():
            if key != "stringUnit":
                yield from units(value, path + (key,))


def signature(value):
    # Preserve argument positions/types while allowing translators to reorder.
    result, index = {}, 1
    for match in FORMAT.finditer(value.replace("%%", "")):
        position = int(match[1]) if match[1] else index
        result[position] = (match[2] or "") + match[3]
        index += 1
    return result


def plural_case(language, count):
    if language in SINGLE_PLURAL_LANGUAGES:
        return "other"
    if count == 1 or count == 0 and language in {"fr", "pt-BR"}:
        return "one"
    if language == "pl":
        return "few" if 2 <= count % 10 <= 4 and not 12 <= count % 100 <= 14 else "many"
    return "other"


def argument_end(mask, start):
    depth = 0
    for position in range(start, len(mask)):
        character = mask[position]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            if depth == 0:
                return position
            depth -= 1
        elif character == "," and depth == 0:
            return position
    return len(mask)


def validate_catalog(catalog, baseline):
    errors = []
    entries = catalog["strings"]
    if catalog.get("sourceLanguage") != "de":
        errors.append("Catalog sourceLanguage must remain de")
    preserved = 0
    for key, entry in baseline["strings"].items():
        for language, localization in entry.get("localizations", {}).items():
            for path, unit in units(localization):
                if unit.get("state") != "translated":
                    continue
                current = dict(units(entries.get(key, {}).get("localizations", {}).get(language, {}))).get(path)
                if current != unit:
                    errors.append(f"Original translation changed/removed: {language} {key!r} {'/'.join(path)}")
                preserved += 1
    for key, entry in entries.items():
        if entry.get("shouldTranslate") is False:
            continue
        for language in LANGUAGES:
            localization = entry.get("localizations", {}).get(language)
            if localization is None:
                if language != "de" and any(char.isalpha() for char in FORMAT.sub("", key)):
                    errors.append(f"Missing {language} translation: {key!r}")
                continue  # German source-key fallback is intentional.
            leaves = list(units(localization))
            if not leaves:
                errors.append(f"Empty localization: {language} {key!r}")
            for path, unit in leaves:
                value = unit.get("value", "")
                if not value and key:
                    errors.append(f"Empty value: {language} {key!r}")
                if language != "de" and unit.get("state") != "translated":
                    errors.append(f"Unfinished {language} translation: {key!r} {'/'.join(path)}")
                # Substitutions contain fragments, not a complete format.
                if "substitutions" not in path and signature(key) != signature(value):
                    errors.append(f"Format mismatch: {language} {key!r}: {signature(key)} != {signature(value)}")
            plural = localization.get("variations", {}).get("plural", {})
            if entry.get("localizations", {}).get("de", {}).get("variations", {}).get("plural"):
                required = {"other"}
                if language not in SINGLE_PLURAL_LANGUAGES:
                    required.add("one")
                if language == "pl":
                    required.update(("few", "many"))
                if not required <= plural.keys():
                    errors.append(f"Missing plural variants {required - plural.keys()}: {language} {key!r}")
    print(f"Catalog: {len(entries)} keys; checked {preserved} original translated units against git baseline")
    return errors


def audit_sources(catalog):
    entries = catalog["strings"]
    errors, review = [], []
    files = sorted((ROOT / "OfflineMusic").glob("*.swift"))
    literal_count = consumer_count = 0
    for file in files:
        source = file.read_text()
        literals, mask = swift_literals(source)
        by_start = {item.start: item for item in literals}
        consumers = list(CONSUMER.finditer(mask))
        literal_count += len(literals)
        for consumer in consumers:
            pos = consumer.end()
            while pos < len(source) and source[pos].isspace():
                pos += 1
            literal = by_start.get(pos)
            consumer_count += 1
            location = f"{file.relative_to(ROOT)}:{source.count(chr(10), 0, consumer.start()) + 1}"
            if literal:
                key = literal.value
                if not any(c.isalpha() for c in key):
                    continue
                variants = {key}
                # SwiftUI interpolation's type depends on overload resolution.
                # Both historic %@ and explicit Int64 catalog keys are checked.
                if literal.expressions:
                    variants.add(key.replace("%@", "%lld"))
                if not variants.intersection(entries):
                    errors.append(f"{location}: {consumer[1]} literal missing catalog: {key!r}")
            else:
                end = source.find("\n", pos)
                expression = source[pos:end if end >= 0 else len(source)].strip()[:180]
                # Explicit localization wrappers remain independently audited.
                if not expression.startswith(("L10n.", "LocalizedStringKey(", "Text(", "verbatim:")):
                    review.append(f"{location}: dynamic {consumer[1]}({expression}")
                # LocalizedStringKey's branches are app keys even when their
                # surrounding expression is dynamic. Search prompts are labeled
                # arguments and are audited separately below.
                if consumer[1] == "LocalizedStringKey":
                    end = argument_end(mask, pos)
                    for candidate in literals:
                        if pos <= candidate.start < end and candidate.value and not candidate.expressions:
                            if candidate.value not in entries:
                                errors.append(f"{location}: dynamic key missing catalog: {candidate.value!r}")
        for prompt in re.finditer(r"\bprompt\s*:", mask):
            pos = prompt.end()
            while pos < len(source) and source[pos].isspace():
                pos += 1
            literal = by_start.get(pos)
            if literal and literal.value not in entries:
                location = f"{file.relative_to(ROOT)}:{source.count(chr(10), 0, prompt.start()) + 1}"
                errors.append(f"{location}: search prompt missing catalog: {literal.value!r}")
        for literal in literals:
            if not GERMAN.search(literal.value) or literal.value in entries:
                continue
            if literal.value.replace("%@", "%lld") in entries:
                continue
            # Sentinels/errors may originate outside a View; audit all files.
            location = f"{file.relative_to(ROOT)}:{source.count(chr(10), 0, literal.start) + 1}"
            review.append(f"{location}: German candidate outside catalog: {literal.value!r}")
    print(f"Source audit: {len(files)} Swift files, {literal_count} literals, {consumer_count} UI/localization consumers")
    return errors, review


def audit_extracted_strings(catalog, directory):
    """Check compiler-resolved SwiftUI keys, including exact integer types."""
    files = sorted(directory.rglob("*.stringsdata"))
    if not files:
        return [f"No compiler .stringsdata files found in {directory}"]
    errors, keys = [], set()
    for file in files:
        extracted = json.loads(file.read_text())
        for item in extracted.get("tables", {}).get("Localizable", []):
            key = item["key"]
            keys.add(key)
            if key not in catalog["strings"] and any(c.isalpha() for c in FORMAT.sub("", key)):
                errors.append(f"Compiler key missing catalog: {extracted.get('source', file.name)}:{item.get('location', {}).get('startingLine', '?')}: {key!r}")
    print(f"Compiler extraction: {len(files)} files, {len(keys)} distinct exact SwiftUI keys")
    return errors


def runtime_checks(catalog, permissions, directory, environment):
    bundle = directory / "LocalizationChecks.app" / "Contents"
    resources, executable = bundle / "Resources", bundle / "MacOS" / "LocalizationChecks"
    resources.mkdir(parents=True)
    executable.parent.mkdir()
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "test.offlinemusic.localization." + directory.name,
        "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL",
        "CFBundleDevelopmentRegion": "de", "CFBundleLocalizations": list(LANGUAGES),
    }))
    # Snapshot inputs together so concurrent agent edits cannot alter half a run.
    snapshot = directory / "Localizable.xcstrings"
    snapshot.write_text(json.dumps(catalog, ensure_ascii=False))
    helper = directory / "Localization.swift"
    helper.write_bytes((ROOT / "OfflineMusic/Localization.swift").read_bytes())
    theme = (ROOT / "OfflineMusic/AppTheme.swift").read_text()
    # Only this Foundation-compatible presentation enum is needed; retain its
    # implementation verbatim, leaving UIKit/SwiftUI surfaces out of this build.
    metadata = directory / "MetadataText.swift"
    metadata.write_text(theme[theme.index("enum MetadataText {"):theme.index("private struct MusicScreen:")])
    language_options = [option for language in LANGUAGES for option in ("--language", language)]
    subprocess.run(["xcrun", "xcstringstool", "compile", str(snapshot), "--output-directory", str(resources),
                    *language_options], env=environment, check=True, timeout=60)
    permission_snapshot = directory / "InfoPlist.xcstrings"
    permission_snapshot.write_text(json.dumps(permissions, ensure_ascii=False))
    subprocess.run(["xcrun", "xcstringstool", "compile", str(permission_snapshot), "--output-directory", str(resources),
                    *language_options], env=environment, check=True, timeout=60)
    for language in LANGUAGES:
        if not (resources / f"{language}.lproj/Localizable.strings").is_file():
            raise RuntimeError(f"No compiled {language} strings")
        if not (resources / f"{language}.lproj/Localizable.stringsdict").is_file():
            raise RuntimeError(f"No compiled {language} plurals")
    # Exercise every plain catalog lookup and representative integer plural in each language.
    cases = []
    for key in permissions["strings"]:
        for language in LANGUAGES:
            value = permissions["strings"][key]["localizations"][language]["stringUnit"]["value"]
            if not value:
                raise RuntimeError(f"Empty permission description: {language} {key}")
            cases.append({"language": language, "key": key, "expected": value, "table": "InfoPlist"})
    for key, entry in catalog["strings"].items():
        if signature(key) == {1: "lld"}:
            for language in LANGUAGES:
                node = entry.get("localizations", {}).get(language, {})
                plural = node.get("variations", {}).get("plural", {})
                for count in (0, 1, 2, 5, 12, 21, 22, 25):
                    form = plural.get(plural_case(language, count), plural.get("other", node))
                    value = form.get("stringUnit", {}).get("value", key)
                    expected = FORMAT.sub(lambda match: str(count), value)
                    cases.append({"language": language, "key": key, "expected": expected, "count": count})
        if signature(key) or "%#@" in key:
            continue
        for language in LANGUAGES:
            node = entry.get("localizations", {}).get(language, {})
            value = node.get("stringUnit", {}).get("value", key)
            if not node or "stringUnit" in node:
                cases.append({"language": language, "key": key, "expected": value})
    cases_path = directory / "lookups.json"
    cases_path.write_text(json.dumps(cases, ensure_ascii=False))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "modules"),
                    str(helper), str(metadata), str(ROOT / "Tests/check_localization.swift"), "-o", str(executable)],
                   cwd=ROOT, env=environment, check=True, timeout=120)
    subprocess.run([str(executable), str(cases_path)], env=environment, check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static-only", action="store_true")
    parser.add_argument("--baseline", default="HEAD", help="git revision containing translations to preserve")
    parser.add_argument("--report", type=Path, help="write full JSON audit, including dynamic consumers for review")
    parser.add_argument("--extracted-strings", type=Path, help="also audit Xcode-generated .stringsdata below this directory")
    arguments = parser.parse_args()
    catalog = json.loads((ROOT / CATALOG).read_text())
    permissions = json.loads((ROOT / PERMISSIONS).read_text())
    baseline = json.loads(subprocess.check_output(["git", "show", f"{arguments.baseline}:{CATALOG}"], cwd=ROOT, text=True))
    permissions_baseline = json.loads(subprocess.check_output(["git", "show", f"{arguments.baseline}:{PERMISSIONS}"], cwd=ROOT, text=True))
    errors = validate_catalog(catalog, baseline)
    errors.extend(validate_catalog(permissions, permissions_baseline))
    source_errors, review = audit_sources(catalog)
    errors.extend(source_errors)
    if arguments.extracted_strings:
        errors.extend(audit_extracted_strings(catalog, arguments.extracted_strings))
    if arguments.report:
        arguments.report.write_text(json.dumps({"errors": errors, "review": review}, indent=2, ensure_ascii=False) + "\n")
    for error in errors:
        print("FAIL:", error)
    print(f"Manual-review candidates: {len(review)} (use --report PATH for the full list)")
    if not arguments.static_only and not errors:
        with tempfile.TemporaryDirectory(prefix="localization-checks-") as temp:
            directory = Path(temp)
            environment = {**os.environ, "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
                           "CLANG_MODULE_CACHE_PATH": str(directory / "clang"), "SWIFT_MODULECACHE_PATH": str(directory / "swift")}
            runtime_checks(catalog, permissions, directory, environment)
    if errors:
        raise SystemExit(1)
    runtime_summary = f" and compiled runtime checks in {len(LANGUAGES)} languages" if not arguments.static_only else ""
    print("PASS: catalog integrity, translation preservation, and static literal coverage" + runtime_summary)


if __name__ == "__main__":
    main()
