#!/usr/bin/env bash
# Asks whether this game actually makes a noise.
#
#   tools/audio_probe.sh
#
# Uses xvfb-run because this needs an audio device, and `--headless` does not have one:
# AudioServer reports the `Dummy` driver there, dot-audio correctly builds the sink that
# cannot make a noise, and the one question this asks never comes up. The same reason
# screenshot.sh is not headless, for the other sense.
#
# Exit codes:
#   0  every probe sounded
#   1  something was silent that should not have been
#   2  no audio device -- this machine cannot answer the question
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --script tools/audio_probe.gd
