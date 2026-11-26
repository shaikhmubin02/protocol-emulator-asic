// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0

#include "chip.h"

#include <fstream>
#include <stdexcept>

#include "Vtt_um_shaikhmubin02_pemu.h"

namespace {
constexpr int kHalf = 4;  // SCK = clk / 8

uint16_t engine_addr(int e, int region, int off) { return (e << 14) | (region << 12) | off; }
}  // namespace

Chip::Chip() : top_(new Vtt_um_shaikhmubin02_pemu) {
  top_->ena = 1;
  top_->ui_in = 0b010;  // CSn high
  top_->uio_in = 0xFF;
  top_->rst_n = 0;
  for (int k = 0; k < 5; k++) tick();
  top_->rst_n = 1;
  ticks(4);
}

Chip::~Chip() { top_->final(); }

uint8_t Chip::uo() const { return top_->uo_out; }
uint8_t Chip::uio_out() const { return top_->uio_out; }
uint8_t Chip::uio_oe() const { return top_->uio_oe; }

void Chip::tick() {
  top_->clk = 0;
  top_->eval();
  if (board) board(*this);
  top_->ui_in = (ui_proto & 0xF8) | (mosi_ << 2) | (cs_n_ << 1) | sck_;
  top_->uio_in = uio_in;
  top_->eval();
  top_->clk = 1;
  top_->eval();
  cycle_++;
}

std::vector<uint8_t> Chip::transfer(const std::vector<uint8_t>& data) {
  cs_n_ = 0;
  ticks(kHalf);
  std::vector<uint8_t> got;
  for (uint8_t b : data) {
    uint8_t r = 0;
    for (int k = 7; k >= 0; k--) {
      mosi_ = (b >> k) & 1;
      ticks(kHalf);
      r = (r << 1) | (uo() >> 7);
      sck_ = 1;
      ticks(kHalf);
      sck_ = 0;
    }
    got.push_back(r);
  }
  ticks(kHalf);
  cs_n_ = 1;
  ticks(2 * kHalf);
  return got;
}

void Chip::write(uint16_t addr, const std::vector<uint16_t>& words) {
  std::vector<uint8_t> data = {0x02, uint8_t(addr >> 8), uint8_t(addr & 0xFF)};
  for (uint16_t w : words) {
    data.push_back(w >> 8);
    data.push_back(w & 0xFF);
  }
  transfer(data);
}

std::vector<uint16_t> Chip::read(uint16_t addr, int n) {
  std::vector<uint8_t> data = {0x03, uint8_t(addr >> 8), uint8_t(addr & 0xFF), 0};
  data.resize(4 + 2 * n, 0);
  auto got = transfer(data);
  std::vector<uint16_t> words;
  for (int k = 0; k < n; k++) words.push_back((got[4 + 2 * k] << 8) | got[5 + 2 * k]);
  return words;
}

void Chip::load(int engine, const std::vector<uint16_t>& program) {
  write(engine_addr(engine, 0, 0), program);
}

void Chip::own(int pin, int engine) { write(engine_addr(0, 3, pin), {uint16_t(0b100 | engine)}); }

void Chip::run(unsigned engines) { write(engine_addr(0, 3, 0x10), {uint16_t(engines)}); }

uint16_t Chip::status(int engine) { return read(engine_addr(engine, 2, 0), 1)[0]; }

bool Chip::send(int engine, uint16_t word) {
  if (((status(engine) >> 10) & 3) >= 2) return false;
  write(engine_addr(engine, 2, 0x80), {word});
  return true;
}

std::vector<uint16_t> Chip::receive(int engine) {
  int n = (status(engine) >> 12) & 3;
  if (n == 0) return {};
  return read(engine_addr(engine, 2, 0x80), n);
}

std::vector<uint16_t> read_hex(const std::string& path) {
  std::ifstream f(path);
  if (!f) throw std::runtime_error("cannot read " + path);
  std::vector<uint16_t> words;
  std::string line;
  while (std::getline(f, line))
    if (!line.empty()) words.push_back(uint16_t(std::stoul(line, nullptr, 16)));
  return words;
}
