#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
usage() {
	printf 'Usage: %s [--visibility-boost] [output-directory]\n' "${0##*/}"
	printf '  --visibility-boost  Brighten dark UI for debugging; not faithful colors.\n'
}

visibility_boost=0
parse_options=true
directories=()
for argument in "$@"; do
	if [[ "$parse_options" == true ]]; then
		case "$argument" in
		--visibility-boost)
			visibility_boost=1
			continue
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			parse_options=false
			continue
			;;
		-*)
			printf 'Unknown option: %s\n' "$argument" >&2
			usage >&2
			exit 2
			;;
		esac
	fi
	directories+=("$argument")
	if [[ ${#directories[@]} -gt 1 ]]; then
		printf 'Specify only one output directory.\n' >&2
		usage >&2
		exit 2
	fi
done

image=wow-ui-sim:0.1.32-preview
if ! image_color=$(docker image inspect --format '{{index .Config.Labels "local.wow-ui-sim.preview-color"}}' "$image" 2>/dev/null); then
	printf 'Build the renderer first: bash "%s/build_simulator_image.sh" --preview\n' "$script_dir" >&2
	exit 1
fi
if [[ "$image_color" != srgb-no-brightness-boost && "$image_color" != srgb-runtime-visibility-boost ]]; then
	printf 'Rebuild the renderer for faithful colors: bash "%s/build_simulator_image.sh" --preview\n' "$script_dir" >&2
	exit 1
fi
if [[ "$visibility_boost" == 1 && "$image_color" != srgb-runtime-visibility-boost ]]; then
	printf 'Rebuild the renderer for --visibility-boost: bash "%s/build_simulator_image.sh" --preview\n' "$script_dir" >&2
	exit 1
fi

preview_name=share
preview_mode="faithful colors"
if [[ "$visibility_boost" == 1 ]]; then
	preview_name=share-visibility-boost
	preview_mode="visibility boost (debug only; colors are not faithful)"
fi
output_dir=${directories[0]:-"$repo_root/.cache/simulator-previews"}
cache_dir=${QWF_SIMULATOR_CACHE_DIR:-"${XDG_CACHE_HOME:-"$HOME/.cache"}/quest-with-friends/simulator-preview"}
mkdir -p -- "$output_dir" "$cache_dir"
output_dir=$(cd -- "$output_dir" && pwd)
cache_dir=$(cd -- "$cache_dir" && pwd)
args=(
	--rm
	--init
	--platform linux/amd64
	--user "$(id -u):$(id -g)"
	-e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1
	-e "WOW_SIM_VISIBILITY_BOOST=$visibility_boost"
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
screenshot_path="$capture_dir/$preview_name.webp"
log_path="$output_dir/$preview_name.log"
cleanup() {
	if [[ -s "$capture_dir/container.cid" ]]; then
		docker rm --force "$(<"$capture_dir/container.cid")" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$capture_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Preview mode: %s\n' "$preview_mode" | tee "$log_path"
docker run "${args[@]}" --cidfile "$capture_dir/container.cid" "$image" \
	--exec-lua @/demo.lua screenshot \
	--filter QuestWithFriendsPanel --width 800 --height 600 \
	-o "/output/$(basename -- "$capture_dir")/$preview_name.webp" 2>&1 | tee -a "$log_path"
if grep -qF '[exec-lua] error:' "$log_path" || [[ ! -s "$screenshot_path" ]]; then
	printf 'Screenshot failed; see %s\n' "$log_path" >&2
	exit 1
fi
mv -f -- "$screenshot_path" "$output_dir/$preview_name.webp"
printf '\nScreenshot: %s/%s.webp\n' "$output_dir" "$preview_name"
