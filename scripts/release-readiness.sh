#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/pressay-release-readiness.XXXXXX")"

cleanup() {
  rm -rf "$derived_data"
}
trap cleanup EXIT

echo "1/7 · Validation des fichiers Apple"
plutil -lint \
  "$project_root/Pressay/Info.plist" \
  "$project_root/Pressay/Info-AppStore.plist" \
  "$project_root/Pressay/PrivacyInfo.xcprivacy" \
  "$project_root/Pressay/Pressay.entitlements" \
  "$project_root/Pressay/PressayAppStore.entitlements" \
  "$project_root/Pressay/ExportOptions-AppStore.plist"

echo "2/7 · Validation de version directe"
"$project_root/scripts/validate-release.sh"

echo "3/7 · Tests Swift"
xcodebuild test \
  -quiet \
  -project "$project_root/Pressay.xcodeproj" \
  -scheme Pressay \
  -configuration Debug \
  -destination 'platform=macOS'

echo "4/7 · Build Release direct universel"
xcodebuild build \
  -quiet \
  -project "$project_root/Pressay.xcodeproj" \
  -scheme Pressay \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data/direct" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO

direct_app="$derived_data/direct/Build/Products/Release/Pressay.app"
direct_binary="$direct_app/Contents/MacOS/Pressay"
[[ -x "$direct_binary" ]] || {
  echo "Le build direct Release est absent." >&2
  exit 1
}
direct_architectures="$(lipo -archs "$direct_binary")"
[[ "$direct_architectures" == *arm64* && "$direct_architectures" == *x86_64* ]] || {
  echo "Le build direct n'est pas universel: $direct_architectures" >&2
  exit 1
}
[[ -d "$direct_app/Contents/Frameworks/Sparkle.framework" ]] || {
  echo "Sparkle est absent du canal direct." >&2
  exit 1
}
[[ -f "$direct_app/Contents/Resources/PrivacyInfo.xcprivacy" ]] || {
  echo "Le manifeste de confidentialité est absent du canal direct." >&2
  exit 1
}

echo "5/7 · Build et politique Mac App Store"
"$project_root/scripts/validate-app-store.sh"

echo "6/7 · Métadonnées et captures Mac App Store"
metadata="$project_root/AppStoreAssets/Metadata/up-6795505605/MACOS/fr-FR.txt"
[[ -s "$metadata" ]] || {
  echo "Les métadonnées françaises sont absentes." >&2
  exit 1
}
screenshots=("$project_root"/AppStoreAssets/Screenshots/Final/*.png)
(( ${#screenshots[@]} >= 1 && ${#screenshots[@]} <= 10 )) || {
  echo "Apple exige entre 1 et 10 captures macOS." >&2
  exit 1
}
for screenshot in "${screenshots[@]}"; do
  width="$(sips -g pixelWidth "$screenshot" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$screenshot" | awk '/pixelHeight/ { print $2 }')"
  alpha="$(sips -g hasAlpha "$screenshot" | awk '/hasAlpha/ { print $2 }')"
  [[ "$width" == "1440" && "$height" == "900" && "$alpha" == "no" ]] || {
    echo "Capture invalide: $screenshot ($width x $height, alpha=$alpha)" >&2
    exit 1
  }
done

echo "7/7 · Scripts de distribution"
zsh -n \
  "$project_root/scripts/archive-app-store.sh" \
  "$project_root/scripts/notarize.sh" \
  "$project_root/scripts/release-readiness.sh" \
  "$project_root/scripts/validate-app-store.sh" \
  "$project_root/scripts/validate-release.sh"
python3 "$project_root/scripts/test-latest-appcast-build.py"
python3 "$project_root/scripts/test-merge-appcast.py"
python3 -m py_compile "$project_root/scripts/verify-public-appcast.py"

echo "Pressay est techniquement prête pour les validations manuelles de publication."
echo "Direct: 1.2.8 (12107), $direct_architectures"
echo "Mac App Store: 1.2.0 (12005), validation sandbox universelle réussie"
