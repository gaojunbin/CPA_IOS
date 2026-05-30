#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run swift build
run swift run CPAKitValidation
run swiftc -swift-version 6 -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
run swiftc -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
run bash -n Scripts/validate_local.sh Scripts/validate_xcode_release.sh
run git diff --check
run plutil -lint App/Info.plist App/PrivacyInfo.xcprivacy CPA-IOS.xcodeproj/project.pbxproj
run xmllint --noout CPA-IOS.xcodeproj/xcshareddata/xcschemes/CPA-IOS.xcscheme

if command -v jq >/dev/null 2>&1; then
  printf '\n==> validate asset catalog JSON\n'
  find App/Assets.xcassets -name Contents.json -print0 | xargs -0 jq empty
else
  printf '\nwarning: jq is not installed; skipping asset catalog JSON validation\n' >&2
fi

if [[ "${CPA_VALIDATE_XCODE:-0}" == "1" ]]; then
  run xcodebuild -project CPA-IOS.xcodeproj -scheme CPA-IOS -destination 'platform=iOS Simulator,name=iPhone 16' build
else
  printf '\n==> Xcode iOS build skipped\n'
  printf 'Set CPA_VALIDATE_XCODE=1 on a full Xcode machine to run the simulator build gate.\n'
fi
