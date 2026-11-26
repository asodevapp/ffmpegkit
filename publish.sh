#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (c) 2026 ASO.dev
# Publishes verified build.sh archives as the GitHub release FFKIT_RELEASE (release.env) of this repository, together
# with the corresponding source: this recipe and every source tree locked in sources.lock. Prints the SHA-256 of each
# archive for the app that pins them.
#
# Usage: GITHUB_TOKEN=<token that may write releases> ./publish.sh <archive.zip>...
#   The platform is read from the archive name (macos, linux, windows). An existing asset is never replaced: apps pin
#   archives by SHA-256, so a changed archive needs a new FFKIT_RELEASE.
set -euo pipefail

TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FFKIT_HOME=${FFKIT_HOME:-$HOME/.cache/asodev-ffmpegkit}
REPO=${FFKIT_GITHUB_REPO:-asodevapp/ffmpegkit}
# shellcheck source=release.env
source "$TOOL_DIR/release.env"

die() { echo "publish.sh: $*" >&2; exit 1; }
[[ -n ${GITHUB_TOKEN:-} ]] || die "set GITHUB_TOKEN"
(($#)) || die "usage: publish.sh <archive.zip>..."

api() { # method path [curl args...] -> response body
  local method=$1 path=$2
  shift 2
  curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$@" "$path"
}

json() { python3 -I -c "import json, sys; print(json.load(sys.stdin)$1)"; }

release_id() { # the release of FFKIT_RELEASE, created on the current commit of main when missing
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$REPO/releases/tags/$FFKIT_RELEASE")
  if [[ $status == 404 ]]; then
    api POST "https://api.github.com/repos/$REPO/releases" -d "$(python3 -I -c '
import json, sys
release = sys.argv[1]
print(json.dumps({
    "tag_name": release,
    "target_commitish": "main",
    "name": f"FFmpegKit {release}",
    "body": f"libffmpegkit for macOS (universal), Linux and Windows (x86_64), built by this recipe at this tag. "
            f"ffmpegkit-{release}-source.tar.xz is the corresponding source: the recipe and every locked source tree.",
}))' "$FFKIT_RELEASE")" | json "['id']"
  else
    api GET "https://api.github.com/repos/$REPO/releases/tags/$FFKIT_RELEASE" | json "['id']"
  fi
}

upload() { # release-id file
  local id=$1 file=$2 name
  name=$(basename "$file")
  if api GET "https://api.github.com/repos/$REPO/releases/$id/assets?per_page=100" |
    python3 -I -c "import json, sys; sys.exit(0 if sys.argv[1] in [a['name'] for a in json.load(sys.stdin)] else 1)" \
      "$name"; then
    die "$name is already in release $FFKIT_RELEASE; bump FFKIT_RELEASE instead of replacing a pinned archive"
  fi
  api POST "https://uploads.github.com/repos/$REPO/releases/$id/assets?name=$name" \
    -H 'Content-Type: application/octet-stream' --data-binary "@$file" >/dev/null
}

source_archive() { # -> path of the corresponding-source tarball
  local stage=$FFKIT_HOME/build/$FFKIT_RELEASE/source name=ffmpegkit-$FFKIT_RELEASE-source out entry dir commit
  out=$FFKIT_HOME/out/$name.tar.xz
  "$TOOL_DIR/build.sh" sources
  rm -rf "$stage"
  mkdir -p "$stage/$name/sources" "$stage/$name/recipe"
  (cd "$TOOL_DIR" && tar --exclude=.git -cf - .) | tar -xf - -C "$stage/$name/recipe"
  while read -r entry _ commit _; do
    [[ -z $entry || $entry == \#* ]] && continue
    dir=$FFKIT_HOME/src/$entry-$commit
    git -C "$dir" archive --prefix="$entry/" HEAD | tar -xf - -C "$stage/$name/sources"
  done <"$TOOL_DIR/sources.lock"
  tar -cJf "$out" -C "$stage" "$name"
  echo "$out"
}

files=()
for archive in "$@"; do
  case $(basename "$archive") in
    *-macos-*) platform=macos ;;
    *-linux-*) platform=linux ;;
    *-windows-*) platform=windows ;;
    *) die "cannot tell the platform of $archive" ;;
  esac
  [[ $(basename "$archive") == ffmpegkit-$FFKIT_RELEASE-* ]] || die "$archive is not release $FFKIT_RELEASE"
  "$TOOL_DIR/verify.sh" "$archive" "$platform" >/dev/null
  files+=("$archive")
done

id=$(release_id)
for archive in "${files[@]}"; do
  upload "$id" "$archive"
done
upload "$id" "$(source_archive)"

echo "Published https://github.com/$REPO/releases/tag/$FFKIT_RELEASE"
for archive in "${files[@]}"; do
  echo "$(basename "$archive")  $(shasum -a 256 "$archive" | cut -d' ' -f1)"
done
