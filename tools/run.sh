#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
history_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
alicorn_root=$history_root/vendor/alicorn
REPO_ROOT=$alicorn_root
. "$alicorn_root/tools/accesskit.sh"
cd "$history_root"

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
accesskit_binding_root=$(alicorn_accesskit_binding_root)
accesskit_library_directory=$(alicorn_accesskit_library_directory)
accesskit_linker_flags=$(alicorn_accesskit_linker_flags)
"$odin_command" build . \
	"-collection:alicorn=$alicorn_root" \
	"-collection:accesskit=$accesskit_binding_root" \
	"-collection:accesskit_c=$accesskit_library_directory" \
	"-extra-linker-flags:$accesskit_linker_flags" \
	-out:out/alicorn-history
exec ./out/alicorn-history "$@"
