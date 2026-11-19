#!/bin/bash
# HackiOS for Xiaomi Redmi 10C (fog) -- run the prebuilt SpringBoard payload, RAM only.
#
#   ./run.sh                 the whole cycle and SECS (default 2400) seconds of the kernel running
#   SECS=600 ./run.sh        a shorter run
#   SLICE=60 ./run.sh        fetch the log every 60 s instead of 120
#
# Nothing is written to the phone: the UEFI, the kernel, the payload and the root image are all
# uploaded/staged into RAM. The loader dies on a second kernel in the same session, so every run is
# a full cycle: bootloader -> UEFI -> [xnuloader] -> resident ramdisk -> stage payload -> oem run.
set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

K=$ROOT/prebuilt/mach.development.bcm2837
UEFI=$ROOT/prebuilt/xnu-usb-fog.img
PAYLOAD=$ROOT/prebuilt/run-sb-unblock.bin
FLASHBOOT=$ROOT/prebuilt/flashboot.apfs
XL=$ROOT/prebuilt/xl

SECS=${SECS:-2400}
SLICE=${SLICE:-120}
OUT=${OUT:-$ROOT/logs/run-sb-unblock.log}
mkdir -p "$ROOT/logs"

say() { echo "[$(date +%T)] $*"; }

waitfor() { # waitfor <what> <command...>
	local what=$1 i
	shift
	for i in $(seq 1 60); do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 2
	done
	say "no $what after 120 s"
	return 1
}

for f in "$K" "$UEFI" "$PAYLOAD" "$FLASHBOOT" "$XL"; do
	[ -f "$f" ] || { say "missing $f"; exit 1; }
done

say "rebooting to the bootloader"
if fastboot devices | grep -q xnuloader; then
	say "leaving the loader"
	fastboot reboot | tail -1
fi
if ! fastboot devices | grep -q fastboot; then
	# Android or its recovery: both have adb (the loader's reboot has landed in recovery before)
	timeout 240 adb wait-for-device || true
	sleep 4
	adb reboot bootloader 2>/dev/null || adb reboot 2>/dev/null || true
	sleep 12
fi
if ! fastboot devices | grep -q fastboot; then
	say "no fastboot device"
	exit 1
fi

say "booting the UEFI"
fastboot boot "$UEFI" | tail -2
sleep 10
waitfor xnuloader sh -c 'fastboot devices | grep -q xnuloader' || exit 1

say "uploading the resident image"
"$XL" ramdisk "$FLASHBOOT" | tail -2 || exit 1

say "staging the payload"
fastboot stage "$PAYLOAD" | tail -2 || exit 1

say "running ($SECS s)"
fastboot oem run | tail -2

i=0
while [ $((i * SLICE)) -lt "$SECS" ]; do
	i=$((i + 1))
	sleep "$SLICE"
	"$XL" log >/dev/null 2>&1 || true
	# the kernel log starts after the loader's own log
	sed -n '/== KERNEL LOG/,$p' "$ROOT/logs/loader.log" > "$OUT"
	say "slice $i: $(wc -c <"$OUT") bytes, $(grep -ac 'hakios: threads' "$OUT") thread dumps, last line: $(tail -1 "$OUT" | cut -c1-60)"
	if [ $((i % 2)) = 0 ]; then
		"$XL" screenshot "$ROOT/logs/screen-$((i * SLICE)).png" >/dev/null 2>&1 || true
	fi
done
say "done; the slice is $OUT"
