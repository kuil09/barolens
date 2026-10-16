"""Reject obsolete product names outside explicitly bounded compatibility code."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OLD_NAME = re.compile(r"Lens|(?<![A-Z])LENS|(?<![A-Za-z])lens")
MIGRATION = "Sources/Barolens/App/BarolensMigration.swift"
LEGACY_BINDING = re.compile(
    r"^\s+BAROLENS_([A-Z0-9_]+): \$\{\{ (secrets|vars)\.BAROLENS_\1"
    r" \|\| \2\.LENS_\1 \}\}$"
)
legacy_lines = {
    '    static let legacyBundleIdentifier = "dev.local.lens"',
    '    static let legacyExportDirectoryName = "Lens"',
    '    static let legacyWindowFrameKey = "NSWindow Frame LensSettingsWindow"',
    '            "NSToolbar Configuration LensActions": "NSToolbar Configuration BarolensActions",',
    '            "NSToolbar Configuration LensSettingsToolbar": "NSToolbar Configuration BarolensSettingsToolbar"',
}
paths = subprocess.check_output(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
).decode().split("\0")
errors = []
checked = 0
for name in sorted(set(paths)):
    path = ROOT / name
    if not name or not path.is_file() or path == Path(__file__).resolve():
        continue
    if OLD_NAME.search(name):
        errors.append(f"{name}: obsolete filename")
    try:
        source = path.read_text()
    except UnicodeError:
        continue
    checked += 1
    for number, line in enumerate(source.splitlines(), 1):
        if not OLD_NAME.search(line):
            continue
        if name == MIGRATION and line in legacy_lines:
            continue
        if name == ".github/workflows/notarized-dmg.yml" and LEGACY_BINDING.fullmatch(line):
            continue
        errors.append(f"{name}:{number}: obsolete product name")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Branding: {checked} source/configuration documents checked; compatibility literals isolated.")
