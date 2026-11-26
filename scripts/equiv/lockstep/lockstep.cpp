// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// The RTL and the signed-off netlist in lockstep under Verilator: the same random inputs every
// cycle, every output compared after every clock edge. The inputs are what a board could do:
// random programs loaded over the SPI host port, random host traffic (mailboxes read when empty
// too, status, registers, debugger stop / step / resume, flags, pin owners, fabric and CRC
// configuration), and random levels on the protocol pins.
//
//   lockstep <seed> <cycles>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vlockstep.h"
#include "verilated.h"

namespace {

Vlockstep* t;
uint64_t cyc = 0;
uint8_t sck = 0, csn = 1, mosi = 0, ui_hi = 0, uio = 0xFF;
uint64_t rng = 1;
const char* last_op = "reset";

uint32_t rnd() {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return uint32_t(rng >> 11);
}
uint32_t pick(uint32_t n) { return rnd() % n; }

void compare() {
  if (t->uo_rtl != t->uo_gl || t->uio_out_rtl != t->uio_out_gl || t->uio_oe_rtl != t->uio_oe_gl) {
    std::printf("DIFFER at cycle %llu (after %s): uo %02x/%02x uio_out %02x/%02x uio_oe %02x/%02x (rtl/gl)\n",
                (unsigned long long)cyc, last_op, t->uo_rtl, t->uo_gl, t->uio_out_rtl,
                t->uio_out_gl, t->uio_oe_rtl, t->uio_oe_gl);
    std::exit(1);
  }
}

void tick() {
  t->clk = 0;
  t->eval();
  // the protocol pins move now and then, as a device on the other end would move them
  if (pick(8) == 0) ui_hi = uint8_t(rnd());
  if (pick(8) == 0) uio = uint8_t(rnd());
  t->ui_in = uint8_t((ui_hi & 0xF8) | (mosi << 2) | (csn << 1) | sck);
  t->uio_in = uio;
  t->eval();
  compare();  // outputs that follow inputs without a clock, if any
  t->clk = 1;
  t->eval();
  cyc++;
  compare();
}
void ticks(int n) {
  for (int k = 0; k < n; k++) tick();
}

// one SPI frame, mode 0, SCK = clk/8
std::vector<uint8_t> transfer(const std::vector<uint8_t>& d) {
  std::vector<uint8_t> got;
  csn = 0;
  ticks(4);
  for (uint8_t b : d) {
    uint8_t r = 0;
    for (int k = 7; k >= 0; k--) {
      mosi = (b >> k) & 1;
      ticks(4);
      r = uint8_t((r << 1) | (t->uo_rtl >> 7));
      sck = 1;
      ticks(4);
      sck = 0;
    }
    got.push_back(r);
  }
  ticks(4);
  csn = 1;
  ticks(8);
  return got;
}

// what the status words read back showed: that the random activity reaches the mailboxes
uint64_t statuses = 0, outbox_words = 0, inbox_words = 0, running = 0, stopped = 0;
uint16_t addr(int e, int region, int off) { return uint16_t((e << 14) | (region << 12) | off); }
void write(uint16_t a, const std::vector<uint16_t>& w) {
  std::vector<uint8_t> d = {0x02, uint8_t(a >> 8), uint8_t(a)};
  for (uint16_t x : w) d.insert(d.end(), {uint8_t(x >> 8), uint8_t(x)});
  transfer(d);
}
std::vector<uint16_t> read(uint16_t a, int n) {
  std::vector<uint8_t> d = {0x03, uint8_t(a >> 8), uint8_t(a), 0};
  d.resize(4 + 2 * n, 0);
  auto got = transfer(d);  // MISO is uo[7], compared every cycle anyway
  std::vector<uint16_t> w;
  for (int k = 0; k < n; k++) w.push_back(uint16_t((got[4 + 2 * k] << 8) | got[5 + 2 * k]));
  return w;
}

// programs that keep the engines busy: many mailbox, timeout and flag instructions
uint16_t instr() {
  int r = pick(8);
  switch (pick(12)) {
    case 0: case 1: return uint16_t(0x0300 | r);              // PUSH
    case 2: case 3: return uint16_t(0x0400 | r);              // PULL
    case 4: return uint16_t(0xE000 | ((1 + pick(12)) << 6) | 0x04);  // CSRWI tmo, small
    case 5: return uint16_t(0x1000 | (r << 9) | (pick(2) << 8) | pick(256));  // LDI / LDIH
    case 6: return uint16_t(0x2000 | (r << 9) | (pick(8) << 6) | (pick(8) << 3));  // ALU
    case 7: return uint16_t(0x4000 | pick(256));              // JMP
    case 8: return uint16_t(0x0500 | (pick(2) << 8) | pick(8));  // SIG / CLRF
    default: {
      uint16_t w = uint16_t(rnd());
      return (w >> 12) == 15 ? uint16_t(w & 0x0FFF) : w;  // op 15 is reserved
    }
  }
}

void load_programs(unsigned engines) {
  write(addr(0, 3, 0x10), {0});  // stop them all: program memory is written while stopped
  for (int e = 0; e < 4; e++) {
    if (!((engines >> e) & 1)) continue;
    std::vector<uint16_t> p(256);
    for (auto& w : p) w = instr();
    write(addr(e, 0, 0), p);
  }
  last_op = "programs";
}

void host_op() {
  int e = pick(4);
  switch (pick(14)) {
    case 0: case 1: {
      std::vector<uint16_t> w(1 + pick(3));
      for (auto& x : w) x = uint16_t(rnd());
      write(addr(e, 2, 0x80), w);
      last_op = "mailbox write";
      break;
    }
    case 2: case 3: read(addr(e, 2, 0x80), 1 + pick(2)); last_op = "mailbox read"; break;
    case 4: case 5: {
      uint16_t st = read(addr(e, 2, 0), 1)[0];
      statuses++;
      inbox_words += (st >> 10) & 3;
      outbox_words += (st >> 12) & 3;
      running += (st >> 9) & 1;
      stopped += (st >> 15) & 1;
      last_op = "status";
      break;
    }
    case 6: read(addr(e, 2, 0x10 + pick(8)), 1 + pick(3)); last_op = "registers"; break;
    case 7: {
      // the debugger: stop, resume or step some engines
      uint16_t m = uint16_t(1 << pick(4));
      write(addr(0, 3, 0x14), {uint16_t(m << (4 * pick(3)))});
      last_op = "debug";
      break;
    }
    case 8: write(addr(0, 3, 0x11), {uint16_t(pick(256))}); last_op = "flags"; break;
    case 9: write(addr(0, 3, pick(15)), {uint16_t(pick(8))}); last_op = "pin owner"; break;
    case 10: {
      int ce = pick(2), word = pick(18);
      write(addr(ce, 1, 2 * word), {uint16_t(rnd()), uint16_t(rnd())});
      last_op = "configuration";
      break;
    }
    case 11: read(addr(0, 3, 0x12 + pick(2)), 1); last_op = "time"; break;
    case 12: write(addr(0, 3, 0x10), {uint16_t(pick(16))}); last_op = "run"; break;
    case 13:
      if (pick(8) == 0) {
        load_programs(1u << pick(4) | 1u << pick(4));
        write(addr(0, 3, 0x10), {uint16_t(pick(16))});
      }
      break;
  }
  ticks(pick(200));
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 1;
  uint64_t cycles = argc > 2 ? std::strtoull(argv[2], nullptr, 0) : 1000000;
  rng = seed * 0x9E3779B97F4A7C15ull + 1;
  t = new Vlockstep;
  t->ena = 1;
  t->rst_n = 0;
  t->ui_in = 0b010;
  t->uio_in = 0xFF;
  ticks(5);
  t->rst_n = 1;
  ticks(4);
  load_programs(0xF);
  write(addr(0, 3, 0x10), {0xF});
  uint64_t ops = 0;
  while (cyc < cycles) {
    host_op();
    ops++;
  }
  std::printf("seed %llu: %llu cycles, %llu host operations, outputs equal every cycle; "
              "%llu status reads: %llu words waiting in inboxes, %llu in outboxes, running %llu, "
              "stopped by the debugger %llu\n",
              (unsigned long long)seed, (unsigned long long)cyc, (unsigned long long)ops,
              (unsigned long long)statuses, (unsigned long long)inbox_words,
              (unsigned long long)outbox_words, (unsigned long long)running,
              (unsigned long long)stopped);
  t->final();
  delete t;
  return 0;
}
