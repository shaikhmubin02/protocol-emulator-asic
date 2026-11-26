// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// The chip as a USB low-speed keyboard, with Linux on the other end through USB/IP.
//
// On the chip: usb_dev_rx.s (engine 0) receives, usb_dev_tx.s (engine 1) answers; together they
// do all of the wire protocol (NRZI, bit stuffing, CRC-5 and CRC-16, ACK / NAK / STALL, DATA0 /
// DATA1, the turnaround time). Around the chip, as on a board:
//   Host    a USB low-speed host on D+ (uio[4]) and D- (uio[5]), cycle by cycle at 48 MHz: it
//           plays the host's packets onto the pins and decodes the chip's from them;
//   Board   the processor next to the chip, through the chip's SPI host port only: it holds the
//           descriptors, answers requests and has key reports to send (as hw/test/usb_board.ml);
//   Bridge  a USB/IP server: Linux's vhci_hcd sends it URBs over TCP, the bridge runs each one as
//           transactions on the pins and sends back what the chip answered.
// vhci_hcd answers SET_ADDRESS itself, so the bridge resets and addresses the device on the
// wire before Linux sees it. Everything else Linux asks goes to the chip.

#include "usb.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "chip.h"

namespace usb {
namespace {

using Bytes = std::vector<uint8_t>;

constexpr int kBit = 32;  // 48 MHz / 1.5 Mbit/s
constexpr uint8_t kOut = 0xE1, kIn = 0x69, kSetup = 0x2D, kData0 = 0xC3, kData1 = 0x4B,
                  kAck = 0xD2, kNak = 0x5A, kStall = 0x1E;

enum Line : uint8_t { kJ, kK, kSe0, kSe1 };

uint16_t crc16(const Bytes& d) {
  uint16_t c = 0xFFFF;
  for (uint8_t b : d)
    for (int k = 0; k < 8; k++) {
      int fb = (c ^ (b >> k)) & 1;
      c >>= 1;
      if (fb) c ^= 0xA001;
    }
  return c;
}

// the two bytes after a token's PID: address, endpoint, CRC-5 (USB 2.0 8.3.5.1)
Bytes token_bytes(int addr, int ep) {
  int bits[11];
  for (int k = 0; k < 7; k++) bits[k] = (addr >> k) & 1;
  for (int k = 0; k < 4; k++) bits[7 + k] = (ep >> k) & 1;
  int c = 0x1F;
  for (int b : bits) {
    int fb = ((c >> 4) & 1) ^ b;
    c = (c << 1) & 0x1F;
    if (fb) c ^= 0x05;
  }
  c ^= 0x1F;
  uint16_t v = addr | (ep << 7);
  for (int k = 0; k < 5; k++) v |= ((c >> (4 - k)) & 1) << (11 + k);
  return {uint8_t(v & 0xFF), uint8_t(v >> 8)};
}

// SYNC, the bytes bit-stuffed and NRZI-coded from J, then SE0 SE0 J
std::vector<Line> line_states(const Bytes& bytes) {
  Line line = kJ;
  int ones = 0;
  std::vector<Line> out;
  auto toggle = [&] { line = line == kJ ? kK : kJ; };
  auto send = [&](int b) {
    if (b == 0) {
      toggle();
      ones = 0;
    } else {
      ones++;
    }
    out.push_back(line);
    if (ones == 6) {
      toggle();
      ones = 0;
      out.push_back(line);
    }
  };
  Bytes all = {0x80};
  all.insert(all.end(), bytes.begin(), bytes.end());
  for (uint8_t byte : all)
    for (int k = 0; k < 8; k++) send((byte >> k) & 1);
  out.insert(out.end(), {kSe0, kSe0, kJ});
  return out;
}

bool is_data(uint8_t pid) { return pid == kData0 || pid == kData1; }

std::vector<Line> packet(uint8_t pid, const Bytes& data = {}) {
  Bytes b = {pid};
  b.insert(b.end(), data.begin(), data.end());
  if (is_data(pid)) {
    uint16_t c = ~crc16(data);
    b.push_back(c & 0xFF);
    b.push_back(c >> 8);
  }
  return line_states(b);
}

// what the host got back: a PID (0: no answer, or not a packet) and, for data, the bytes
struct Res {
  uint8_t pid = 0;
  Bytes data;
};

// ---------------------------------------------------------------------------------------------
// the host on the wire

class Host {
 public:
  uint64_t now = 0;
  uint64_t answers = 0, naks = 0, timeouts = 0, collisions = 0, bad = 0;
  double ta_min = 1e9, ta_max = 0;

  bool idle() const { return phase_ == kFree; }

