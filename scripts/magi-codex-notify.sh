#!/bin/zsh

set -u

script_dir="${0:A:h}"
previous_command=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  previous_command+=("$1")
  shift
done
[[ $# -gt 0 ]] && shift
payload="${1:-}"

if [[ ${#previous_command[@]} -gt 0 ]]; then
  "${previous_command[@]}" "$payload" || true
fi

"$script_dir/magi-cli-hook.sh" codex "$payload"
