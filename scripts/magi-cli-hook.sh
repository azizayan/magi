#!/bin/zsh

set -euo pipefail
umask 077

provider="${1:-}"
case "$provider" in
  codex|claude) ;;
  *) exit 0 ;;
esac

response_dir="${MAGI_CLI_RESPONSE_DIR:-$HOME/Library/Application Support/Magi/CLI Responses}"
mkdir -p "$response_dir"
chmod 700 "$response_dir"
temporary_file="$(mktemp "$response_dir/.incoming.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

if [[ "$provider" == "codex" ]]; then
  [[ $# -ge 2 ]] || exit 0
  printf '%s' "$2" > "$temporary_file"
else
  cat > "$temporary_file"
fi

final_file="$response_dir/$provider-$(date +%s)-$$-$RANDOM.json"
mv "$temporary_file" "$final_file"
chmod 600 "$final_file"
trap - EXIT
