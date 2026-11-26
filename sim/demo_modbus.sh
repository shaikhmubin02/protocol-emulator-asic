#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
#
# mbpoll, unmodified, reads and writes holding registers of modbus.s on the simulated chip
# through a pseudo-terminal. Needs mbpoll (apt install mbpoll).
set -euo pipefail
cd "$(dirname "$0")"
make -s
log=build/modbus.log
./build/pemu_sim modbus > "$log" &
sim=$!
trap 'kill $sim 2>/dev/null || true' EXIT
for _ in $(seq 50); do grep -q /dev/pts "$log" && break; sleep 0.1; done
pty=$(grep -o '/dev/pts/[0-9]*' "$log" | head -1)
opts=(-m rtu -a 1 -b 115200 -P even -t 4 -0 -1)
echo "== read registers 0 to 3"
mbpoll "${opts[@]}" -r 0 -c 4 "$pty"
echo "== write 4660 (0x1234) to register 2"
mbpoll "${opts[@]}" -r 2 "$pty" 4660
echo "== read them again"
mbpoll "${opts[@]}" -r 0 -c 4 "$pty"
