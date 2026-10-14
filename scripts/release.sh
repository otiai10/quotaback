#!/bin/sh
# Build a notarized dist/Quotaback-<version>.zip for distribution: sign with Developer ID (bundle.sh),
# notarize, staple, and zip the stapled app. Prints the sha256 for the Homebrew cask.
#
# VERSION defaults to the v1.2.3 tag on HEAD, else the latest v*.*.* tag with the patch bumped (0.1.0 when
# there is none). After a successful build, HEAD is tagged v<version> locally (push it yourself). Notarization uses the keychain profile
# NOTARY_PROFILE (default "quotaback-notary", made with `xcrun notarytool store-credentials`), or an
# App Store Connect API key from NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER (for CI)
set -eu
cd "$(dirname "$0")/.."

git fetch --tags --quiet origin 2>/dev/null || echo "release: couldn't fetch tags; using local ones" >&2
if [ -z "${VERSION:-}" ]; then
    HEAD_TAG="$(git tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n 1)"
    LATEST="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n 1)"
    if [ -n "$HEAD_TAG" ]; then
        VERSION="${HEAD_TAG#v}"
    elif [ -n "$LATEST" ]; then
        VERSION="$(echo "${LATEST#v}" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')"
    else
        VERSION=0.1.0
    fi
    echo "release: version $VERSION (latest tag: ${LATEST:-none})"
fi
if ! echo "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "release: VERSION must look like 1.2.3 (got '$VERSION')" >&2
    exit 1
fi
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    && [ "$(git rev-list -n 1 "$TAG")" != "$(git rev-parse HEAD)" ]; then
    echo "release: $TAG already exists on another commit" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "release: the working tree has uncommitted changes" >&2
    exit 1
fi

if [ "${SIGN_IDENTITY:-}" = "-" ]; then
    echo "release: needs a Developer ID identity, not ad-hoc" >&2
    exit 1
fi
VERSION="$VERSION" ./scripts/bundle.sh
APP=dist/Quotaback.app
codesign -dvv "$APP" 2>&1 | grep -q '^Authority=Developer ID Application:' \
    || { echo "release: $APP is not signed with a Developer ID Application identity" >&2; exit 1; }

if [ -n "${NOTARY_KEY:-}" ]; then
    set -- --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}"
else
    set -- --keychain-profile "${NOTARY_PROFILE:-quotaback-notary}"
fi

# notarytool takes a zip; the app inside is what gets the ticket
UPLOAD=dist/Quotaback-upload.zip
rm -f "$UPLOAD"
ditto -c -k --keepParent "$APP" "$UPLOAD"
xcrun notarytool submit "$UPLOAD" "$@" --wait --output-format json > dist/notarize.json \
    || { cat dist/notarize.json >&2; exit 1; }
rm -f "$UPLOAD"
STATUS="$(plutil -extract status raw dist/notarize.json)"
if [ "$STATUS" != "Accepted" ]; then
    ID="$(plutil -extract id raw dist/notarize.json)"
    echo "release: notarization $STATUS. Log:" >&2
    xcrun notarytool log "$ID" "$@" >&2 || true
    exit 1
fi

xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

ZIP="dist/Quotaback-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "built $ZIP (notarized)"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -a "$TAG" -m "Quotaback $VERSION"
    echo "tagged $TAG (not pushed: git push origin $TAG)"
fi
echo "sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
