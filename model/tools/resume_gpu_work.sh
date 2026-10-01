#!/usr/bin/env bash
# Thaw the model jobs frozen by pause_gpu_work.sh.
exec "$(dirname "$0")/pause_gpu_work.sh" --resume
