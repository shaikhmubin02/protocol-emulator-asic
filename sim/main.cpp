// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// pemu_sim: the chip's RTL under Verilator with unmodified Linux software on the other end.
//
//   pemu_sim jtag [port]      jtag_tap.s on engine 0, as a TCP server for OpenOCD's
//                             remote_bitbang driver (default port 3335; see openocd_pemu.cfg)
//   pemu_sim jtag --selftest  the same TAP, scanned by a few lines of this program instead
//   pemu_sim modbus           modbus.s on engine 0 behind a pseudo-terminal, for mbpoll or any
//                             Modbus RTU client (115200 bit/s 8E1, server address 1)
//   pemu_sim modbus --selftest  one read request sent by this program instead
//
// The firmware hex files are read from build/ (the Makefile assembles them).

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "chip.h"

namespace {

// jtag_tap.s pins: TCK ui[4], TMS ui[5], TDI ui[6]; TDO on uio[0] (released outside Shift-DR/IR)
struct Jtag {
  uint8_t tck = 0, tms = 1, tdi = 0;
  // cycles per remote_bitbang write: the TAP firmware needs 7 or more per half period of TCK
  int cycles_per_write = 16;
};

int tdo(Chip& c) { return (c.uio_oe() & 1) ? (c.uio_out() & 1) : 1; }

void setup_tap(Chip& chip, Jtag& j) {
  chip.board = [&j](Chip& c) {
    c.ui_proto = (j.tck << 4) | (j.tms << 5) | (j.tdi << 6);
    c.uio_in = 0xFE | tdo(c);
  };
  chip.load(0, read_hex("build/jtag_tap.hex"));
  chip.own(0, 0);  // uio[0] (TDO) belongs to engine 0
  chip.run(1);
  // the IDCODE (bits 15:0, then 31:16) and USER's first value
  for (uint16_t w : {0xFEE1, 0x1C0F, 0x1234})
    while (!chip.send(0, w)) chip.ticks(16);
}

void set(Chip& chip, Jtag& j, int tck, int tms, int tdi) {
  j.tck = tck;
  j.tms = tms;
  j.tdi = tdi;
  chip.ticks(j.cycles_per_write);
}

// one TCK period with TMS and TDI; TDO as read before the rising edge
int clock_bit(Chip& chip, Jtag& j, int tms, int tdi) {
  set(chip, j, 0, tms, tdi);
  int out = tdo(chip);
  set(chip, j, 1, tms, tdi);
  return out;
}

int selftest() {
  Chip chip;
  Jtag j;
  setup_tap(chip, j);
  for (int k = 0; k < 5; k++) clock_bit(chip, j, 1, 0);  // Test-Logic-Reset
  for (int tms : {0, 1, 0, 0}) clock_bit(chip, j, tms, 0);  // to Shift-DR
  uint32_t id = 0;
  for (int k = 0; k < 32; k++) id |= uint32_t(clock_bit(chip, j, k == 31, 0)) << k;
  for (int tms : {1, 0}) clock_bit(chip, j, tms, 0);
  std::printf("IDCODE %08x after %llu cycles\n", id, (unsigned long long)chip.cycle());
  return id == 0x1C0FFEE1 ? 0 : 1;
}

int serve_jtag(int port) {
  Chip chip;
  Jtag j;
  setup_tap(chip, j);
  int s = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (sockaddr*)&a, sizeof a) < 0 || listen(s, 1) < 0) {
    std::perror("bind");
    return 1;
  }
  std::printf("jtag_tap.s waiting for OpenOCD on 127.0.0.1:%d\n", port);
  std::fflush(stdout);
  int c = accept(s, nullptr, nullptr);
  setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  auto t0 = std::chrono::steady_clock::now();
  uint64_t c0 = chip.cycle(), writes = 0, reads = 0;
  char buf[4096];
  bool quit = false;
  while (!quit) {
    ssize_t n = recv(c, buf, sizeof buf, 0);
    if (n <= 0) break;
    std::string reply;
    for (ssize_t k = 0; k < n; k++) {
      char ch = buf[k];
      if (ch >= '0' && ch <= '7') {
        int v = ch - '0';
        set(chip, j, (v >> 2) & 1, (v >> 1) & 1, v & 1);
        writes++;
      } else if (ch == 'R') {
        reply += char('0' + tdo(chip));
        reads++;
      } else if (ch == 'Q') {
        quit = true;
      }
      // 'B'/'b' (LED) and 'r'..'u' (TRST/SRST: this TAP has neither) need nothing
    }
    if (!reply.empty()) send(c, reply.data(), reply.size(), 0);
  }
  double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  uint64_t cyc = chip.cycle() - c0;
  std::printf("%llu writes, %llu reads, %llu cycles in %.2f s (%.2f MHz simulated)\n",
              (unsigned long long)writes, (unsigned long long)reads, (unsigned long long)cyc, secs,
              cyc / secs / 1e6);
  close(c);
  close(s);
  return 0;
}