  // once a cycle, from the chip's board callback (before the clock edge)
  void cycle(Chip& c) {
    now++;
    uint8_t oe = c.uio_oe(), out = c.uio_out();
    int hdp = 0, hdm = 1;  // nobody driving: J, from the device's pull-up on D-
    switch (phase_) {
      case kWaiting:
        drive_ = -1;
        if (now >= until_) {
          phase_ = kFree;
          auto f = std::move(next_);
          f();
        }
        break;
      case kPlaying: {
        uint64_t k = (now - start_) / kBit;
        if (k < states_.size()) {
          drive_ = states_[k];
        } else {
          drive_ = -1;
          phase_ = kFree;
          auto f = std::move(next_);
          f();
        }
        break;
      }
      default:
        drive_ = -1;
    }
    if (drive_ >= 0) {
      hdp = drive_ == kK || drive_ == kSe1;
      hdm = drive_ == kJ || drive_ == kSe1;
      if (oe & 0x30) collisions++;
    }
    int dp = (oe & 0x10) ? (out >> 4) & 1 : hdp;
    int dm = (oe & 0x20) ? (out >> 5) & 1 : hdm;
    Line l = dp ? (dm ? kSe1 : kK) : (dm ? kJ : kSe0);
    if (phase_ == kListening) listen_step(l);
    last_ = l;
    c.uio_in = uint8_t((0xFF & ~0x30) | (hdp << 4) | (hdm << 5));
  }

  void play(std::vector<Line> s, std::function<void()> next) {
    states_ = std::move(s);
    start_ = now + 1;
    next_ = std::move(next);
    phase_ = kPlaying;
  }
  void wait(uint64_t cycles, std::function<void()> next) {
    until_ = now + cycles;
    next_ = std::move(next);
    phase_ = kWaiting;
  }
  // a new transaction: at least 2 bit times of idle line since the last packet (7.1.18); 3 here
  void begin(std::vector<Line> s, std::function<void()> next) {
    wait(3 * kBit, [this, s = std::move(s), next = std::move(next)]() mutable {
      play(std::move(s), std::move(next));
    });
  }
  void listen(std::function<void(Res)> k) {
    from_ = now;
    first_k_ = 0;
    se0_at_ = 0;
    tr_.clear();
    k_ = std::move(k);
    phase_ = kListening;
  }

  // ---- transactions (8.5)
  void setup(int addr, const Bytes& d, std::function<void(Res)> k) {
    auto s = packet(kSetup, token_bytes(addr, 0));
    s.insert(s.end(), {kJ, kJ});
    auto p = packet(kData0, d);
    s.insert(s.end(), p.begin(), p.end());
    begin(std::move(s), [this, k = std::move(k)]() mutable { listen(std::move(k)); });
  }
  // IN: good data is acknowledged before [k] runs
  void in(int addr, int ep, std::function<void(Res)> k) {
    begin(packet(kIn, token_bytes(addr, ep)), [this, k = std::move(k)]() mutable {
      listen([this, k = std::move(k)](Res r) mutable {
        if (is_data(r.pid)) {
          wait(3 * kBit, [this, r, k = std::move(k)]() mutable {
            play(packet(kAck), [r, k = std::move(k)] { k(r); });
          });
        } else {
          k(r);
        }
      });
    });
  }
  void out(int addr, int ep, uint8_t pid, const Bytes& d, std::function<void(Res)> k) {
    auto s = packet(kOut, token_bytes(addr, ep));
    s.insert(s.end(), {kJ, kJ});
    auto p = packet(pid, d);
    s.insert(s.end(), p.begin(), p.end());
    begin(std::move(s), [this, k = std::move(k)]() mutable { listen(std::move(k)); });
  }
  void reset(uint64_t cycles, std::function<void()> k) {
    std::vector<Line> s(cycles / kBit + 1, kSe0);
    s.push_back(kJ);
    begin(std::move(s), [this, cycles, k = std::move(k)]() mutable { wait(cycles, std::move(k)); });
  }

 private:
  enum Phase { kFree, kPlaying, kListening, kWaiting } phase_ = kFree;
  int drive_ = -1;
  std::vector<Line> states_;
  uint64_t start_ = 0, until_ = 0, from_ = 0, first_k_ = 0, se0_at_ = 0;
  std::function<void()> next_;
  std::function<void(Res)> k_;
  std::vector<std::pair<uint64_t, Line>> tr_;
  Line last_ = kJ;

  void finish(Res r) {
    phase_ = kFree;
    auto k = std::move(k_);
    k(std::move(r));
  }

  void listen_step(Line l) {
    if (!first_k_) {
      if (l == kK) {
        first_k_ = now;
        tr_.push_back({now, l});
      } else if (now - from_ > 17 * kBit) {
        timeouts++;  // 16 to 18 bit times with no SYNC (8.7.3)
        finish({});
      }
      return;
    }
    if (l != last_) {
      tr_.push_back({now, l});
      if (l == kSe0) se0_at_ = now;
      if (l == kJ && last_ == kSe0) {
        double ta = double(first_k_ - from_) / kBit + 1;
        ta_min = std::min(ta_min, ta);
        ta_max = std::max(ta_max, ta);
        answers++;
        Res r = decode();
        if (r.pid == kNak) naks++;
        finish(std::move(r));
        return;
      }
    }
    if (now - first_k_ > 120 * kBit) {
      bad++;
      finish({});
    }
  }

