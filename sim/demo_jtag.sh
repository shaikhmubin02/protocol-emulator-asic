#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
#
# OpenOCD, unmodified, finds jtag_tap.s on the simulated chip and reads and writes its USER
# register. Needs openocd (apt install openocd).
set -euo pipefail
cd "$(dirname "$0")"
make -s
./build/pemu_sim jtag 3335 &
sim=$!
trap 'kill $sim 2>/dev/null || true' EXIT
sleep 1
openocd -f openocd_pemu.cfg
wait $sim
