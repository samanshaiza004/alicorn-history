#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
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
mkdir -p out
"$odin_command" build . -out:out/alicorn-history
exec ./out/alicorn-history "$@"
