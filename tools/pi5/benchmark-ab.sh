#!/bin/bash

# Reproducible Raspberry Pi 5 A/B benchmark for the legacy tuned branch and
# the modern ARMSX2 port. Existing user profiles are read-only: every run gets
# fresh, isolated data and shader-cache directories.

set -euo pipefail

GAME="${1:?usage: benchmark-ab.sh <sotc|gtavc|gow2|bge|driv3r> [repeats]}"
REPEATS="${2:-3}"
START_FRAME="${START_FRAME:-240}"
END_FRAME="${END_FRAME:-840}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-240}"
MIN_SAMPLES="${MIN_SAMPLES:-200}"
MRT_MODE="${MRT_MODE:-baseline}"

ROMS=/mnt/share/roms/ps2
SOURCE_DATA=/home/raspi/armsx2-data/PCSX2
STABLE_BIN=/home/raspi/armsx2-staging/2026-07-15-ftlog/pcsx2-qt
MODERN_BIN=/home/raspi/armsx2-port-20260715/build-pi5-port/bin/armsx2-qt
RESULT_BASE=/home/raspi/perf-results
RUN_ID="$(date +%Y%m%d-%H%M%S)-${GAME}-${MRT_MODE}-ab"
RUN_ROOT="$RESULT_BASE/$RUN_ID"

RECORDING=
STATE=
case "$GAME" in
	sotc)
		ROM="$ROMS/Shadow of the Colossus (Europe, Australia) (En,Fr,De,Es,It).chd"
		RECORDING=/home/raspi/sotc-frame-locked.p2m2
		;;
	gtavc)
		ROM="$ROMS/Grand Theft Auto - Vice City (Europe) (En,Fr,De,Es,It) (v3.00).chd"
		STATE="$SOURCE_DATA/sstates/SLES-51061 (26954C46).01.p2s"
		;;
	gow2)
		ROM="$ROMS/God of War II (Europe, Australia) (En,Fr,De,Es,It,Ru).chd"
		STATE="$SOURCE_DATA/sstates/SCES-54206 (44A8A22A).01.p2s"
		;;
	bge)
		ROM="$ROMS/Beyond Good & Evil (Europe).chd"
		STATE="$SOURCE_DATA/sstates/SLES-51917 (591ABA45).01.p2s"
		;;
	driv3r)
		ROM="$ROMS/Driv3r (Europe, Australia) (En,Fr,De,Es,It).chd"
		STATE="${DRIV3R_STATE:-$SOURCE_DATA/sstates/SLES-50876 (E94FBF35).01.p2s}"
		;;
	*)
		echo "unknown game: $GAME" >&2
		exit 2
		;;
esac

test -x "$STABLE_BIN"
test -x "$MODERN_BIN"
test -r "$ROM"
[ -z "$STATE" ] || test -r "$STATE"
[ -z "$RECORDING" ] || test -r "$RECORDING"
if pgrep -x pcsx2-qt >/dev/null || pgrep -x armsx2-qt >/dev/null; then
	echo "ARMSX2 is already running; benchmark cancelled" >&2
	exit 3
fi

mkdir -p "$RUN_ROOT"

prepare_profile() {
	local build="$1" app="$2" profile
	profile="$RUN_ROOT/profile-$build"
	local target="$profile/$app"
	mkdir -p "$target"
	for directory in bios cheats gamesettings inis inputprofiles memcards patches textures; do
		if [ -d "$SOURCE_DATA/$directory" ]; then
			cp -a "$SOURCE_DATA/$directory" "$target/"
		fi
	done
	mkdir -p "$target/cache" "$target/logs" "$target/sstates" "$profile/xdg-cache"
}

