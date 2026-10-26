#!/bin/zsh
# One install of boringNotch.app, always (hub D-162). Every build or install of this fork on
# the Mac goes through here, so the Mac never ends up with extra copies that Spotlight,
# Launchpad, "Open With" and Launch Services list as separate installs.
#
#   zsh Hub/notch-install.sh install [--adhoc]   build Release, replace /Applications/boringNotch.app
#   zsh Hub/notch-install.sh build NAME [--adhoc] [--debug] [--dev-helper]   build only (agents)
#   zsh Hub/notch-install.sh clean [--keep]      unregister (and delete) this clone's build products
#   zsh Hub/notch-install.sh rollback            put the previous install back from the archive
#   zsh Hub/notch-install.sh check               exactly one registered copy, in /Applications?
#
# Run it from the clone (any directory inside it). Rules it enforces:
# - Build products live in <clone>/build.noindex/<name> (".noindex": Spotlight skips it). Xcode
#   registers a built app with Launch Services, so every build unregisters its product right away,
#   and install deletes the product once it is copied into /Applications.
# - The previous /Applications/boringNotch.app is kept as ONE archive, newest only:
#   ~/.local/share/boring.notch.mine/previous-app.zip (never a loose .app; LS doesn't look in zips).
# - install and clean end with `check`: `lsregister -dump` may list boringNotch.app only at
#   /Applications/boringNotch.app (plus the helpers inside it), and Spotlight may find no other
#   copy. Anything else fails loudly. Stray copies inside Xcode build products (DerivedData,
#   */Build/Products/*, build.noindex) are unregistered and deleted on the way, since a build
#   recreates them; any other stray copy is unregistered and reported, never deleted.
# - Signing: install signs with the project's identity (needs the login keychain: run it in the
#   Mac's own Terminal). Over SSH pass --adhoc (ad-hoc signature, dev helper variant).
set -euo pipefail

APP=/Applications/boringNotch.app
BUNDLE_ID=boring.notch.mine
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ARCHIVE=${BN_ARCHIVE:-$HOME/.local/share/boring.notch.mine/previous-app.zip}

die() { print -u2 -- "notch-install: $*"; exit 1; }

