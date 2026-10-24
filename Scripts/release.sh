#!/bin/zsh
# Archives the iPhone app in Release and exports it for App Store Connect.
#   Scripts/release.sh            → build/release/ (nothing leaves this Mac)
#   Scripts/release.sh --upload   → the same, then uploads it to App Store Connect (TestFlight)
# Signing and uploading use the Apple Account signed in to Xcode (team W533Y4V578). The app
# record (bundle ID com.svein.newnew) must exist in App Store Connect before the first upload.
set -euo pipefail
cd "${0:A:h}/.."

upload=false
[[ "${1:-}" == "--upload" ]] && upload=true

out=build/release
mkdir -p "$out"
exportOptions="$out/ExportOptions.plist"
cp Distribution/ExportOptions.plist "$exportOptions"
if $upload; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$exportOptions"
fi

# The project folder lives in iCloud Drive, whose file attributes break signing of build output;
# keep derived data outside it.
derived="${TMPDIR:-/tmp}/newnew-release"

xcodegen generate --quiet
echo "▸ Archiving"
xcodebuild archive \
  -project Newnew.xcodeproj -scheme Newnew -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$derived" \
  -archivePath "$out/newnew.xcarchive" -allowProvisioningUpdates -quiet
echo "▸ Exporting"
xcodebuild -exportArchive \
  -archivePath "$out/newnew.xcarchive" -exportPath "$out/iOS" \
  -exportOptionsPlist "$exportOptions" -allowProvisioningUpdates -quiet

if $upload; then
  echo "✓ Uploaded. The build appears in App Store Connect › TestFlight after processing (10–30 min)."
else
  echo "✓ Exported to $out/iOS. Run with --upload to send it to App Store Connect."
fi
