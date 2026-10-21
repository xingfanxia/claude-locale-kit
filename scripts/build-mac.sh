#!/bin/sh
# Builds "dist/Claude Locale Kit.app" (the SwiftUI app with the claude-locale CLI inside),
# a standalone dist/claude-locale, and dist/claude-locale-kit-mac-<version>.zip.
# Ad-hoc signed only: not notarized. Needs Xcode (for xcstringstool), not just the CLT.
#
# Like an Xcode build, this syncs mac/Resources/Localizable.xcstrings with the strings the
# compiler finds in the sources (new keys added, removed ones marked stale). Commit the result.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' package.json)
if [ -z "$version" ]; then
    echo "build-mac: could not read the version from package.json" >&2
    exit 1
fi

catalog=mac/Resources/Localizable.xcstrings
strings_dir="$root/mac/.build/localized-strings"
mkdir -p "$strings_dir"

swift build -c release --package-path mac \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$strings_dir"
bin=$(swift build -c release --package-path mac --show-bin-path)

xcrun xcstringstool sync "$catalog" --stringsdata "$strings_dir"/*.stringsdata

app="dist/Claude Locale Kit.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/en.lproj"
cp "$bin/ClaudeLocaleKit" "$bin/claude-locale" "$app/Contents/MacOS/"
cp mac/Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
# Source-language keys are the English text, so en.lproj stays empty until the catalog has
# translations; each translated language compiles into its own <lang>.lproj here.
xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"

cp "$bin/claude-locale" dist/claude-locale
codesign --force --sign - dist/claude-locale
# Inner executable first, then the bundle (which seals Info.plist and Resources).
codesign --force --sign - "$app/Contents/MacOS/claude-locale"
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

zip="dist/claude-locale-kit-mac-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "Built $app"
echo "Built dist/claude-locale"
echo "Built $zip"
