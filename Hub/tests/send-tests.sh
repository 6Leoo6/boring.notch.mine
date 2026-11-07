#!/usr/bin/env bash
# Runs the hub send tests (HubSendCore.swift is Foundation only) against a fake helper.
# macOS: swiftc. Elsewhere: the swift Docker image.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
cp "$root/boringNotch/Hub/HubSendCore.swift" "$out/HubSendCore.swift"
cp "$root/Hub/tests/send-tests.swift" "$out/main.swift"
if command -v swiftc >/dev/null; then
  swiftc "$out/HubSendCore.swift" "$out/main.swift" -o "$out/tests" && "$out/tests"
else
  docker run --rm -v "$out:/t" -w /t "${SWIFT_IMAGE:-swift:6.1}" \
    sh -c 'swiftc HubSendCore.swift main.swift -o tests && ./tests'
fi
