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

# Ad-hoc sign so the local app launches on Apple Silicon. This is never a
# public release artifact.
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"

if [ "$profile" = "release" ]; then
    zip_path="target/release/Magi-reader-macos-UNNOTARIZED.zip"
    rm -f "$zip_path"
    # ditto preserves the bundle structure and code signature inside the zip.
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
    verify_dir="$(mktemp -d /tmp/magi-rust-package.XXXXXX)"
    trap 'rm -rf "$verify_dir"' EXIT
    ditto -x -k "$zip_path" "$verify_dir"
    codesign --verify --deep --strict "$verify_dir/Magi.app"
    shasum -a 256 "$zip_path" > "$zip_path.sha256"
    rm -rf "$app_dir"
    echo "WARNING: local artifact is not notarized; do not publish it." >&2
    echo "$zip_path"
    echo "$zip_path.sha256"
fi
