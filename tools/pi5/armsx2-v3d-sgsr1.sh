#!/usr/bin/env bash
set -euo pipefail

ARMSX2_ROOT="${ARMSX2_ROOT:-/mnt/share/dev/armsx2-v3d-sgsr1/build-final}"
ARMSX2_DATA="${ARMSX2_DATA:-/home/raspi/armsx2-data}"

export LD_LIBRARY_PATH=/opt/mesa-stable/lib/aarch64-linux-gnu
export VK_DRIVER_FILES=/opt/mesa-stable/share/vulkan/icd.d/broadcom_icd.aarch64.json
export XDG_RUNTIME_DIR=/run/user/1000
export PULSE_SERVER=unix:/run/user/1000/pulse/native
export WAIT_SPIN_MICROSECONDS=2
export ARMSX2_MRT_AUTO="${ARMSX2_MRT_AUTO:-1}"
export ARMSX2_MRT_SWBLEND="${ARMSX2_MRT_SWBLEND:-1}"
export ARMSX2_MRT_ALPHA2="${ARMSX2_MRT_ALPHA2:-1}"
export ARMSX2_V3D_SGSR1="${ARMSX2_V3D_SGSR1:-1}"

case "${1:-}" in
  *"God of War"*) export ARMSX2_DEPTH=d24s8 ;;
esac

export GAME_MODE="${GAME_MODE:-720x480}"
exec /home/raspi/game-mode.sh gamemoderun "$ARMSX2_ROOT/bin/pcsx2-qt" \
  -batch -fullscreen -nogui -datapath "$ARMSX2_DATA" -- "$1"
