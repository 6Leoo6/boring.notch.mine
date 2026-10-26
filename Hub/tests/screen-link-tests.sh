#!/usr/bin/env bash
# Runs the hubcast encoder-link tests (HubScreenLink.swift is Foundation only).
# macOS: swiftc. Elsewhere: the swift Docker image.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
cp "$root/boringNotch/Hub/HubScreenLink.swift" "$out/HubScreenLink.swift"
cp "$root/Hub/tests/screen-link-tests.swift" "$out/main.swift"
if command -v swiftc >/dev/null; then
  swiftc -O "$out/HubScreenLink.swift" "$out/main.swift" -o "$out/tests" && "$out/tests"
else
  docker run --rm -v "$out:/t" -w /t "${SWIFT_IMAGE:-swift:6.1}" \
    sh -c 'swiftc HubScreenLink.swift main.swift -o tests && ./tests'
fi
