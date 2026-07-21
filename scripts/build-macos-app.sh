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

mkdir -p "$macos_dir"
cp "target/$profile/magi" "$macos_dir/magi"
cp "packaging/macos/Info.plist" "$contents_dir/Info.plist"

echo "$app_dir"
