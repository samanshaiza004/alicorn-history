#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
REPO_ROOT=$repo_root
cd "$repo_root"

odin_command=${ALICORN_ODIN:-odin}
case "$odin_command" in
	/*)
		if [ ! -x "$odin_command" ]; then
			echo "Odin executable not found: $odin_command" >&2
			exit 1
		fi
		;;
	*)
		odin_path=$(command -v "$odin_command" 2>/dev/null || true)
		if [ -z "$odin_path" ]; then
			echo "Odin executable not found on PATH: $odin_command" >&2
			exit 1
		fi
		odin_command=$odin_path
		;;
esac

git submodule update --init --recursive
. "$repo_root/vendor/alicorn/tools/accesskit.sh"
accesskit_link_flags=$(alicorn_accesskit_linker_flags)
mkdir -p out
"$odin_command" build . "-extra-linker-flags:$accesskit_link_flags" -out:out/alicorn-history-check
exec ./out/alicorn-history-check --self-test "${1:-.}"