prepare_profile stable PCSX2
prepare_profile modern ARMSX2

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/home/raspi/.Xauthority}"
export XDG_RUNTIME_DIR=/run/user/1000
export PULSE_SERVER=unix:/run/user/1000/pulse/native
export LD_LIBRARY_PATH=/home/raspi/armsx2-deps/prefix/lib:/opt/mesa-stable/lib/aarch64-linux-gnu
export VK_DRIVER_FILES=/opt/mesa-stable/share/vulkan/icd.d/broadcom_icd.aarch64.json
export WAIT_SPIN_MICROSECONDS=2
export ARMSX2_FTLOG=1
export ARMSX2_FRAMEGATE=1
export ARMSX2_FRAMELOG=1
unset ARMSX2_MRT ARMSX2_MRT_AUTO ARMSX2_MRT_SWBLEND ARMSX2_MRT_ALPHA2 ARMSX2_MRT_DIAG
unset ARMSX2_SPRITE_FASTPATH ARMSX2_SPRITE_FASTPATH_DIAG ARMSX2_HITCHLOG
if [ "$GAME" = gow2 ]; then
	export ARMSX2_DEPTH=d24s8
else
	unset ARMSX2_DEPTH
fi
if [ -n "$RECORDING" ]; then
	export ARMSX2_INPUT_RECORDING="$RECORDING"
else
	unset ARMSX2_INPUT_RECORDING
fi

ESDE_PID="$(pgrep -x es-de || true)"
restore_desktop() {
	[ -n "$ESDE_PID" ] && kill -CONT "$ESDE_PID" 2>/dev/null || true
	sleep 1
	xrandr --output HDMI-2 --mode 1920x1080 --rate 60 --primary 2>/dev/null || true
}
trap restore_desktop EXIT INT TERM HUP QUIT
[ -n "$ESDE_PID" ] && kill -STOP "$ESDE_PID" 2>/dev/null || true
xrandr --output HDMI-2 --mode 720x480 --rate 60 --primary 2>/dev/null || true

run_one() {
	local build="$1" phase="$2" iteration="$3"
	local bin app profile log prefix pid started last captured
	if [ "$build" = stable ]; then
		bin="$STABLE_BIN"
		app=PCSX2
	else
		bin="$MODERN_BIN"
		app=ARMSX2
	fi
	profile="$RUN_ROOT/profile-$build"
	log="$profile/$app/logs/emulog.txt"
	prefix="$RUN_ROOT/${build}-${phase}-${iteration}"
	: >"$log"

	local -a state_args=()
	local -a run_env=("XDG_CACHE_HOME=$profile/xdg-cache")
	[ -z "$STATE" ] || state_args=(-statefile "$STATE")
	if [ "$MRT_MODE" = tuned ]; then
		run_env+=(ARMSX2_MRT_SWBLEND=1 ARMSX2_MRT_ALPHA2=1)
		run_env+=(ARMSX2_MRT_AUTO=1)
	elif [ "$MRT_MODE" != baseline ]; then
		echo "unknown MRT_MODE: $MRT_MODE" >&2
		exit 2
	fi
	env "${run_env[@]}" gamemoderun "$bin" \
		-unlimited -batch -fullscreen -nogui -datapath "$profile" \
		"${state_args[@]}" -- "$ROM" >"$prefix.launch.log" 2>&1 &
	pid=$!
	started="$(date +%s)"
	last=0
	captured=0
	while kill -0 "$pid" 2>/dev/null; do
		last="$(grep -o 'FRAMEGATE frame=[0-9]*' "$log" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
		last="${last:-0}"
		if [ "$last" -ge "$END_FRAME" ]; then
			break
		fi
		if [ "$phase" = warmup ] && [ "$captured" -eq 0 ] && [ "$last" -ge 600 ]; then
			scrot "$prefix-frame600.png" 2>/dev/null || true
			captured=1
		fi
		if [ "$(( $(date +%s) - started ))" -ge "$TIMEOUT_SECONDS" ]; then
			echo "$build $phase $iteration timed out at frame $last" >&2
			break
		fi
		sleep 0.2
	done
	kill -TERM "$pid" 2>/dev/null || true
	sleep 1
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	grep 'FTLOG frame=' "$log" >"$prefix.ftlog" || true
	cp "$log" "$prefix.emulog.txt"

	python3 - "$prefix.ftlog" "$START_FRAME" "$END_FRAME" "$MIN_SAMPLES" "$prefix.json" "$build" "$phase" "$iteration" <<'PY'
import json, math, re, sys

path, start, end, minimum, output, build, phase, iteration = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5],
    sys.argv[6], sys.argv[7], int(sys.argv[8])
)
records = []
with open(path, encoding="utf-8", errors="replace") as stream:
    for line in stream:
        match = re.search(r"\[\s*([0-9.]+)\].*FTLOG frame=(\d+) ms=([0-9.]+)", line)
        if not match:
            continue
        timestamp, frame, milliseconds = float(match[1]), int(match[2]), float(match[3])
        if start <= frame <= end:
            records.append((frame, milliseconds, timestamp))
