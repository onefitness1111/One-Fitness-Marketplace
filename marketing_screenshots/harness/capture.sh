#!/usr/bin/env bash
# Regenerates marketing_screenshots/*.png with real fonts.
# `flutter test` forces the Ahem font (--use-test-fonts) and skips asset
# fonts (--disable-asset-fonts). This script turns those two switches off
# for one run, then puts the Flutter tool back the way it was.
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is not on PATH" >&2
  exit 1
fi

FLUTTER_BIN="$(command -v flutter)"
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
DEVICE="$FLUTTER_ROOT/packages/flutter_tools/lib/src/test/flutter_tester_device.dart"
SNAPSHOT="$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
STAMP="$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"

if [[ ! -f "$DEVICE" ]]; then
  echo "Could not find flutter_tester_device.dart under $FLUTTER_ROOT" >&2
  exit 1
fi

cp "$DEVICE" "$DEVICE.marketing-bak"
restore() {
  mv "$DEVICE.marketing-bak" "$DEVICE"
  rm -f "$SNAPSHOT" "$STAMP"
}
trap restore EXIT

python3 - "$DEVICE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("      '--use-test-fonts',\n", "")
text = text.replace("      '--disable-asset-fonts',\n", "")
path.write_text(text)
PY

rm -f "$SNAPSHOT" "$STAMP"
flutter test marketing_screenshots/harness/capture_test.dart --reporter expanded
