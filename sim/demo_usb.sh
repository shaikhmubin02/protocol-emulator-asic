#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
#
# The Linux kernel's own USB stack enumerates the chip's RTL as a USB keyboard. pemu_sim runs
# usb_dev_rx.s and usb_dev_tx.s on the simulated chip and exports it over USB/IP; the kernel's
# vhci_hcd attaches it, usbhid binds to it, and a program reading its hidraw node turns the Caps
# Lock LED on, which makes the board start typing. Needs root (attach, hidraw, dmesg) and a kernel
# with USBIP_VHCI_HCD and USB_HID (WSL2's has both); lsusb (usbutils) is used if present.
set -euo pipefail
cd "$(dirname "$0")"
make -s
log=build/usb.log
./build/pemu_sim usb > "$log" &
sim=$!
port=""
cleanup() {
  [ -n "$port" ] && python3 usbip_attach.py --detach "$port" > /dev/null 2>&1 || true
  sleep 1
  kill $sim 2> /dev/null || true
}
trap cleanup EXIT
for _ in $(seq 100); do grep -q exported "$log" && break; sleep 0.1; done
head -1 "$log"
dmesg -C 2> /dev/null || true
echo "== attach"
out=$(python3 usbip_attach.py)
echo "$out"
port=$(echo "$out" | grep -o 'vhci port [0-9]*' | grep -o '[0-9]*$')
for _ in $(seq 300); do ls /sys/class/hidraw/*/device/uevent > /dev/null 2>&1 && grep -qs 1209 /sys/class/hidraw/*/device/uevent && break; sleep 0.1; done
echo "== the kernel's log"
dmesg | grep -E "usb 1-|input:|hid-generic" | sed -E 's/^\[ *[0-9.]+\] //'
if command -v lsusb > /dev/null; then
  echo "== lsusb"
  lsusb -d 1209:0001
fi
echo "== typing (the board starts when the Caps Lock LED comes on)"
python3 hidraw_keys.py 20 | grep -v '^report'
echo "== detach"
python3 usbip_attach.py --detach "$port"
port=""
sleep 1
kill $sim 2> /dev/null || true
wait $sim 2> /dev/null || true
echo "== the board processor saw"
sed -n '/Linux closed/,$p' "$log" | tail -n +2
