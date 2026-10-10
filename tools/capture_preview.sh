#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
usage() {
	printf 'Usage: %s [options] [output-directory]\n' "${0##*/}"
	printf '  --lua FILE          Lua scene setup, replacing the default appearance preview.\n'
	printf '  --filter FRAME      Capture one frame hierarchy; "none" captures all visible UI.\n'
	printf '                      Default: QuestWithFriendsPanel, or none with --lua.\n'
	printf '  --width PIXELS       Canvas width (default: 800).\n'
	printf '  --height PIXELS      Canvas height (default: 600).\n'
	printf '  --name NAME          Output basename (default: preview).\n'
	printf '  --no-game-assets     Disable local WoW asset discovery and loading.\n'
	printf '  --visibility-boost   Brighten dark UI for debugging; not faithful colors.\n'
	printf '  WOW_INSTALL_PATH overrides discovery of an installation above the addon directory.\n'
}

visibility_boost=0
no_game_assets=0
scene="$script_dir/simulator/preview_demo.lua"
custom_scene=0
filter=QuestWithFriendsPanel
filter_explicit=0
width=800
height=600
preview_name=preview
directories=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--visibility-boost)
		visibility_boost=1
		;;
	--no-game-assets)
		no_game_assets=1
		;;
	--lua | --filter | --width | --height | --name)
		if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
			printf 'Missing value for %s.\n' "$1" >&2
			usage >&2
			exit 2
		fi
		case "$1" in
		--lua)
			scene=$2
			custom_scene=1
			;;
		--filter)
			filter=$2
			filter_explicit=1
			;;
		--width) width=$2 ;;
		--height) height=$2 ;;
		--name) preview_name=$2 ;;
		esac
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		directories+=("$@")
		break
		;;
	-*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*) directories+=("$1") ;;
	esac
	shift
done
if [[ ${#directories[@]} -gt 1 ]]; then
	printf 'Specify only one output directory.\n' >&2
	usage >&2
	exit 2
fi
if [[ ! "$preview_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
	printf 'Output name must contain only letters, digits, underscores or hyphens, starting with a letter or digit.\n' >&2
	exit 2
fi
for size in "$width" "$height"; do
	if [[ ! "$size" =~ ^[1-9][0-9]{0,3}$ ]]; then
		printf 'Canvas dimensions must be integers between 1 and 9999.\n' >&2
		exit 2
	fi
done
if [[ ! -f "$scene" || ! -r "$scene" ]]; then
	printf 'Lua scene is not a readable file: %s\n' "$scene" >&2
	exit 2
fi
scene=$(cd -- "$(dirname -- "$scene")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$scene")")
if [[ "$custom_scene" == 1 && "$filter_explicit" == 0 ]]; then
	filter=none
fi

install_path=
asset_source="disabled by --no-game-assets"
if [[ "$no_game_assets" == 0 ]]; then
	if [[ -n ${WOW_INSTALL_PATH:-} ]]; then
		if [[ ! -d "$WOW_INSTALL_PATH/Data" || ! -f "$WOW_INSTALL_PATH/.build.info" ]]; then
			printf 'WOW_INSTALL_PATH must point to a WoW installation root with Data and .build.info: %s\n' "$WOW_INSTALL_PATH" >&2
			exit 2
		fi
		install_path=$(cd -- "$WOW_INSTALL_PATH" && pwd -P)
		asset_source=WOW_INSTALL_PATH
	else
		candidate=$repo_root
		while :; do
			if [[ -d "$candidate/Data" && -f "$candidate/.build.info" ]]; then
				install_path=$candidate
				break
			fi
			[[ "$candidate" == / ]] && break
			candidate=$(dirname -- "$candidate")
		done
		asset_source="auto-discovered above addon"
		if [[ -z "$install_path" ]]; then
			asset_source="not found; fallback assets may be missing"
		fi
	fi
fi

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

preview_mode="faithful colors"
if [[ "$visibility_boost" == 1 ]]; then
	preview_name+=-visibility-boost
	preview_mode="visibility boost (debug only; colors are not faithful)"
fi
output_dir=${directories[0]:-"$repo_root/.cache/simulator-previews"}
cache_dir=${QWF_SIMULATOR_CACHE_DIR:-"${XDG_CACHE_HOME:-"$HOME/.cache"}/quest-with-friends/simulator-preview"}
mkdir -p -- "$output_dir" "$cache_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
cache_dir=$(cd -- "$cache_dir" && pwd -P)
args=(
	--rm
	--init
	--platform linux/amd64
	--user "$(id -u):$(id -g)"
	-e WOW_SIM_LOAD_OUT_OF_DATE_ADDONS=1
	-e "WOW_SIM_VISIBILITY_BOOST=$visibility_boost"
	-v "$repo_root:/app/Interface/AddOns/QuestWithFriends:ro"
	-v "$scene:/demo.lua:ro"
	-v "$output_dir:/output"
	-v "$cache_dir:/tmp/wow-ui-sim-cache"
)
if [[ -n "$install_path" ]]; then
	args+=(-v "$install_path:/wow:ro" -e WOW_INSTALL_PATH=/wow)
else
	args+=(-e WOW_SIM_CASC=0)
fi
screenshot_args=(--width "$width" --height "$height")
if [[ "$filter" != none ]]; then
	screenshot_args+=(--filter "$filter")
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
{
	printf 'Preview mode: %s\n' "$preview_mode"
	printf 'Scene: %s\nFilter: %s\nCanvas: %sx%s\n' "$scene" "$filter" "$width" "$height"
	printf 'Game assets: %s%s\n' "$asset_source" "${install_path:+ ($install_path)}"
} | tee "$log_path"
if docker run "${args[@]}" --cidfile "$capture_dir/container.cid" "$image" \
	--exec-lua @/demo.lua screenshot "${screenshot_args[@]}" \
	-o "/output/$(basename -- "$capture_dir")/$preview_name.webp" 2>&1 | tee -a "$log_path"; then
	if grep -qF '[exec-lua] error:' "$log_path" || [[ ! -s "$screenshot_path" ]]; then
		printf 'Screenshot failed; see %s\n' "$log_path" >&2
		exit 1
	fi
else
	status=$?
	printf 'Screenshot failed; see %s\n' "$log_path" >&2
	exit "$status"
fi
mv -f -- "$screenshot_path" "$output_dir/$preview_name.webp"
printf '\nScreenshot: %s/%s.webp\n' "$output_dir" "$preview_name"
