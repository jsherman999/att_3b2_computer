#!/bin/sh
# Fail if a vendored checkout has changes that patches/ does not reproduce.
# Usage: scripts/check-patches.sh [--write NAME]
#   --write NAME  save SIMH's unrecorded changes as patches/NAME first
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check REPO PATCH-GLOB LABEL [PATHS...]: pristine HEAD + patches must equal the
# working tree (limited to PATHS when given).
check() {
  repo=$1; glob=$2; label=$3; shift 3
  git -C "$repo" worktree add -q --detach "$TMP/$label" HEAD
  for p in $glob; do
    [ -e "$p" ] || continue
    git -C "$TMP/$label" apply "$p" || { echo "$label: $p does not apply" >&2; exit 1; }
  done
  git -C "$TMP/$label" diff -- "$@" > "$TMP/$label.expected"
  git -C "$repo" diff -- "$@" > "$TMP/$label.actual"
  git -C "$repo" worktree remove --force "$TMP/$label"
  if ! cmp -s "$TMP/$label.expected" "$TMP/$label.actual"; then
    echo "$label: working tree has changes not recorded in patches/:" >&2
    diff "$TMP/$label.expected" "$TMP/$label.actual" | grep '^[<>] [-+]' | head -20 >&2
    return 1
  fi
  echo "$label: patches reproduce the working tree"
}

if [ "$1" = "--write" ] && [ -n "$2" ]; then
  # Record the difference between (pristine + existing patches) and the working tree.
  git -C "$ROOT/vendor/simh" worktree add -q --detach "$TMP/base" HEAD
  for p in "$ROOT"/patches/[0-9]*.patch; do git -C "$TMP/base" apply "$p"; done
  git -C "$TMP/base" add -A >/dev/null
  git -C "$TMP/base" -c user.email=x -c user.name=x commit -qm base
  for f in $(git -C "$ROOT/vendor/simh" diff --name-only); do cp "$ROOT/vendor/simh/$f" "$TMP/base/$f"; done
  git -C "$TMP/base" diff > "$ROOT/patches/$2"
  git -C "$ROOT/vendor/simh" worktree remove --force "$TMP/base"
  echo "wrote patches/$2"
fi

status=0
check "$ROOT/vendor/simh" "$ROOT/patches/[0-9]*.patch" simh || status=1
[ -d "$ROOT/vendor/dmd_core" ] && { check "$ROOT/vendor/dmd_core" "$ROOT/patches/dmd_core-*.patch" dmd_core || status=1; }
[ -d "$ROOT/vendor/dmd-layers" ] && { check "$ROOT/vendor/dmd-layers" "$ROOT/patches/dmd-layers-*.patch" dmd-layers || status=1; }
# freesdp630: only the host tools we patch (case-colliding files show as changed on macOS)
[ -d "$ROOT/vendor/freesdp630" ] && { check "$ROOT/vendor/freesdp630" "$ROOT/patches/freesdp630-*.patch" freesdp630 dmdld jx dmdversion loadfont || status=1; }
exit $status
