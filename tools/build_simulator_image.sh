#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target="test"
image=wow-ui-sim:0.1.32-portable
if [[ ${1:-} == --preview ]]; then
	target=preview
	image=wow-ui-sim:0.1.32-preview
	shift
fi
exec docker build \
	--platform linux/amd64 \
	--target "$target" \
	--tag "$image" \
	"$@" \
	"$script_dir/simulator"
