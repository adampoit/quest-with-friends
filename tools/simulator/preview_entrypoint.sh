#!/bin/sh
set -eu

umask 077
mkdir -p "$XDG_CACHE_HOME/wow-ui-sim" "$XDG_RUNTIME_DIR"
if [ ! -e "$XDG_CACHE_HOME/wow-ui-sim/blizzard-ui" ]; then
	ln -s /opt/wow-ui-sim/blizzard-ui "$XDG_CACHE_HOME/wow-ui-sim/blizzard-ui"
fi
exec /app/wow-sim "$@"
