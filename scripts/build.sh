#!/bin/zsh
# Unified development entry; no build has been executed in this integration task.
set -eu
cd "${0:A:h:h}"
exec zsh scripts/build-cloud.sh
