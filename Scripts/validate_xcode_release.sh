#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="${CPA_PROJECT:-CPA-IOS.xcodeproj}"
SCHEME="${CPA_SCHEME:-CPA-IOS}"
SIMULATOR_DESTINATION="${CPA_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
ARCHIVE_PATH="${CPA_ARCHIVE_PATH:-$ROOT_DIR/CPA-IOS.xcarchive}"
DERIVED_DATA_PATH="${CPA_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived-data}"
PROJECT_FILE="$PROJECT/project.pbxproj"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

require_full_xcode() {
  if ! xcodebuild -version >/dev/null 2>&1; then
    printf 'error: xcodebuild requires full Xcode. Current developer directory: ' >&2
    xcode-select -p >&2 || true
    exit 1
  fi
  run xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
  run xcrun --sdk iphoneos --show-sdk-path >/dev/null
}

checked_in_development_team() {
  if [[ ! -f "$PROJECT_FILE" ]]; then
    return 0
  fi
  awk -F= '/DEVELOPMENT_TEAM = / {
    gsub(/[ ;"]/, "", $2)
    if ($2 != "") {
      print $2
      exit
    }
  }' "$PROJECT_FILE"
}

require_signing_team_for_archive() {
  if [[ "${CPA_SKIP_ARCHIVE:-0}" == "1" ]]; then
    return
  fi
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    return
  fi
  if [[ -n "$(checked_in_development_team)" ]]; then
    return
  fi
  cat >&2 <<'EOF'
error: DEVELOPMENT_TEAM is required for the Release archive.
Run, for example:
  DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh
If you only need the simulator gate, set CPA_SKIP_ARCHIVE=1.
EOF
  exit 1
}

build_settings=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  build_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${CPA_PRODUCT_BUNDLE_IDENTIFIER:-}" ]]; then
  build_settings+=("PRODUCT_BUNDLE_IDENTIFIER=$CPA_PRODUCT_BUNDLE_IDENTIFIER")
fi

xcode_common_args=()
if [[ "${CPA_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  xcode_common_args+=("-allowProvisioningUpdates")
fi

run Scripts/validate_local.sh
require_full_xcode
require_signing_team_for_archive

run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$SIMULATOR_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH/simulator" \
  "${xcode_common_args[@]}" \
  "${build_settings[@]}" \
  build

if [[ "${CPA_SKIP_ARCHIVE:-0}" == "1" ]]; then
  printf '\n==> archive skipped\n'
  printf 'CPA_SKIP_ARCHIVE=1 was set. Run without it before App Store upload.\n'
else
  rm -rf "$ARCHIVE_PATH"
  run xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH/archive" \
    "${xcode_common_args[@]}" \
    "${build_settings[@]}" \
    archive
  test -d "$ARCHIVE_PATH"
fi
