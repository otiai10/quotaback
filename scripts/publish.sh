#!/bin/sh
# Publish what `make release` built: push the v<version> tag, create the GitHub release with
# dist/Quotaback-<version>.zip, and bump version/sha256 in the Homebrew cask (otiai10/homebrew-tap).
# Uses your own git and gh credentials. Steps already done are skipped, so it can be re-run.
#
# VERSION defaults to the v1.2.3 tag on HEAD (what `make release` just tagged)
set -eu
cd "$(dirname "$0")/.."

REPO=otiai10/quotaback
TAP_REPO=otiai10/homebrew-tap
CASK=Casks/quotaback.rb

if [ -z "${VERSION:-}" ]; then
    HEAD_TAG="$(git tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n 1)"
    [ -n "$HEAD_TAG" ] || { echo "publish: HEAD has no v1.2.3 tag; run make release first or set VERSION" >&2; exit 1; }
    VERSION="${HEAD_TAG#v}"
fi
TAG="v$VERSION"
ZIP="dist/Quotaback-$VERSION.zip"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "publish: no local tag $TAG" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "publish: $ZIP not found; run make release" >&2; exit 1; }

# The zip must hold a notarized app with this version
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
[ "$(plutil -extract CFBundleShortVersionString raw "$CHECK/Quotaback.app/Contents/Info.plist")" = "$VERSION" ] \
    || { echo "publish: $ZIP is not version $VERSION" >&2; exit 1; }
xcrun stapler validate -q "$CHECK/Quotaback.app" \
    || { echo "publish: $ZIP is not notarized" >&2; exit 1; }
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "publish: $TAG ($ZIP, sha256 $SHA256)"

# The tagged commit must already be on origin/main, so the tag doesn't publish unpushed work
git fetch --quiet origin
git merge-base --is-ancestor "$TAG^{commit}" origin/main \
    || { echo "publish: $TAG is not on origin/main yet; push main first" >&2; exit 1; }

# 1. Tag
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
    echo "tag: $TAG already pushed"
else
    git push origin "$TAG"
fi

# 2. GitHub release
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "release: $TAG already exists ($(gh release view "$TAG" -R "$REPO" --json url -q .url))"
else
    gh release create "$TAG" "$ZIP" -R "$REPO" --verify-tag --title "Quotaback $VERSION" --generate-notes
fi

# 3. Homebrew cask
TAP="$CHECK/tap"
gh repo clone "$TAP_REPO" "$TAP" -- --quiet --depth 1
sed -i '' -E \
    -e "s/^(  version )\".*\"$/\1\"$VERSION\"/" \
    -e "s/^(  sha256 )\".*\"$/\1\"$SHA256\"/" "$TAP/$CASK"
if git -C "$TAP" diff --quiet; then
    echo "cask: already $VERSION"
else
    git -C "$TAP" diff
    git -C "$TAP" commit --quiet -am "Update quotaback: $VERSION"
    git -C "$TAP" push --quiet origin HEAD
    echo "cask: updated to $VERSION"
fi
echo "published $TAG: brew upgrade --cask otiai10/tap/quotaback"
