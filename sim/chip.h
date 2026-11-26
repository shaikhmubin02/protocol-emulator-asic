// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// The chip's RTL under Verilator, driven only through its pins, the way a board would drive it:
// the host SPI port (ui[0] SCK, ui[1] CSn, ui[2] MOSI, uo[7] MISO) and the protocol pins. The
// address map is in hw/src/chip.ml. Inputs change on the falling clock edge, half a cycle away
// from the chip's rising edge, as in the cocotb testbench (test/test.py).
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class Vtt_um_shaikhmubin02_pemu;

class Chip {
 public:
  Chip();
  ~Chip();

  // What is wired to the protocol pins: called on every falling clock edge, it may read the
  // outputs and set ui_proto (ui[7:3]) and uio_in.
  std::function<void(Chip&)> board;
  uint8_t ui_proto = 0;
  uint8_t uio_in = 0xFF;

  uint8_t uo() const;
  uint8_t uio_out() const;
  uint8_t uio_oe() const;
  uint64_t cycle() const { return cycle_; }

  void tick();
  void ticks(uint64_t n) {
    for (uint64_t k = 0; k < n; k++) tick();
  }

  // the host port
  void write(uint16_t addr, const std::vector<uint16_t>& words);
  std::vector<uint16_t> read(uint16_t addr, int n);

  void load(int engine, const std::vector<uint16_t>& program);
  void own(int pin, int engine);
  void run(unsigned engines);
  uint16_t status(int engine);
  // to an engine's inbox if there is room; false if it is full
  bool send(int engine, uint16_t word);
  // whatever is waiting in an engine's outbox
  std::vector<uint16_t> receive(int engine);

 private:
  std::unique_ptr<Vtt_um_shaikhmubin02_pemu> top_;
  uint64_t cycle_ = 0;
  uint8_t sck_ = 0, cs_n_ = 1, mosi_ = 0;
  std::vector<uint8_t> transfer(const std::vector<uint8_t>& data);
};

// one word a line, in hex, as hw/_build/default/bin/asm.exe prints it
std::vector<uint16_t> read_hex(const std::string& path);
