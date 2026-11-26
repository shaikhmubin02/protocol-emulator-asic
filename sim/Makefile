# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
#
# The chip's RTL under Verilator with Linux software on the other end. `make` builds
# build/pemu_sim and assembles the firmware it uses; see main.cpp for what it runs.

VERILATOR ?= verilator
TOP = tt_um_shaikhmubin02_pemu
RTL = ../src/pemu.v ../test/sim_models.v \
      ../test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
      ../test/models/RM_IHPSG13_1P_256x16_c2_bm_bist.v
ASM = ../hw/_build/default/bin/asm.exe
FIRMWARE = jtag_tap modbus usb_dev_rx usb_dev_tx
FABRIC = ../hw/_build/default/post/fabric_words.exe
CONFIGS = usb_rx usb_tx

all: build/pemu_sim $(FIRMWARE:%=build/%.hex) $(CONFIGS:%=build/%.fabric)

build/pemu_sim: $(RTL) chip.cpp chip.h main.cpp usb.cpp usb.h
	@mkdir -p build/obj
	$(VERILATOR) --cc --exe --build -j 1 -O2 --no-timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-STMTDLY \
	  -DFUNCTIONAL \
	  --top-module $(TOP) -Mdir build/obj -o ../pemu_sim $(RTL) \
	  $(CURDIR)/chip.cpp $(CURDIR)/main.cpp $(CURDIR)/usb.cpp -CFLAGS "-O2 -I$(CURDIR)"

build/%.hex: ../hw/firmware/%.s
	@mkdir -p build
	$(ASM) $< > $@

# a fabric configuration's 8 words (hw/post/fabric_words.ml)
build/%.fabric: $(FABRIC)
	@mkdir -p build
	$(FABRIC) $* > $@

clean:
	rm -rf build

.PHONY: all clean