  // sample the middle of each bit on the grid set by the first K, undo NRZI and stuffing
  Res decode() {
    int n = int((se0_at_ - first_k_ + kBit / 2) / kBit);
    auto level_at = [&](uint64_t t) {
      Line v = kK;
      for (auto& [at, ln] : tr_)
        if (at <= t) v = ln;
      return v;
    };
    Line prev = kJ;
    int ones = 0;
    std::vector<int> bits;
    for (int k = 0; k < n; k++) {
      Line v = level_at(first_k_ + uint64_t(k) * kBit + kBit / 2);
      int b = v == prev;
      prev = v;
      if (ones == 6) {
        if (b) bad++;
        ones = 0;
        continue;
      }
      bits.push_back(b);
      ones = b ? ones + 1 : 0;
    }
    if (bits.size() % 8 || bits.size() < 16) {
      bad++;
      return {};
    }
    Bytes bytes;
    for (size_t i = 0; i < bits.size(); i += 8) {
      uint8_t v = 0;
      for (int k = 0; k < 8; k++) v |= bits[i + k] << k;
      bytes.push_back(v);
    }
    uint8_t pid = bytes[1];
    if (bytes[0] != 0x80 || ((pid >> 4) ^ 0xF) != (pid & 0xF)) {
      bad++;
      return {};
    }
    Res r{pid, Bytes(bytes.begin() + 2, bytes.end())};
    if (is_data(pid)) {
      if (r.data.size() < 2) {
        bad++;
        return {};
      }
      uint16_t sent = r.data[r.data.size() - 2] | (r.data.back() << 8);
      r.data.resize(r.data.size() - 2);
      if (uint16_t(~crc16(r.data)) != sent) {
        bad++;
        return {};
      }
    }
    return r;
  }
};

// ---------------------------------------------------------------------------------------------
// control transfers (8.5.3) and interrupt IN, with the retries a host controller does

constexpr int kStalled = -32, kNoAnswer = -71;

struct Control {
  Host& h;
  int addr;
  Bytes setup;
  Bytes out_data;
  int want;  // wLength for a read
  std::function<void(int, Bytes)> done;
  Bytes got;
  int errors = 0;
  uint8_t toggle = kData1;
  size_t sent = 0;

