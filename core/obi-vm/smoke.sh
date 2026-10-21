#!/bin/sh
# obi-vm's own limits, on a real VM (#827's review): a tampered image doesn't boot, the time limit
# stops the VM by itself, the console kept on the host stays at 1 MiB however much the guest writes,
# and killing obi-vm takes the VM down with it. The guest is `yes` as PID 1 (a debug build of obi-vm
# may boot its own init; a release build can't), so it floods the console and never stops.
#
#   core/obi-vm/smoke.sh <image dir: vmlinuz, initrd, root.img, image.json>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=$(cd "${1:?usage: smoke.sh <image dir>}" && pwd)
work=$(mktemp -d)
trap 'pkill -f "$work/obi-vm" 2>/dev/null || true; rm -rf "$work"' EXIT
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; exit 1; }
vms() { pgrep -f com.apple.Virtualization.VirtualMachine | sort | tr '\n' ' '; }

OBI_VM_DEBUG=1 "$here/build.sh" "$work/obi-vm" "$image/image.json" >/dev/null 2>&1
# One built for another image (its root's hash changed): it must refuse this one.
sed 's/"root.img": "[0-9a-f]/"root.img": "z/' "$image/image.json" > "$work/other.json"
OBI_VM_DEBUG=1 "$here/build.sh" "$work/obi-vm-other" "$work/other.json" >/dev/null 2>&1
dd if=/dev/zero of="$work/disk" bs=1 count=0 seek=1073741824 2>/dev/null

# Runs a VM named $1 with stdin held open, `$2` its --max-seconds, `$3` the image, `$4` the obi-vm.
run() {
  (sleep 900 | OBI_VM_DEBUG_INIT=/usr/bin/yes "${4:-$work/obi-vm}" run --kernel "$3/vmlinuz" --initrd "$3/initrd" \
     --root "$3/root.img" --disk "$work/disk" --cpus 2 --memory-mib 1024 --console "$work/$1.console" \
     --max-seconds "$2" > "$work/$1.events" 2> "$work/$1.err") &
}
# Waits up to $1 seconds for $3 in the file $2.
waitfor() {
  i=0
  while [ $i -lt $(($1 * 10)) ]; do grep -q "$3" "$2" 2>/dev/null && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

echo "== An image other than the one obi-vm was built for doesn't boot"
run bad 30 "$image" "$work/obi-vm-other"
waitfor 180 "$work/bad.err" "isn't the image this obi-vm was built for" || fail "it booted: $(cat "$work/bad.events" "$work/bad.err")"
pass "refused: $(cat "$work/bad.err")"

echo "== The time limit stops it, and the console stays at 1 MiB"
before=$(vms)
run limit 45 "$image"
waitfor 180 "$work/limit.events" '"running"' || fail "it didn't start: $(cat "$work/limit.err")"
started=$(date +%s)
waitfor 90 "$work/limit.events" '"time_limit"' || fail "no time limit: $(cat "$work/limit.events")"
sleep 3
if pgrep -f "$work/obi-vm run" >/dev/null; then fail "obi-vm still runs after its limit"; fi
[ "$(vms)" = "$before" ] || fail "a VM process outlived obi-vm"
pass "stopped by itself $(( $(date +%s) - started )) s after it started (limit 45 s); no VM process left"
size=$(stat -f %z "$work/limit.console")
[ "$size" -le 1048576 ] || fail "the console kept $size bytes"
[ "$size" -ge 1000000 ] || fail "the guest wrote only $size bytes: the cap wasn't tried"
pass "the guest flooded its console; $size bytes kept"

echo "== Killing obi-vm takes the VM with it"
before=$(vms)
run kill 600 "$image"
waitfor 180 "$work/kill.events" '"running"' || fail "it didn't start: $(cat "$work/kill.err")"
sleep 2
[ "$(vms)" != "$before" ] || fail "no VM process appeared"
pkill -9 -f "$work/obi-vm run"
i=0
while [ "$(vms)" != "$before" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(vms)" = "$before" ] || fail "the VM process outlived SIGKILL of obi-vm"
pass "the VM process was gone $((i / 10)).$((i % 10)) s after SIGKILL"
echo "All smoke checks passed."
