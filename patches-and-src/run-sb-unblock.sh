#!/bin/bash
# Run SpringBoard on the fog phone with our own payload: redwood's kernel, the small root.apfs
# (GL=1, RC_JOBS=rc.jobs.unlock, no REST=1) and the resident flashboot.apfs as /dev/md0.
#
#   scripts/run-sb-unblock.sh            the whole cycle and a run of SECS seconds
#   SECS=600 scripts/run-sb-unblock.sh   shorter
#
# The loader dies on a second kernel in the same session, so every run is a full cycle:
# Android/loader -> bootloader -> UEFI -> [xnuloader] -> ramdisk -> stage payload -> oem run.
set -u
ROOT=/home/feolov/Projects/hackios-fog-workspace/hakios-xnu-kernel
K=/home/feolov/Projects/hackios-redwood/hackios-xnu-kernel/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
UEFI=/home/feolov/Projects/hackios-redwood/hackios-xnu-kernel/xnu-usb-fog.img
PAYLOAD=$ROOT/out/run-sb-unblock.bin
SECS=${SECS:-1500}
SLICE=${SLICE:-60}
OUT=${OUT:-/tmp/opencode/run-sb-unblock.log}

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

say "packing $PAYLOAD"
python3 "$ROOT/xnuloader/mkpayload.py" -o "$PAYLOAD" kernel="$K" ramdisk="$ROOT/userland/root.apfs" \
	--cmdline "debug=0x8 root_apfs=ufs_darwin ufs=2 bootcpu=7 cpus=7 loader_return_after=$SECS var_store=1 ufs_write=1 adreno=0 gl=1 sb_delay=10 graphics_console=0 fbscale=2 applog=1 darwin_file=1 darwin_blocks=3145728 console=fbcon -v amfi_get_out_of_my_way=1 cs_enforcement_disable=1 ${THREADS:+sb_threads=$THREADS} ${EXTRA_ARGS:-}" \
	|| exit 1
ls -la "$PAYLOAD"

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
"$ROOT/xl" ramdisk "$ROOT/userland/flashboot.apfs" | tail -2 || exit 1

say "staging the payload"
fastboot stage "$PAYLOAD" | tail -2 || exit 1

say "running ($SECS s)"
fastboot oem run | tail -2

i=0
while [ $((i * SLICE)) -lt "$SECS" ]; do
	i=$((i + 1))
	sleep "$SLICE"
	"$ROOT/xl" log >/dev/null 2>&1 || true
	# the kernel log starts after the loader's own log
	sed -n '/== KERNEL LOG/,$p' "$ROOT/logs/loader.log" > "$OUT"
	say "slice $i: $(wc -c <"$OUT") bytes, $(grep -ac 'hakios: threads' "$OUT") thread dumps, last line: $(tail -1 "$OUT" | cut -c1-60)"
	if [ $((i % 2)) = 0 ]; then
		"$ROOT/xl" screenshot "/tmp/opencode/screen-unblock-$((i * SLICE)).png" >/dev/null 2>&1 || true
	fi
done
say "done; the slice is $OUT"
