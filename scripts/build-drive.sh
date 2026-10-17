#!/bin/zsh
# Compatibility entry point: there is now one app with runtime sync selection.
set -eu
cd "${0:A:h:h}"
exec zsh scripts/build-cloud.sh "$@"
