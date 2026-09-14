#!/usr/bin/env bash
#
# Build, test and package SheepTun.
#
#   ./build.sh test                 Run the unit tests
#   ./build.sh build [debug|release] Compile without packaging
#   ./build.sh release              Test, archive, sign, verify and package
#   ./build.sh clean                Remove build/
#
# Options for `release`:
#   --no-test          Skip the test run
#   --dmg              Also build a .dmg (needs: brew install create-dmg)
#   --identity <id>    codesign identity; default "-" (ad hoc)
#
# Everything is written to build/, which is gitignored.
#
# Note on signing: the app is re-signed with the entitlements extracted from the
# archived bundle. Signing without them silently strips App Sandbox, microphone
# and network access, which is why this script verifies them afterwards.

set -euo pipefail

readonly PROJECT="sheeptun.xcodeproj"
readonly SCHEME="sheeptun"
readonly APP_NAME="SheepTun"
readonly REQUIRED_ENTITLEMENTS=(
    "com.apple.security.app-sandbox"
    "com.apple.security.device.audio-input"
    "com.apple.security.network.client"
)

cd "$(dirname "${BASH_SOURCE[0]}")"
readonly BUILD_DIR="$PWD/build"
readonly LOG_DIR="$BUILD_DIR/logs"
readonly DIST_DIR="$BUILD_DIR/dist"
readonly ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"

IDENTITY="-"
RUN_TESTS=1
MAKE_DMG=0

step() { printf '\033[1m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Runs a noisy command into build/logs/<name>.log and only surfaces it on failure.
logged() {
    local name="$1"
    shift
    local log="$LOG_DIR/$name.log"
    mkdir -p "$LOG_DIR"
    if ! "$@" >"$log" 2>&1; then
        printf '\033[31merror:\033[0m %s failed; last 40 lines of %s:\n' "$name" "$log" >&2
        tail -40 "$log" >&2
        exit 1
    fi
}

marketing_version() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -showBuildSettings 2>/dev/null |
        awk -F' = ' '/ MARKETING_VERSION = /{gsub(/ /,"",$2); print $2; exit}'
}

cmd_test() {
    step "Running unit tests"
    logged test xcodebuild test \
        -project "$PROJECT" -scheme "$SCHEME" \
        -destination 'platform=macOS' \
        -only-testing:sheeptunTests
    local passed
    passed=$(grep -c '^Test case .* passed on' "$LOG_DIR/test.log" || true)
    info "$passed tests passed"
}

cmd_build() {
    local config="${1:-Debug}"
    case "$(printf '%s' "$config" | tr '[:upper:]' '[:lower:]')" in
        debug) config="Debug" ;;
        release) config="Release" ;;
        *) die "unknown configuration: $config" ;;
    esac
    step "Building ($config)"
    logged "build-$config" xcodebuild build \
        -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$config" -destination 'platform=macOS'
    info "build succeeded"
}

archive() {
    step "Archiving (Release)"
    rm -rf "$ARCHIVE_PATH"
    logged archive xcodebuild archive \
        -project "$PROJECT" -scheme "$SCHEME" \
        -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates
    info "$(basename "$ARCHIVE_PATH")"
}

# Pulls the .app straight out of the archive: Organizer's Direct Distribution flow
# needs a paid Developer ID certificate, which this project does not use.
extract_app() {
    step "Extracting the app from the archive"
    local src
    src=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
    [[ -n "$src" ]] || die "no .app found inside $ARCHIVE_PATH"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    ditto "$src" "$DIST_DIR/$APP_NAME.app"
    info "$(basename "$src") → $APP_NAME.app"
}

sign_app() {
    local app="$DIST_DIR/$APP_NAME.app"
    local ents="$BUILD_DIR/$APP_NAME.entitlements"
    step "Re-signing (identity: $IDENTITY)"

    rm -f "$ents"
    codesign -d --entitlements "$ents" --xml "$app" 2>/dev/null ||
        die "could not read the entitlements of the archived app"
    grep -q "app-sandbox" "$ents" ||
        die "the archived app carries no sandbox entitlement — check ENABLE_APP_SANDBOX"
    info "entitlements saved to $(basename "$ents")"

    # Nested code first: --deep is not a dependable way to sign an app for distribution.
    if [[ -d "$app/Contents/Frameworks" ]]; then
        while IFS= read -r -d '' nested; do
            codesign --force --options runtime -s "$IDENTITY" "$nested" >/dev/null 2>&1 ||
                die "failed to sign $(basename "$nested")"
            info "signed $(basename "$nested")"
        done < <(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
    fi

    codesign --force --options runtime --entitlements "$ents" -s "$IDENTITY" "$app" >/dev/null 2>&1 ||
        die "failed to sign $APP_NAME.app"
    info "signed $APP_NAME.app"
}

verify_app() {
    local app="$DIST_DIR/$APP_NAME.app"
    step "Verifying signature and entitlements"
    codesign --verify --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /'

    local dump
    dump=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
    for key in "${REQUIRED_ENTITLEMENTS[@]}"; do
        grep -q "$key" <<<"$dump" || die "entitlement lost while signing: $key"
        info "$key ✓"
    done

    # Expected to be rejected: the app is not notarized. Informational only.
    local verdict
    verdict=$(spctl -a -vvv "$app" 2>&1 || true)
    info "spctl: $(tail -1 <<<"$verdict")"
}

package() {
    local version="$1"
    local app="$DIST_DIR/$APP_NAME.app"
    step "Packaging"

    local zip="$DIST_DIR/$APP_NAME-$version.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    info "$(basename "$zip") ($(du -h "$zip" | cut -f1 | tr -d ' '))"

    if ((MAKE_DMG)); then
        command -v create-dmg >/dev/null ||
            die "create-dmg is not installed (brew install create-dmg)"
        local dmg="$DIST_DIR/$APP_NAME-$version.dmg"
        rm -f "$dmg"
        logged create-dmg create-dmg \
            --volname "$APP_NAME" \
            --app-drop-link 450 120 \
            "$dmg" "$app"
        info "$(basename "$dmg") ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
    fi
}

cmd_release() {
    local version
    version=$(marketing_version)
    [[ -n "$version" ]] || die "could not read MARKETING_VERSION from $PROJECT"
    step "Releasing $APP_NAME $version"

    if ((RUN_TESTS)); then
        cmd_test
    else
        info "tests skipped (--no-test)"
    fi
    archive
    extract_app
    sign_app
    verify_app
    package "$version"

    step "Done"
    info "$DIST_DIR"
    info "Publish with: gh release create v$version $DIST_DIR/$APP_NAME-$version.zip --title v$version"
}

cmd_clean() {
    step "Cleaning"
    rm -rf "$BUILD_DIR"
    info "removed build/"
}

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"

cmd="${1:-release}"
shift || true
config_arg=""

while (($#)); do
    case "$1" in
        --no-test) RUN_TESTS=0 ;;
        --dmg) MAKE_DMG=1 ;;
        --identity)
            IDENTITY="${2:-}"
            [[ -n "$IDENTITY" ]] || die "--identity needs a value"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        debug | release | Debug | Release) config_arg="$1" ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$cmd" in
    test) cmd_test ;;
    build) cmd_build "${config_arg:-debug}" ;;
    release) cmd_release ;;
    clean) cmd_clean ;;
    -h | --help | help)
        usage
        exit 0
        ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac
