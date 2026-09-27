#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
image=wow-ui-sim:0.1.32-preview
if ! docker image inspect "$image" >/dev/null 2>&1; then
	printf 'Build the renderer first: bash "%s/build_simulator_image.sh" --preview\n' "$script_dir" >&2
	exit 1
fi

output_dir=${1:-"$repo_root/.cache/simulator-previews"}
cache_dir=${QWF_SIMULATOR_CACHE_DIR:-"${XDG_CACHE_HOME:-"$HOME/.cache"}/quest-with-friends/simulator-preview"}
mkdir -p "$output_dir" "$cache_dir"
output_dir=$(cd -- "$output_dir" && pwd)
cache_dir=$(cd -- "$cache_dir" && pwd)
args=(
	--rm
	--init
	--platform linux/amd64
	--user "$(id -u):$(id -g)"
	-e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1
	-v "$repo_root:/app/Interface/AddOns/QuestWithFriends:ro"
	-v "$script_dir/simulator/share_demo.lua:/demo.lua:ro"
	-v "$output_dir:/output"
	-v "$cache_dir:/tmp/wow-ui-sim-cache"
)
if [[ -n ${WOW_INSTALL_PATH:-} ]]; then
	install_path=$(cd -- "$WOW_INSTALL_PATH" && pwd)
	args+=(-v "$install_path:/wow:ro" -e WOW_INSTALL_PATH=/wow)
else
	args+=(-e WOW_SIM_CASC=0)
fi

capture_dir=$(mktemp -d "$output_dir/.capture.XXXXXX")
screenshot_path="$capture_dir/share.webp"
cleanup() {
	if [[ -s "$capture_dir/container.cid" ]]; then
		docker rm --force "$(<"$capture_dir/container.cid")" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$capture_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker run "${args[@]}" --cidfile "$capture_dir/container.cid" "$image" \
	--exec-lua @/demo.lua screenshot \
	--filter QuestWithFriendsPanel --width 800 --height 600 \
	-o "/output/$(basename -- "$capture_dir")/share.webp" 2>&1 | tee "$output_dir/share.log"
if grep -qF '[exec-lua] error:' "$output_dir/share.log" || [[ ! -s "$screenshot_path" ]]; then
	printf 'Screenshot failed; see %s/share.log\n' "$output_dir" >&2
	exit 1
fi
mv -f -- "$screenshot_path" "$output_dir/share.webp"
printf '\nScreenshot: %s/share.webp\n' "$output_dir"