root=${BN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
need_root() { [[ -n $root && -d $root/boringNotch.xcodeproj ]] || die "run it inside a boring.notch.mine clone (or set BN_ROOT)"; }

quit_notch() {
  # The app ignores SIGTERM: ask it to quit, kill only if it is still there after 5 s.
  osascript -e 'quit app "boringNotch"' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -x boringNotch >/dev/null || return 0; sleep 0.5; done
  pkill -KILL -x boringNotch 2>/dev/null || true
  sleep 0.5
}

# Registered paths of boringNotch.app bundles (and everything inside them), one per line.
registered() {
  $LSR -dump | grep -E '^path:.*boringNotch\.app' | sed -E 's/^path:[[:space:]]+//; s/ \(0x[0-9a-fA-F]+\)$//' || true
}

is_build_product() { [[ $1 == */Build/Products/* || $1 == */build.noindex/* || $1 == */DerivedData/* ]]; }

# The top-level boringNotch.app of a registered path (helpers inside it map to their app).
top_app() { print -r -- "${1%%boringNotch.app*}boringNotch.app"; }

# Unregister an app and every bundle inside it (Updater.app, HubHelper*.app): lsregister -u on the
# app alone leaves the nested ones registered. Works for paths already deleted from disk, too.
unregister() {
  local p
  $LSR -u -R "$1" >/dev/null 2>&1 || true
  for p in "${(@f)$(registered)}"; do
    [[ $p == $1 || $p == $1/* ]] && { $LSR -u "$p" >/dev/null 2>&1 || true; }
  done
  return 0
}

# Unregister every copy outside /Applications; delete it only when it is an Xcode build product.
# Prints the copies it had to leave on disk.
sweep() {
  local p a kept=()
  local -aU apps=()
  for p in "${(@f)$(registered)}"; do
    [[ -z $p || $p == $APP || $p == $APP/* ]] && continue
    apps+=("$(top_app "$p")")
  done
  for p in "${(@f)$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)}"; do
    [[ -z $p || $p == $APP || ! -e $p ]] && continue
    apps+=("$p")
  done
  for a in $apps; do
    unregister "$a"
    if [[ -e $a ]]; then
      if is_build_product "$a"; then rm -rf "$a"; print -- "  removed build product $a"
      else kept+=("$a"); fi
    fi
  done
  (( ${#kept} )) && print -l -- $kept
  return 0
}

# Fails unless exactly one boringNotch.app is registered, at /Applications.
check() {
  local p bad=() top=0 spot=()
  for p in "${(@f)$(registered)}"; do
    [[ -z $p ]] && continue
    if [[ $p == $APP ]]; then (( ++top ))
    elif [[ $p != $APP/* ]]; then bad+=("$p"); fi
  done
  for p in "${(@f)$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)}"; do
    [[ -n $p && $p != $APP && -e $p ]] && spot+=("$p")
  done
  if (( top == 1 && ${#bad} == 0 && ${#spot} == 0 )); then
    print -- "check: one install, $APP (Launch Services and Spotlight agree)"
    return 0
  fi
  print -u2 -- "check: FAILED, boringNotch.app must be registered once, at $APP"
  (( top == 1 )) || print -u2 -- "  $APP is registered $top times"
  (( ${#bad} )) && print -u2 -l -- "  also registered:" "    "${^bad}
  (( ${#spot} )) && print -u2 -l -- "  Spotlight also finds:" "    "${^spot}
  print -u2 -- "  fix: zsh Hub/notch-install.sh clean (build products), move other copies into an archive"
  return 1
}

# build NAME [--adhoc] [--debug] [--dev-helper]: Release (or Debug) into build.noindex/NAME,
# product unregistered. Prints the product path as the last line.
build() {
  need_root
  local name=$1; shift
  local config=Release adhoc=0 variant=""
  for a; do case $a in
    --adhoc) adhoc=1 ;; --debug) config=Debug ;; --dev-helper) variant=dev ;;
    *) die "build: unknown option $a" ;;
  esac; done
  local dd=$root/build.noindex/$name log=$root/build.noindex/$name.log
  local -a extra=()
  (( adhoc )) && extra+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  [[ -n $variant ]] && extra+=(HUB_HELPER_VARIANT=$variant)
  mkdir -p $root/build.noindex
  local rc=0
  (cd $root && xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration $config \
     -derivedDataPath $dd -destination 'platform=macOS' $extra build) >$log 2>&1 || rc=$?
  grep -E '(hub helper|error:|BUILD (SUCCEEDED|FAILED)|The following build commands failed)' $log | sort -u | tail -40 || true
  print -- "full log: $log"
  local product=$dd/Build/Products/$config/boringNotch.app
  [[ -d $product ]] && unregister $product
  (( rc == 0 )) || return $rc
  [[ -d $product ]] || die "no product at $product"
  print -r -- $product
}

archive_current() {
  [[ -d $APP ]] || return 0
  mkdir -p ${ARCHIVE:h}
  rm -f $ARCHIVE.tmp
  ditto -c -k --sequesterRsrc --keepParent $APP $ARCHIVE.tmp
  mv -f $ARCHIVE.tmp $ARCHIVE
  print -- "  previous install archived: $ARCHIVE"
}

# Replace /Applications/boringNotch.app with $1 (an .app dir), then open it.
put_in_place() {
  local src=$1
  quit_notch
  rm -rf $APP
  ditto $src $APP
  $LSR -f $APP >/dev/null 2>&1 || true
}

open_and_confirm() {
  open $APP
  local running=""
  for _ in {1..20}; do
    running=$(ps -o comm= -p "$(pgrep -x boringNotch | head -1)" 2>/dev/null | sed 's|/Contents/MacOS/.*||' || true)
    [[ -n $running ]] && break
    sleep 0.5
  done
  [[ $running == $APP ]] || die "the running notch is '${running:-none}', not $APP"
  print -- "running: $running"
}

finish() {
  local kept
  kept=$(sweep)
  [[ -n $kept ]] && print -u2 -l -- "  copies left on disk (not build products, not deleted):" $kept
  check
}

cmd=${1:-}; (( $# )) && shift
case $cmd in
  install)
    adhoc=()
    for a; do case $a in --adhoc) adhoc=(--adhoc) ;; *) die "install: unknown option $a" ;; esac; done
    need_root
    print -- "1/3 build ($(git -C $root rev-parse --short HEAD), Release${adhoc:+, ad-hoc})"
    out=$(build release $adhoc) || { print -r -- "$out"; die "build failed"; }
    print -r -- "${out%$'\n'*}"
    product=${out##*$'\n'}
    print -- "2/3 install"
    quit_notch
    archive_current
    put_in_place $product
    unregister $product
    rm -rf $product
    open_and_confirm
    print -- "3/3 one install"
    finish ;;
  build)
    (( $# )) || die "usage: build NAME [--adhoc] [--debug] [--dev-helper]"
    build "$@" ;;
  clean)
    need_root
    keep=0; [[ ${1:-} == --keep ]] && keep=1
    for p in $root/build.noindex/*/Build/Products/*/boringNotch.app(N/); do
      unregister $p
      (( keep )) || { rm -rf $p; print -- "  removed $p"; }
    done
    (( keep )) && exit 0
    finish ;;
  rollback)
    [[ -f $ARCHIVE ]] || die "no archive at $ARCHIVE"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/boringNotch-rollback.XXXXXX")
    tmp=$tmp.noindex; mv ${tmp%.noindex} $tmp
    ditto -x -k $ARCHIVE $tmp
    [[ -d $tmp/boringNotch.app ]] || { rm -rf $tmp; die "the archive holds no boringNotch.app"; }
    unregister $tmp/boringNotch.app
    put_in_place $tmp/boringNotch.app
    rm -rf $tmp
    open_and_confirm
    finish ;;
  check)
    check ;;
  ""|-h|--help|help)
    sed -n '2,25p' $0 | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command $cmd (help)" ;;
esac