  void start() {
    h.setup(addr, setup, [this](Res r) {
      if (r.pid == kAck) return data_stage();
      if (++errors < 3) return h.wait(20 * kBit, [this] { start(); });
      done(kNoAnswer, {});
    });
  }
  void data_stage() {
    errors = 0;
    if (setup[0] & 0x80) return read_next();
    if (!out_data.empty()) return write_next();
    status_in();
  }
  void read_next() {
    h.in(addr, 0, [this](Res r) {
      if (r.pid == kNak) return h.wait(40 * kBit, [this] { read_next(); });
      if (r.pid == kStall) return done(kStalled, {});
      if (!is_data(r.pid)) {
        if (++errors < 3) return h.wait(20 * kBit, [this] { read_next(); });
        return done(kNoAnswer, {});
      }
      if (r.pid != toggle) return h.wait(40 * kBit, [this] { read_next(); });  // a repeat
      toggle = toggle == kData1 ? kData0 : kData1;
      got.insert(got.end(), r.data.begin(), r.data.end());
      if (r.data.size() < 8 || int(got.size()) >= want) return status_out();
      h.wait(20 * kBit, [this] { read_next(); });
    });
  }
  void status_out() {
    h.out(addr, 0, kData1, {}, [this](Res r) {
      if (r.pid == kAck) return done(0, got);
      if (r.pid == kNak || (r.pid == 0 && ++errors < 3))
        return h.wait(40 * kBit, [this] { status_out(); });
      done(r.pid == kStall ? kStalled : kNoAnswer, {});
    });
  }
  void write_next() {
    Bytes chunk(out_data.begin() + sent, out_data.begin() + std::min(out_data.size(), sent + 8));
    h.out(addr, 0, toggle, chunk, [this, n = chunk.size()](Res r) {
      if (r.pid == kNak || (r.pid == 0 && ++errors < 3))
        return h.wait(40 * kBit, [this] { write_next(); });
      if (r.pid != kAck) return done(r.pid == kStall ? kStalled : kNoAnswer, {});
      toggle = toggle == kData1 ? kData0 : kData1;
      sent += n;
      if (sent < out_data.size()) return h.wait(20 * kBit, [this] { write_next(); });
      h.wait(20 * kBit, [this] { status_in(); });
    });
  }
  void status_in() {
    h.in(addr, 0, [this](Res r) {
      if (r.pid == kData1 && r.data.empty()) return done(0, {});
      if (r.pid == kStall) return done(kStalled, {});
      if (r.pid == kNak || (r.pid == 0 && ++errors < 3))
        return h.wait(40 * kBit, [this] { status_in(); });
      done(kNoAnswer, {});
    });
  }
};

// ---------------------------------------------------------------------------------------------
// the board processor (the same as hw/test/usb_board.ml), through the SPI host port only

uint16_t reg_addr(int e, int r) { return (e << 14) | (2 << 12) | (0x10 + r); }
uint16_t config_addr(int e, int word) { return (e << 14) | (1 << 12) | (2 * word); }

const Bytes kDevice = {18, 1, 0x10, 0x01, 0, 0, 0, 8, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01, 1, 2, 0, 1};
const Bytes kReport = {0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15,
                       0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08,
                       0x81, 0x01, 0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91,
                       0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
                       0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0};
const Bytes kConfig = {9, 2, 34, 0, 1, 1, 0, 0x80, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0,
                       9, 0x21, 0x11, 0x01, 0, 1, 0x22, uint8_t(kReport.size()), 0,
                       7, 5, 0x81, 3, 8, 0, 10};

Bytes string_descriptor(const std::string& s) {
  Bytes d = {uint8_t(2 + 2 * s.size()), 3};
  for (char c : s) d.insert(d.end(), {uint8_t(c), 0});
  return d;
}
const std::vector<Bytes> kStrings = {{4, 3, 0x09, 0x04}, string_descriptor("pemu"),
                                     string_descriptor("pemu keyboard")};

// typing [text] on a US keyboard: a report with the key, then one with no key
std::deque<Bytes> type(const std::string& text) {
  std::deque<Bytes> r;
  for (char c : text) {
    uint8_t code = 0, mod = 0;
    if (c >= 'a' && c <= 'z') code = 0x04 + (c - 'a');
    else if (c >= 'A' && c <= 'Z') code = 0x04 + (c - 'A'), mod = 0x02;
    else if (c >= '1' && c <= '9') code = 0x1E + (c - '1');
    else if (c == '0') code = 0x27;
    else if (c == '\n') code = 0x28;
    else if (c == ' ') code = 0x2C;
    else if (c == '.') code = 0x37;
    else if (c == '-') code = 0x2D;
    else continue;
    r.push_back({mod, 0, code, 0, 0, 0, 0, 0});
    r.push_back({0, 0, 0, 0, 0, 0, 0, 0});
  }
  return r;
}

struct Held {
  int ep;
  uint8_t pid;
  Bytes data;
};

class Board {
 public:
  explicit Board(Chip& c) : chip_(c) {}
  std::deque<Bytes> reports;  // key reports still to send
  // typed once the computer turns the Caps Lock LED on (SET_REPORT), so the typing starts
  // when someone on the other end is listening
  std::string on_caps_lock;
  int leds = -1;
  std::vector<std::string> log;

  // one round: read what engine 0 has, act on it, keep engine 1 fed
  void poll() {
    for (uint16_t w : chip_.receive(0)) handle(w);
    feed();
  }

 private:
  Chip& chip_;
  int addr_ = 0, new_addr_ = -1;
  std::deque<Held> ep0_;
  std::deque<Held> after_out_;
  bool holding_ = false, configured_ = false;
  Held held_{};
  uint8_t ep1_pid_ = kData0;

