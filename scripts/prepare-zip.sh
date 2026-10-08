#!/usr/bin/env bash
#
# Vendor-copies @percy/maestro-app/percy into flows/percy, then zips flows/
# into Flows.zip for upload to the BrowserStack Maestro v2 build API.
#
# Mirrors the recommended "Mode B" pattern from the @percy/maestro-app README.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_PERCY="$ROOT_DIR/node_modules/@percy/maestro-app/percy"
FLOWS_DIR="${FLOWS_DIR:-$ROOT_DIR/flows}"
ZIP_OUT="${ZIP_OUT:-$ROOT_DIR/Flows.zip}"

if [ ! -d "$SDK_PERCY" ]; then
  echo "Error: $SDK_PERCY not found." >&2
  echo "Run 'npm install' first." >&2
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: 'zip' is not installed." >&2
  echo "Install it with your package manager (e.g. 'brew install zip')." >&2
  exit 1
fi

rm -rf "$FLOWS_DIR/percy"
cp -r "$SDK_PERCY" "$FLOWS_DIR/percy"

rm -f "$ZIP_OUT"
# BrowserStack requires the test-suite zip to contain a SINGLE root folder.
# Zipping files at the archive root fails the build with
# BROWSERSTACK_TESTSUITE_PARSE_ERROR. Zip the flows/ directory itself so
# "flows/" becomes that single root folder; relative runFlow paths
# (e.g. percy/flows/percy-screenshot.yaml) resolve unchanged inside it.
(cd "$ROOT_DIR" && zip -rq "$ZIP_OUT" "$(basename "$FLOWS_DIR")")

echo "Wrote $ZIP_OUT (contains: $(cd "$FLOWS_DIR" && find . -name '*.yaml' -not -path '*/percy/*' | sed 's|^\./||' | tr '\n' ' '))"
echo
echo "Upload the zip to BrowserStack:"
echo "  curl -u \"\$BROWSERSTACK_USERNAME:\$BROWSERSTACK_ACCESS_KEY\" \\"
echo "       -X POST 'https://api-cloud.browserstack.com/app-automate/maestro/v2/test-suite' \\"
echo "       -F 'file=@Flows.zip'"
