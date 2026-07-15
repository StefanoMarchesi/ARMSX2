#!/bin/bash

# Isolated Raspberry Pi 5 launcher for validating the modern ARMSX2 port.
# It intentionally leaves every experimental renderer path disabled so results
# can be compared against a clean modern-upstream baseline first.

ASX=/home/raspi/armsx2-port-20260715/build-pi5-port
TEST_DATA=/home/raspi/armsx2-port-test-profile

export LD_LIBRARY_PATH=/home/raspi/armsx2-deps/prefix/lib:/opt/mesa-stable/lib/aarch64-linux-gnu
export VK_DRIVER_FILES=/opt/mesa-stable/share/vulkan/icd.d/broadcom_icd.aarch64.json
export XDG_RUNTIME_DIR=/run/user/1000
export PULSE_SERVER=unix:/run/user/1000/pulse/native
export WAIT_SPIN_MICROSECONDS=2
export GAME_MODE="${GAME_MODE:-720x480}"

unset ARMSX2_MRT ARMSX2_MRT_AUTO ARMSX2_MRT_AUTO_DIAG
unset ARMSX2_MRT_SWBLEND ARMSX2_MRT_ALPHA2 ARMSX2_MRT_DIAG
unset ARMSX2_SPRITE_FASTPATH ARMSX2_SPRITE_FASTPATH_DIAG
unset ARMSX2_HITCHLOG ARMSX2_FRAMELOG

case "$1" in
	*"God of War"*) export ARMSX2_DEPTH=d24s8 ;;
	*) unset ARMSX2_DEPTH ;;
esac

exec /home/raspi/game-mode.sh gamemoderun "$ASX/bin/armsx2-qt" \
	-batch -fullscreen -nogui -datapath "$TEST_DATA" -- "$1"
