#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This packaging script only runs on macOS." >&2
    exit 1
fi

profile="${1:-debug}"
case "$profile" in
    debug)
        cargo build
        ;;
    release)
        cargo build --release
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac

app_dir="target/$profile/Magi.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

rm -rf "$app_dir"
mkdir -p "$macos_dir"
cp "target/$profile/magi" "$macos_dir/magi"
cp "packaging/macos/Info.plist" "$contents_dir/Info.plist"

# Ad-hoc sign so the app launches on Apple Silicon. This is not a Developer ID
# signature: distributed users still clear Gatekeeper once (see README).
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"

if [ "$profile" = "release" ]; then
    zip_path="target/release/Magi-macos.zip"
    rm -f "$zip_path"
    # ditto preserves the bundle structure and code signature inside the zip.
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
    echo "$zip_path"
fi