if len(records) < minimum:
    raise SystemExit(f"{build} {phase} {iteration}: only {len(records)} samples")

samples = sorted(item[1] for item in records)
def percentile(value):
    position = (len(samples) - 1) * value
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return samples[lower]
    return samples[lower] * (upper - position) + samples[upper] * (position - lower)

elapsed = records[-1][2] - records[0][2]
result = {
    "build": build,
    "phase": phase,
    "iteration": iteration,
    "samples": len(records),
    "first_frame": records[0][0],
    "last_frame": records[-1][0],
    "elapsed_s": elapsed,
    "emulated_fps": (records[-1][0] - records[0][0]) / elapsed,
    "mean_ms": sum(samples) / len(samples),
    "p50_ms": percentile(0.50),
    "p95_ms": percentile(0.95),
    "p99_ms": percentile(0.99),
    "max_ms": max(samples),
    "over_33_3ms": sum(value > 33.3 for value in samples),
    "over_50ms": sum(value > 50.0 for value in samples),
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(result, stream, indent=2, sort_keys=True)
print(
    f"{build} {phase} {iteration}: {result['emulated_fps']:.3f} fps; "
    f"p50={result['p50_ms']:.3f} ms p95={result['p95_ms']:.3f} ms "
    f"p99={result['p99_ms']:.3f} ms"
)
PY
}

echo "Results: $RUN_ROOT"
echo "Warming isolated caches..."
run_one stable warmup 0
run_one modern warmup 0

for iteration in $(seq 1 "$REPEATS"); do
	if [ "$((iteration % 2))" -eq 1 ]; then
		run_one stable measure "$iteration"
		run_one modern measure "$iteration"
	else
		run_one modern measure "$iteration"
		run_one stable measure "$iteration"
	fi
done

python3 - "$RUN_ROOT" <<'PY'
import glob, json, os, statistics, sys

root = sys.argv[1]
rows = []
for path in glob.glob(os.path.join(root, "*-measure-*.json")):
    with open(path, encoding="utf-8") as stream:
        rows.append(json.load(stream))
summary = {}
for build in ("stable", "modern"):
    selected = [row for row in rows if row["build"] == build]
    summary[build] = {
        key: statistics.median(row[key] for row in selected)
        for key in ("emulated_fps", "mean_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms")
    }
with open(os.path.join(root, "summary.json"), "w", encoding="utf-8") as stream:
    json.dump(summary, stream, indent=2, sort_keys=True)
for build, values in summary.items():
    print(
        f"{build}: median fps={values['emulated_fps']:.3f}, "
        f"p50={values['p50_ms']:.3f} ms, p95={values['p95_ms']:.3f} ms, "
        f"p99={values['p99_ms']:.3f} ms"
    )
change = (summary["modern"]["emulated_fps"] / summary["stable"]["emulated_fps"] - 1.0) * 100.0
print(f"modern throughput change: {change:+.2f}%")
PY
