#!/bin/sh
set -eu

binary=${1:-bin/vc}
state=$(mktemp -d /tmp/vcode-bench-state.XXXXXX)
config=$(mktemp -d /tmp/vcode-bench-config.XXXXXX)
trap 'rm -rf "$state" "$config"' EXIT

echo "Warm model-list startup (5 runs):"
i=0
while [ "$i" -lt 5 ]; do
  XDG_STATE_HOME="$state" XDG_CONFIG_HOME="$config" OPENAI_API_KEY= ANTHROPIC_API_KEY= /usr/bin/time -p "$binary" model list >/dev/null
  i=$((i + 1))
done
