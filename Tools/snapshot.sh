#!/bin/bash
# Snapshot harness (step 3): runs the Debug build of the app with --snapshot on a temporary, isolated state. The app
# captures its windows and its scene as PNG, writes report.txt and stats.json into <dossier>, then quits by itself.
# Never the copy in build/Demo, never the user's state. Exit code: the app's (0 done, 1 command line, 2 writing,
# 3 watchdog or interruption).
#
#   Tools/snapshot.sh <dossier> [scénario]      # scénario: all (default), overview, zooms… or "zooms,list"
set -u

if [ $# -lt 1 ] || [ $# -gt 2 ] || [ -z "$1" ]; then
    echo "Utilisation : Tools/snapshot.sh <dossier> [scénario]" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/DerivedData/Build/Products/Debug/PixelOpenSpace.app/Contents/MacOS/PixelOpenSpace"
if [ ! -x "$BIN" ]; then
    echo "snapshot.sh : l'app est introuvable ($BIN)." >&2
    echo "Construis d'abord l'app : xcodegen generate && xcodebuild -project PixelOpenSpace.xcodeproj" \
        "-scheme PixelOpenSpace -configuration Debug -derivedDataPath build/DerivedData" \
        "-skipPackagePluginValidation build" >&2
    exit 1
fi

OUT="$1"
if ! mkdir -p "$OUT"; then
    echo "snapshot.sh : impossible de créer le dossier $OUT." >&2
    exit 2
fi

"$BIN" --snapshot "$OUT" --scenario "${2:-all}" -ApplePersistenceIgnoreState YES
exit $?