// ---- Modbus RTU: modbus.s on engine 0 behind a pseudo-terminal, for mbpoll or any Modbus
// client. The serial line runs at 115200 bit/s 8E1 in simulated time; this program also plays
// the host microcontroller that keeps the registers.

constexpr double kBit = 50e6 / 115200;  // cycles a bit

// characters from the client to the chip's RX pin (ui[3])
struct UartOut {
  std::deque<uint8_t> queue;
  int bit = -1;  // -1: idle
  uint16_t frame = 0;
  double next = 0;
  int level(uint64_t cycle) {
    if (bit < 0) {
      if (queue.empty()) return 1;
      uint8_t b = queue.front();
      queue.pop_front();
      frame = uint16_t(b << 1) | uint16_t((__builtin_popcount(b) & 1) << 9) | uint16_t(1 << 10);
      bit = 0;
      next = double(cycle);
    }
    int l = (frame >> bit) & 1;
    if (double(cycle) + 1 >= next + kBit) {
      next += kBit;
      if (++bit == 11) bit = -1;
    }
    return l;
  }
};

// characters from the chip's TX pin (uo[0]) while its driver (uo[1]) is on
struct UartIn {
  int last = 1;
  bool busy = false;
  double start = 0;
  int k = 0;
  uint16_t v = 0;
  std::vector<uint8_t> got;
  void step(uint64_t cycle, int line) {
    if (!busy) {
      if (last == 1 && line == 0) {
        busy = true;
        start = double(cycle);
        k = 0;
        v = 0;
      }
    } else if (double(cycle) >= start + (k + 0.5) * kBit) {
      v |= uint16_t(line << k);
      if (++k == 11) {
        busy = false;
        got.push_back(uint8_t(v >> 1));
      }
    }
    last = line;
  }
};

struct Registers {
  uint16_t r[16];
  Registers() {
    for (int k = 0; k < 16; k++) r[k] = uint16_t(0x1000 + k);
  }
  // the reply's bytes from the function code on, for a request's bytes from the function code on
  std::vector<uint8_t> answer(const std::vector<uint8_t>& p) {
    auto word = [&](int i) { return (p[i] << 8) | p[i + 1]; };
    if (p.size() == 5 && p[0] == 0x03) {
      int a = word(1), n = word(3);
      if (n == 0 || a + n > 16) return {0x83, 0x02};
      std::vector<uint8_t> out = {0x03, uint8_t(2 * n)};
      for (int k = 0; k < n; k++) {
        out.push_back(r[a + k] >> 8);
        out.push_back(r[a + k] & 0xFF);
      }
      return out;
    }
    if (p.size() == 5 && p[0] == 0x06) {
      int a = word(1);
      if (a >= 16) return {0x86, 0x02};
      r[a] = uint16_t(word(3));
      return p;
    }
    if (p.size() >= 6 && p[0] == 0x10) {
      int a = word(1), n = word(3);
      if (a + n > 16 || int(p.size()) != 6 + 2 * n) return {0x90, 0x02};
      for (int k = 0; k < n; k++) r[a + k] = uint16_t(word(6 + 2 * k));
      return {0x10, p[1], p[2], p[3], p[4]};
    }
    return {uint8_t(0x80 | (p.empty() ? 0 : p[0])), 0x01};
  }
};

uint16_t crc16(const std::vector<uint8_t>& bytes) {
  uint16_t c = 0xFFFF;
  for (uint8_t b : bytes) {
    c ^= b;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xA001 : c >> 1;
  }
  return c;
}

struct Modbus {
  Chip chip;
  UartOut to_chip;
  UartIn from_chip;
  Registers regs;
  std::vector<uint8_t> pdu;
  uint64_t requests = 0;