  static uint16_t token_value(int addr) {
    Bytes b = token_bytes(addr, 0);
    return b[0] | (b[1] << 8);
  }
  void to_inbox(int e, const std::vector<uint16_t>& words) {
    for (uint16_t w : words)
      while (!chip_.send(e, w)) chip_.ticks(16);
  }
  void load(const Held& p) {
    uint16_t header = (p.data.size() << 12) | (is_data(p.pid) << 11) | (p.ep << 10) | p.pid;
    std::vector<uint16_t> words;
    for (size_t i = 0; i < p.data.size(); i += 2)
      words.push_back(p.data[i] | (i + 1 < p.data.size() ? p.data[i + 1] << 8 : 0));
    std::vector<uint16_t> all = {header};
    all.insert(all.end(), words.rbegin(), words.rend());  // the last word first
    to_inbox(1, all);
    held_ = p;
    holding_ = true;
  }
  void clear_tx() {
    to_inbox(1, {0});
    holding_ = false;
  }
  void feed() {
    if (!ep0_.empty() && !holding_) return load(ep0_.front());
    if (!ep0_.empty() && holding_ && held_.ep == 1) {
      clear_tx();
      return load(ep0_.front());
    }
    if (ep0_.empty() && !holding_ && configured_ && after_out_.empty() && !reports.empty())
      load({1, ep1_pid_, reports.front()});
  }
  std::deque<Held> reply(const Bytes& data, size_t len) {
    Bytes d(data.begin(), data.begin() + std::min(len, data.size()));
    std::deque<Held> out;
    uint8_t pid = kData1;
    for (size_t i = 0; i < d.size(); i += 8) {
      out.push_back({0, pid, Bytes(d.begin() + i, d.begin() + std::min(d.size(), i + 8))});
      pid = pid == kData1 ? kData0 : kData1;
    }
    if (d.size() < len && d.size() % 8 == 0) out.push_back({0, pid, {}});
    return out;
  }
  void setup(const Bytes& b) {
    int typ = b[0], req = b[1], value = b[2] | (b[3] << 8), len = b[6] | (b[7] << 8);
    char s[64];
    std::snprintf(s, sizeof s, "SETUP %02x %02x %02x %02x %02x %02x %02x %02x", b[0], b[1], b[2], b[3],
                  b[4], b[5], b[6], b[7]);
    log.push_back(s);
    if (holding_) clear_tx();
    after_out_.clear();
    const Held zlp{0, kData1, {}}, stall{0, kStall, {}};
    if (typ == 0x80 && req == 6) {
      int t = value >> 8, i = value & 0xFF;
      if (t == 1) ep0_ = reply(kDevice, len);
      else if (t == 2 && i == 0) ep0_ = reply(kConfig, len);
      else if (t == 3 && i < int(kStrings.size())) ep0_ = reply(kStrings[i], len);
      else ep0_ = {stall};
    } else if (typ == 0x81 && req == 6 && (value >> 8) == 0x22) {
      ep0_ = reply(kReport, len);
    } else if (typ == 0x00 && req == 5) {
      new_addr_ = value & 0x7F;
      ep0_ = {zlp};
    } else if (typ == 0x00 && req == 9) {
      configured_ = value == 1;
      ep1_pid_ = kData0;
      ep0_ = {zlp};
    } else if (typ == 0x80 && req == 8) {
      ep0_ = reply({uint8_t(configured_ ? 1 : 0)}, len);
    } else if ((typ == 0x80 || typ == 0x81 || typ == 0x82) && req == 0) {
      ep0_ = reply({0, 0}, len);  // GET_STATUS
    } else if ((typ == 0x01 && req == 11) || (typ == 0x02 && req == 1) ||
               (typ == 0x21 && (req == 0x0A || req == 0x0B))) {
      ep0_ = {zlp};  // SET_INTERFACE 0, CLEAR_FEATURE(halt), SET_IDLE, SET_PROTOCOL
    } else if (typ == 0x21 && req == 0x09) {
      after_out_ = {zlp};  // SET_REPORT: the LEDs come in the OUT data stage
      ep0_.clear();
    } else {
      ep0_ = {stall};
    }
  }
  Bytes read_data(int count) {
    int n = std::min(count - 2, 8), kept = std::min(count, 8), words = (kept + 1) / 2;
    if (n <= 0) return {};
    auto regs = chip_.read(reg_addr(0, 4), 4);
    Bytes out;
    for (int i = 4 - words; i < 4; i++) out.insert(out.end(), {uint8_t(regs[i] & 0xFF), uint8_t(regs[i] >> 8)});
    out.resize(n);
    return out;
  }
  void handle(uint16_t w) {
    switch (w >> 12) {
      case 4:
        log.push_back("bus reset");
        addr_ = 0;
        new_addr_ = -1;
        ep0_.clear();
        after_out_.clear();
        configured_ = false;
        if (holding_) clear_tx();
        break;
      case 1: {
        Bytes b = read_data((w >> 8) & 0xF);
        to_inbox(0, {token_value(addr_)});
        if (b.size() == 8) setup(b);
        break;
      }
      case 2: {
        Bytes b = read_data((w >> 8) & 0xF);
        to_inbox(0, {token_value(addr_)});
        if (b.size() == 1 && !after_out_.empty()) {
          leds = b[0];
          log.push_back("LEDs " + std::to_string(leds));
          if ((leds & 0x02) && !on_caps_lock.empty()) {
            for (auto& r : type(on_caps_lock)) reports.push_back(r);
            on_caps_lock.clear();
          }
          ep0_ = after_out_;
          after_out_.clear();
        }
        break;
      }
      case 3: {
        int ep = w & 1;
        if (holding_ && held_.ep == ep) {
          holding_ = false;
          if (ep == 0) {
            if (!ep0_.empty()) ep0_.pop_front();
            if (ep0_.empty() && new_addr_ >= 0) {
              addr_ = new_addr_;
              new_addr_ = -1;
              to_inbox(0, {token_value(addr_)});
              log.push_back("address " + std::to_string(addr_));
            }
          } else {
            if (!reports.empty()) reports.pop_front();
            ep1_pid_ = ep1_pid_ == kData0 ? kData1 : kData0;
          }
        }
        break;
      }
    }
  }
};

// the chip with the two programs, their fabric configurations and the CRC-16 settings
void bring_up(Chip& chip) {
  chip.load(0, read_hex("build/usb_dev_rx.hex"));
  chip.load(1, read_hex("build/usb_dev_tx.hex"));
  for (int e = 0; e < 2; e++) {
    std::FILE* f = std::fopen(e == 0 ? "build/usb_rx.fabric" : "build/usb_tx.fabric", "r");
    if (!f) throw std::runtime_error("no fabric file in build/");
    unsigned v;
    for (int k = 0; k < 8 && std::fscanf(f, "%x", &v) == 1; k++)
      chip.write(config_addr(e, k), {uint16_t(v & 0xFFFF), uint16_t(v >> 16)});
    std::fclose(f);
    uint32_t poly = 0x8005u << 16, init = 0xFFFFu << 16;
    chip.write(config_addr(e, 16), {uint16_t(poly & 0xFFFF), uint16_t(poly >> 16)});
    chip.write(config_addr(e, 17), {uint16_t(init & 0xFFFF), uint16_t(init >> 16)});
  }
  chip.own(4, 1);  // D+ and D- belong to the transmitting engine
  chip.own(5, 1);
  chip.run(0b11);
}

// run the board processor until [done] (the host runs inside the chip's clock callback)
void run_until(Board& b, const std::function<bool()>& done) {
  while (!done()) b.poll();
}

std::string hex(const Bytes& d) {
  std::string s;
  char t[4];
  for (uint8_t b : d) {
    std::snprintf(t, sizeof t, "%02x ", b);
    s += t;
  }
  if (!s.empty()) s.pop_back();
  return s;
}

Bytes request(int typ, int req, int value, int index, int len) {
  return {uint8_t(typ), uint8_t(req), uint8_t(value), uint8_t(value >> 8),
          uint8_t(index), uint8_t(index >> 8), uint8_t(len), uint8_t(len >> 8)};
}

// one control transfer, run to its end
std::pair<int, Bytes> control(Host& h, Board& b, int addr, const Bytes& setup, const Bytes& out = {}) {
  bool finished = false;
  std::pair<int, Bytes> result;
  Control c{h, addr, setup, out, setup[6] | (setup[7] << 8), [&](int st, Bytes d) {
              result = {st, std::move(d)};
              finished = true;
            }};
  c.start();
  run_until(b, [&] { return finished; });
  return result;
}

// the bridge's own start: reset, address 1, the device descriptor
constexpr int kAddr = 1;
Bytes enumerate(Host& h, Board& b) {
  bool done = false;
  h.reset(20 * 48, [&] { done = true; });  // 20 us; the device sees a reset after 4 us
  run_until(b, [&] { return done; });
  control(h, b, 0, request(0x00, 5, kAddr, 0, 0));
  done = false;
  h.wait(48 * 100, [&] { done = true; });  // SET_ADDRESS recovery
  run_until(b, [&] { return done; });
  return control(h, b, kAddr, request(0x80, 6, 0x0100, 0, 18)).second;
}

void print_stats(const Host& h, const Chip& chip, double secs) {
  std::printf("device answers: %llu, %.2f to %.2f bit times after the host's packet (2 to 6.5 "
              "allowed); NAKs %llu, no answer %llu, broken %llu, collisions %llu\n",
              (unsigned long long)h.answers, h.ta_min, h.ta_max, (unsigned long long)h.naks,
              (unsigned long long)h.timeouts, (unsigned long long)h.bad,
              (unsigned long long)h.collisions);
  std::printf("%llu cycles (%.1f ms of chip time at 48 MHz) in %.1f s\n",
              (unsigned long long)chip.cycle(), chip.cycle() / 48e3, secs);
}

// ---------------------------------------------------------------------------------------------
// USB/IP (the protocol of drivers/usb/usbip in Linux; all fields big-endian)

void put32(Bytes& b, uint32_t v) {
  for (int k = 3; k >= 0; k--) b.push_back(uint8_t(v >> (8 * k)));
}
void put16(Bytes& b, uint16_t v) {
  b.push_back(uint8_t(v >> 8));
  b.push_back(uint8_t(v));
}
uint32_t get32(const uint8_t* p) { return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }

bool send_all(int fd, const Bytes& b) {
  size_t off = 0;
  while (off < b.size()) {
    ssize_t n = send(fd, b.data() + off, b.size() - off, MSG_NOSIGNAL);
    if (n <= 0) return false;
    off += size_t(n);
  }
  return true;
}
bool recv_all(int fd, uint8_t* p, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t r = recv(fd, p + off, n - off, 0);
    if (r <= 0) return false;
    off += size_t(r);
  }
  return true;
}

// struct usbip_usb_device: path[256], busid[32], busnum, devnum, speed, idVendor, idProduct,
// bcdDevice, class, subclass, protocol, configuration value, configurations, interfaces
Bytes device_info(const Bytes& dd) {
  Bytes b(256 + 32, 0);
  std::snprintf((char*)b.data(), 256, "/sys/devices/pemu/usb1/1-1");
  std::snprintf((char*)b.data() + 256, 32, "1-1");
  put32(b, 1);
  put32(b, kAddr);
  put32(b, 1);  // USB_SPEED_LOW
  put16(b, dd[8] | (dd[9] << 8));
  put16(b, dd[10] | (dd[11] << 8));
  put16(b, dd[12] | (dd[13] << 8));
  b.insert(b.end(), {dd[4], dd[5], dd[6], 0, dd[17], 1});
  return b;
}

struct Urb {
  uint32_t seq;
  uint32_t dir;  // 0 out, 1 in
  uint32_t ep;
  uint32_t length;
  uint32_t packets;
  Bytes setup;
  Bytes out;
};

Bytes ret_submit(const Urb& u, int status, const Bytes& data) {
  Bytes b;
  put32(b, 3);
  put32(b, u.seq);
  put32(b, 0);
  put32(b, 0);
  put32(b, 0);
  put32(b, uint32_t(status));
  put32(b, u.dir ? uint32_t(data.size()) : (status == 0 ? u.length : 0));
  put32(b, 0);
  put32(b, u.packets);
  put32(b, 0);
  b.resize(48, 0);
  if (u.dir) b.insert(b.end(), data.begin(), data.end());
  return b;
}

}  // namespace

