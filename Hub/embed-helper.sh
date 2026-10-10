#!/bin/zsh
# Build phase "Embed hub helper": puts towerbridge (the hub helper, 6Leoo6/hub D-128)
# into the app as Contents/Helpers/HubHelper.app, adds its LaunchAgent plist, and signs
# it with the app's identity. HubHelper.swift registers it with SMAppService.
# No binary available -> a warning, and the app builds without the helper.
#
# Why a bundle and a sandbox: SMAppService only registers a sandboxed helper for a
# sandboxed app, and a sandboxed executable needs a bundle identifier in its signature
# (an Info.plist), which a bare Go binary doesn't have.
#
# Where the binary comes from, first match wins:
#   $HUB_TOWERBRIDGE, $SRCROOT/Hub/bin/towerbridge (gitignored), ~/.local/share/hub-dev/bin/towerbridge
# Build it on the tower with `make build` (dist/towerbridge-darwin-arm64) and copy it to one of these.
#
# Variant: release (the owner's signed builds) or dev. Dev builds carry the helper as
# Helpers/HubHelperDev.app with bundle id and label io.github.leoo6.hub.helper.dev, listening
# on 127.0.0.1:47822, so they get their own sandbox container and LaunchAgent and never touch
# the release helper's (macOS stops a differently signed helper at its container with an
# "differs from previously opened versions" prompt). Dev is chosen by HUB_HELPER_VARIANT=dev
# (the hub repo's `mac notch build` sets it) and is the default for ad-hoc signed builds;
# HUB_HELPER_VARIANT=release forces the release layout.
set -euo pipefail

src=""
for c in "${HUB_TOWERBRIDGE:-}" "$SRCROOT/Hub/bin/towerbridge" "$HOME/.local/share/hub-dev/bin/towerbridge"; do
  [[ -n $c && -x $c ]] && { src=$c; break; }
done

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z $identity ]] && identity=-
variant="${HUB_HELPER_VARIANT:-}"
[[ -z $variant ]] && { [[ $identity == - ]] && variant=dev || variant=release; }
case $variant in
  release) label=io.github.leoo6.hub.helper;     bundle_name=HubHelper.app ;;
  dev)     label=io.github.leoo6.hub.helper.dev; bundle_name=HubHelperDev.app ;;
  *) echo "error: HUB_HELPER_VARIANT must be release or dev, not '$variant'"; exit 1 ;;
esac

contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
bundle="$contents/Helpers/$bundle_name"
agent="$contents/Library/LaunchAgents/$label.plist"
rm -rf "$contents/Helpers/HubHelper.app" "$contents/Helpers/HubHelperDev.app" "$contents/Helpers/towerbridge" \
  "$contents/Library/LaunchAgents/io.github.leoo6.hub.helper.plist" "$contents/Library/LaunchAgents/io.github.leoo6.hub.helper.dev.plist"

if [[ -z $src ]]; then
  echo "warning: hub helper not embedded: no towerbridge binary (see Hub/embed-helper.sh). The app works without it; this Mac just won't join the hub."
  exit 0
fi

version=$("$src" version 2>/dev/null | awk '{print $NF; exit}')
bundle_version=${version#v}
[[ $bundle_version =~ '^[0-9]+(\.[0-9]+)*$' ]] || bundle_version=0   # dev builds: 0
mkdir -p "$bundle/Contents/MacOS" "${agent:h}"
cp -f "$src" "$bundle/Contents/MacOS/towerbridge"
chmod 755 "$bundle/Contents/MacOS/towerbridge"
cp -f "$SRCROOT/Hub/HubHelper-Info.plist" "$bundle/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$bundle_version" "$bundle/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$bundle_version" "$bundle/Contents/Info.plist"
cp -f "$SRCROOT/Hub/io.github.leoo6.hub.helper.plist" "$agent"
if [[ $variant == dev ]]; then
  plutil -replace CFBundleIdentifier -string "$label" "$bundle/Contents/Info.plist"
  plutil -replace CFBundleName -string "hub helper (dev)" "$bundle/Contents/Info.plist"
  plutil -replace Label -string "$label" "$agent"
  plutil -replace BundleProgram -string "Contents/Helpers/$bundle_name/Contents/MacOS/towerbridge" "$agent"
  plutil -replace ProgramArguments -json '["towerbridge","serve","--listen","127.0.0.1:47822"]' "$agent"
fi

codesign --force --options runtime --timestamp=none --sign "$identity" \
  --entitlements "$SRCROOT/Hub/helper.entitlements" "$bundle"
echo "hub helper ${version:-?} ($variant, $label) embedded from $src, signed with $identity"