  Modbus() {
    chip.board = [this](Chip& c) {
      int de = (c.uo() >> 1) & 1;
      int rx = to_chip.level(c.cycle());
      from_chip.step(c.cycle(), de ? (c.uo() & 1) : 1);
      // RS-485: the bus is the chip's TX while its driver is on; its receiver is off then
      c.ui_proto = uint8_t((de ? 1 : rx) << 3);
    };
    chip.load(0, read_hex("build/modbus.hex"));
    chip.own(8, 0);  // uo[0] TX
    chip.own(9, 0);  // uo[1] driver enable
    chip.run(1);
    for (uint16_t w : {434, 7, 1})  // 115200 bit/s at 50 MHz, server address 1
      while (!chip.send(0, w)) chip.ticks(100);
  }

  // the host microcontroller's side: the words from the chip
  void service() {
    for (uint16_t w : chip.receive(0)) {
      if ((w & 0xFF00) == 0x0100) {
        pdu.push_back(uint8_t(w));
      } else {
        if ((w & 0x8000) && !(w & 0x4000)) {
          auto reply = regs.answer(pdu);
          std::vector<uint16_t> words = {uint16_t(reply.size())};
          for (uint8_t b : reply) words.push_back(b);
          for (uint16_t x : words)
            while (!chip.send(0, x)) chip.ticks(100);
        } else if (w & 0x8000) {
          regs.answer(pdu);  // a broadcast: do it, no reply
        }
        requests++;
        pdu.clear();
      }
    }
  }
};

int modbus_selftest() {
  Modbus m;
  std::vector<uint8_t> req = {0x01, 0x03, 0x00, 0x00, 0x00, 0x02};
  uint16_t c = crc16(req);
  req.push_back(c & 0xFF);
  req.push_back(c >> 8);
  for (uint8_t b : req) m.to_chip.queue.push_back(b);
  for (int k = 0; k < 100 && m.from_chip.got.size() < 9; k++) {
    m.chip.ticks(2000);
    m.service();
  }
  std::printf("reply:");
  for (uint8_t b : m.from_chip.got) std::printf(" %02x", b);
  bool ok = m.from_chip.got.size() == 9 && crc16(m.from_chip.got) == 0;
  std::printf(" (%s) after %llu cycles\n", ok ? "CRC good" : "WRONG", (unsigned long long)m.chip.cycle());
  return ok ? 0 : 1;
}

int serve_modbus() {
  Modbus m;
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
    std::perror("pty");
    return 1;
  }
  termios t{};
  tcgetattr(master, &t);
  cfmakeraw(&t);
  tcsetattr(master, TCSANOW, &t);
  fcntl(master, F_SETFL, O_NONBLOCK);
  std::printf("modbus.s, server address 1, on %s (try: mbpoll -m rtu -a 1 -b 115200 -P even -t 4 -r 1 -c 4 %s)\n",
              ptsname(master), ptsname(master));
  std::fflush(stdout);
  size_t sent = 0;
  auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    uint8_t buf[256];
    ssize_t n = read(master, buf, sizeof buf);
    for (ssize_t k = 0; k < n; k++) m.to_chip.queue.push_back(buf[k]);
    if (m.to_chip.queue.empty() && !m.from_chip.busy && m.to_chip.bit < 0) {
      // nothing on the line: let simulated time stand still instead of spinning
      usleep(200);
    }
    m.chip.ticks(2000);
    m.service();
    if (m.from_chip.got.size() > sent) {
      ssize_t w = write(master, m.from_chip.got.data() + sent, m.from_chip.got.size() - sent);
      if (w > 0) sent += size_t(w);
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (secs > 1 && m.requests && m.chip.cycle() % 1000000 < 2000) {
      std::printf("%llu frames, %llu cycles simulated\n", (unsigned long long)m.requests,
                  (unsigned long long)m.chip.cycle());
      std::fflush(stdout);
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::string cmd = argc > 1 ? argv[1] : "";
  bool self = argc > 2 && std::string(argv[2]) == "--selftest";
  if (cmd == "jtag") return self ? selftest() : serve_jtag(argc > 2 ? std::atoi(argv[2]) : 3335);
  if (cmd == "modbus") return self ? modbus_selftest() : serve_modbus();
  std::fprintf(stderr, "usage: pemu_sim jtag [port | --selftest] | modbus [--selftest]\n");
  return 2;
}
