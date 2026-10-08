#!/usr/bin/env bash
#
# End-to-end smoke test: runs this example's flows on BrowserStack App Automate
# with Percy enabled, on a chosen Maestro version, and fails unless every
# expected snapshot reached Percy.
#
# Used as the per-release go/no-go when BrowserStack adds or changes a Maestro
# version: run it once per version with MAESTRO_VERSION=<version>.
#
# Required env:
#   BROWSERSTACK_USERNAME, BROWSERSTACK_ACCESS_KEY, PERCY_TOKEN (App project)
# Optional env:
#   MAESTRO_VERSION      maestroVersion for the build (unset = BrowserStack default)
#   BS_DEVICE            device to run on (default: Samsung Galaxy S22-12.0)
#   EXPECTED_SNAPSHOTS   snapshots that must reach Percy (default: 4)
#   PERCY_BRANCH         Percy branch for the build (default: maestro-smoke-<version>)
#   BS_API               BrowserStack API base (default: https://api-cloud.browserstack.com)
#   SMOKE_TIMEOUT_SECS   max wait for the BrowserStack build (default: 1800)
#
# Requires: curl, jq, zip, and `npm install` already run (for prepare-zip).
#
# On success prints PERCY_BUILD_ID=<id> so a caller can `percy build:wait` on it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${BROWSERSTACK_USERNAME:?BROWSERSTACK_USERNAME is required}"
: "${BROWSERSTACK_ACCESS_KEY:?BROWSERSTACK_ACCESS_KEY is required}"
: "${PERCY_TOKEN:?PERCY_TOKEN is required}"

MAESTRO_VERSION="${MAESTRO_VERSION:-}"
BS_DEVICE="${BS_DEVICE:-Samsung Galaxy S22-12.0}"
EXPECTED_SNAPSHOTS="${EXPECTED_SNAPSHOTS:-4}"
PERCY_BRANCH="${PERCY_BRANCH:-maestro-smoke-${MAESTRO_VERSION:-default}}"
BS_API="${BS_API:-https://api-cloud.browserstack.com}"
SMOKE_TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-1800}"

for bin in curl jq zip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: '$bin' is not installed." >&2; exit 1; }
done

AUTH="$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY"
MAESTRO_API="$BS_API/app-automate/maestro/v2"

bs() { curl -sS --fail-with-body -u "$AUTH" "$@"; }

echo "==> Maestro version: ${MAESTRO_VERSION:-<BrowserStack default>} | device: $BS_DEVICE | expecting $EXPECTED_SNAPSHOTS snapshots"

echo "==> Preparing Flows.zip"
bash "$SCRIPT_DIR/prepare-zip.sh"

echo "==> Uploading app and test suite"
APP_URL=$(bs -X POST "$MAESTRO_API/app" -F "file=@$ROOT_DIR/resources/app-debug.apk" | jq -r '.app_url')
SUITE_URL=$(bs -X POST "$MAESTRO_API/test-suite" -F "file=@$ROOT_DIR/Flows.zip" | jq -r '.test_suite_url')
if [[ "$APP_URL" != bs://* || "$SUITE_URL" != bs://* ]]; then
  echo "Error: upload failed (app=$APP_URL suite=$SUITE_URL)" >&2
  exit 1
fi
echo "    app=$APP_URL suite=$SUITE_URL"

echo "==> Triggering build"
BODY=$(jq -n \
  --arg app "$APP_URL" --arg suite "$SUITE_URL" --arg device "$BS_DEVICE" \
  --arg version "$MAESTRO_VERSION" --arg token "$PERCY_TOKEN" --arg branch "$PERCY_BRANCH" \
  '{app: $app, testSuite: $suite, devices: [$device], project: "percy-maestro-smoke",
    appPercy: {PERCY_TOKEN: $token, env: {PERCY_BRANCH: $branch}}}
   + (if $version == "" then {} else {maestroVersion: $version} end)')
BUILD_ID=$(bs -X POST "$MAESTRO_API/android/build" -H "Content-Type: application/json" -d "$BODY" | jq -r '.build_id // empty')
if [ -z "$BUILD_ID" ]; then
  echo "Error: BrowserStack did not return a build_id" >&2
  exit 1
fi
echo "    BrowserStack build: $BUILD_ID"

echo "==> Waiting for BrowserStack build"
DEADLINE=$(( $(date +%s) + SMOKE_TIMEOUT_SECS ))
while :; do
  BUILD_JSON=$(bs "$MAESTRO_API/builds/$BUILD_ID")
  STATUS=$(jq -r '.status' <<<"$BUILD_JSON")
  case "$STATUS" in
    running|queued) ;;
    *) break ;;
  esac
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Error: build still '$STATUS' after ${SMOKE_TIMEOUT_SECS}s" >&2
    exit 1
  fi
  sleep 30