// ---------------------------------------------------------------------------------------------

int selftest() {
  auto t0 = std::chrono::steady_clock::now();
  Chip chip;
  Host h;
  chip.board = [&h](Chip& c) { h.cycle(c); };
  bring_up(chip);
  Board b(chip);
  std::string text = "pemu\n";
  b.reports = type(text);
  auto want = b.reports;
  Bytes dd = enumerate(h, b);
  std::printf("device descriptor: %s\n", hex(dd).c_str());
  auto cfg = control(h, b, kAddr, request(0x80, 6, 0x0200, 0, 34));
  std::printf("configuration:     %s\n", hex(cfg.second).c_str());
  auto prod = control(h, b, kAddr, request(0x80, 6, 0x0302, 0x0409, 255));
  std::string name;
  for (size_t i = 2; i < prod.second.size(); i += 2) name += char(prod.second[i]);
  std::printf("product string:    %s\n", name.c_str());
  control(h, b, kAddr, request(0x00, 9, 1, 0, 0));
  std::vector<Bytes> got;
  while (got.size() < want.size()) {
    bool done = false;
    h.in(kAddr, 1, [&](Res r) {
      if (is_data(r.pid)) got.push_back(r.data);
      done = true;
    });
    run_until(b, [&] { return done; });
  }
  bool same = true;
  for (size_t i = 0; i < want.size(); i++) same = same && got[i] == want[i];
  std::printf("key reports: %zu, %s\n", got.size(), same ? "the same as the board's" : "WRONG");
  print_stats(h, chip, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  bool ok = same && dd == kDevice && cfg.second == kConfig && name == "pemu keyboard" &&
            h.collisions == 0 && h.bad == 0;
  return ok ? 0 : 1;
}

int serve(int port) {
  auto t0 = std::chrono::steady_clock::now();
  Chip chip;
  Host h;
  chip.board = [&h](Chip& c) { h.cycle(c); };
  bring_up(chip);
  Board b(chip);
  b.on_caps_lock = "hello from the chip\n";
  Bytes dd = enumerate(h, b);
  if (dd != kDevice) {
    std::printf("the device did not enumerate: %s\n", hex(dd).c_str());
    return 1;
  }
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
  std::printf("pemu keyboard (1209:0001) at address %d, exported as busid 1-1 on 127.0.0.1:%d\n",
              kAddr, port);
  std::fflush(stdout);

  // the import: OP_REQ_DEVLIST (usbip list -r) can come first, on its own connection
  int c = -1;
  for (;;) {
    c = accept(s, nullptr, nullptr);
    uint8_t hdr[8];
    if (!recv_all(c, hdr, 8)) {
      close(c);
      continue;
    }
    uint16_t code = (hdr[2] << 8) | hdr[3];
    Bytes rep;
    if (code == 0x8005) {
      put16(rep, 0x0111);
      put16(rep, 0x0005);
      put32(rep, 0);
      put32(rep, 1);
      Bytes info = device_info(dd);
      rep.insert(rep.end(), info.begin(), info.end());
      rep.insert(rep.end(), {3, 1, 1, 0});  // the interface: HID, boot, keyboard
      send_all(c, rep);
      close(c);
      continue;
    }
    if (code == 0x8003) {
      uint8_t busid[32];
      recv_all(c, busid, 32);
      put16(rep, 0x0111);
      put16(rep, 0x0003);
      put32(rep, 0);
      Bytes info = device_info(dd);
      rep.insert(rep.end(), info.begin(), info.end());
      send_all(c, rep);
      break;
    }
    close(c);
  }
  setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  std::printf("attached; serving URBs\n");
  std::fflush(stdout);

  std::deque<Urb> control_q, interrupt_q;
  Bytes inbuf;
  bool busy = false;  // a URB is on the bus
  uint32_t busy_seq = 0;
  bool busy_unlinked = false;
  std::deque<Bytes> replies;
  uint8_t ep1_want = kData0;
  uint64_t urbs = 0, keys = 0;
  auto t_last = std::chrono::steady_clock::now();
  std::unique_ptr<Control> ctl;

  auto unlink_reply = [&](uint32_t seq, uint32_t target, int status) {
    Bytes r;
    put32(r, 4);
    put32(r, seq);
    put32(r, 0);
    put32(r, 0);
    put32(r, 0);
    put32(r, uint32_t(status));
    r.resize(48, 0);
    (void)target;
    replies.push_back(r);
  };

  for (;;) {
    // 1. read what Linux sent
    pollfd p{c, POLLIN, 0};
    bool quiet = !busy && control_q.empty() && interrupt_q.empty();
    if (poll(&p, 1, quiet ? 50 : 0) > 0) {
      uint8_t buf[4096];
      ssize_t n = recv(c, buf, sizeof buf, 0);
      if (n <= 0) break;
      inbuf.insert(inbuf.end(), buf, buf + n);
    }
    while (inbuf.size() >= 48) {
      uint32_t cmd = get32(&inbuf[0]), seq = get32(&inbuf[4]), dir = get32(&inbuf[12]),
               ep = get32(&inbuf[16]);
      if (cmd == 1) {
        uint32_t len = get32(&inbuf[24]);
        size_t need = 48 + (dir == 0 ? len : 0);
        if (inbuf.size() < need) break;
        Urb u{seq, dir, ep, len, get32(&inbuf[32]), Bytes(inbuf.begin() + 40, inbuf.begin() + 48),
              Bytes(inbuf.begin() + 48, inbuf.begin() + need)};
        inbuf.erase(inbuf.begin(), inbuf.begin() + need);
        (ep == 0 ? control_q : interrupt_q).push_back(u);
        urbs++;
      } else if (cmd == 2) {
        uint32_t target = get32(&inbuf[20]);
        inbuf.erase(inbuf.begin(), inbuf.begin() + 48);
        bool found = false;
        for (auto* q : {&control_q, &interrupt_q})
          for (auto it = q->begin(); it != q->end(); ++it)
            if (it->seq == target) {
              q->erase(it);
              found = true;
              break;
            }
        if (!found && busy && busy_seq == target) {
          busy_unlinked = true;
          found = true;
        }
        unlink_reply(seq, target, found ? -104 : 0);
      } else {
        std::printf("unknown USB/IP command %u\n", cmd);
        inbuf.clear();
      }
    }
    // 2. put the next URB on the bus: control first
    if (!busy && h.idle() && (!control_q.empty() || !interrupt_q.empty())) {
      busy = true;
      busy_unlinked = false;
      if (!control_q.empty()) {
        Urb u = control_q.front();
        control_q.pop_front();
        busy_seq = u.seq;
        if (u.setup[0] == 0x00 && u.setup[1] == 9) ep1_want = kData0;  // SET_CONFIGURATION
        ctl.reset(new Control{h, kAddr, u.setup, u.out, u.setup[6] | (u.setup[7] << 8),
                              [&, u](int st, Bytes d) {
                                if (d.size() > u.length) d.resize(u.length);
                                if (!busy_unlinked) replies.push_back(ret_submit(u, st, d));
                                busy = false;
                              }});
        ctl->start();
      } else {
        Urb u = interrupt_q.front();
        interrupt_q.pop_front();
        busy_seq = u.seq;
        h.in(kAddr, int(u.ep), [&, u](Res r) {
          if (is_data(r.pid) && r.pid == ep1_want) {
            ep1_want = ep1_want == kData0 ? kData1 : kData0;
            keys++;
            if (!busy_unlinked) replies.push_back(ret_submit(u, 0, r.data));
          } else if (!busy_unlinked) {
            interrupt_q.push_front(u);  // NAK (or a repeat): ask again later
            h.wait(400 * kBit, [] {});
          }
          busy = false;
        });
      }
    }
    // 3. time passes on the chip while anything is going on
    if (busy || !h.idle()) b.poll();
    // 4. answers back to Linux
    while (!replies.empty()) {
      if (!send_all(c, replies.front())) break;
      replies.pop_front();
    }
    auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration<double>(now - t_last).count() > 5) {
      t_last = now;
      std::printf("%llu URBs, %llu key reports, %llu cycles; board saw %zu requests%s\n",
                  (unsigned long long)urbs, (unsigned long long)keys,
                  (unsigned long long)chip.cycle(), b.log.size(),
                  b.leds >= 0 ? (", LEDs " + std::to_string(b.leds)).c_str() : "");
      std::fflush(stdout);
    }
  }
  std::printf("Linux closed the connection\n");
  for (auto& l : b.log) std::printf("  %s\n", l.c_str());
  print_stats(h, chip, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  return 0;
}

}  // namespace usb