done
echo "    BrowserStack build status: $STATUS"

# Grade on what the Percy SDK logged, not on the Maestro pass/fail: a flow can
# pass while its snapshots never reach Percy.
LOGS=""
for SESSION_ID in $(jq -r '.devices[].sessions[].id' <<<"$BUILD_JSON"); do
  SESSION_JSON=$(bs "$MAESTRO_API/builds/$BUILD_ID/sessions/$SESSION_ID")
  while IFS=$'\t' read -r NAME TC_STATUS LOG_URL; do
    echo "    flow $NAME: $TC_STATUS"
    [ -n "$LOG_URL" ] && LOGS+=$(curl -sS -L -u "$AUTH" "$LOG_URL")$'\n'
  done < <(jq -r '.testcases.data[].testcases[] | [.name, .status, (.maestro_log // "")] | @tsv' <<<"$SESSION_JSON")
done

RAN_VERSION=$(grep -a -o -m1 -E 'Maestro Version: [0-9.]+' <<<"$LOGS" || true)
echo "    ${RAN_VERSION:-Maestro Version: <not found in logs>}"

UPLOADED=$(grep -a -o -E "\[percy\] (Done: .*snapshot\[name\]=[A-Za-z0-9_-]+|Screenshot '[A-Za-z0-9_-]+' uploaded)" <<<"$LOGS" \
  | sed -E "s/.*snapshot\[name\]=//; s/.*Screenshot '([^']+)'.*/\1/" | sort -u || true)
UPLOADED_COUNT=$(grep -c . <<<"$UPLOADED" || true)
PERCY_ERRORS=$(grep -a -o -E '\[percy\] (Upload failed|Error|DISABLED|SKIPPED)[^"\\]*' <<<"$LOGS" | sort -u || true)
PERCY_BUILD_ID=$(grep -a -o -m1 -E 'build_id=[0-9]+' <<<"$LOGS" | cut -d= -f2 || true)

echo "==> Snapshots uploaded to Percy: $UPLOADED_COUNT/$EXPECTED_SNAPSHOTS"
[ -n "$UPLOADED" ] && sed 's/^/    - /' <<<"$UPLOADED"
if [ -n "$PERCY_ERRORS" ]; then
  echo "==> Percy SDK errors:"
  sed 's/^/    /' <<<"$PERCY_ERRORS"
fi

if [ "$STATUS" != "passed" ] || [ "$UPLOADED_COUNT" -ne "$EXPECTED_SNAPSHOTS" ] || [ -n "$PERCY_ERRORS" ]; then
  echo "FAIL: Percy Maestro smoke test on Maestro ${MAESTRO_VERSION:-default} (BrowserStack build $BUILD_ID)" >&2
  exit 1
fi

[ -n "$PERCY_BUILD_ID" ] && echo "PERCY_BUILD_ID=$PERCY_BUILD_ID"
echo "PASS: Percy Maestro smoke test on Maestro ${MAESTRO_VERSION:-default}"
