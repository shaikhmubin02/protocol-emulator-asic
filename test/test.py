# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0

# Drives the chip only through its pins, like a board would: everything goes over the host
# SPI port (ui[0] SCK, ui[1] CSn, ui[2] MOSI, uo[7] MISO). Address map: hw/src/chip.ml.

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

HERE = os.path.dirname(os.path.abspath(__file__))
HALF = 4  # SCK = clk/8

CHIP_ID = 0x5045


def engine_addr(e, region, off):
    return (e << 14) | (region << 12) | off


def program(e, off=0):
    return engine_addr(e, 0, off)


def status(e):
    return engine_addr(e, 2, 0)


def mailbox(e):
    return engine_addr(e, 2, 0x80)


def glob(off):
    return engine_addr(0, 3, off)


def firmware(name):
    with open(os.path.join(HERE, "firmware", name)) as f:
        return [int(line, 16) for line in f if line.strip()]


class Board:
    """Everything outside the chip: the SPI host and whatever is wired to the protocol pins.
    Inputs change on the falling clock edge and outputs are read there too, half a cycle
    away from the chip's rising edge."""

    def __init__(self, dut):
        self.dut = dut
        self.sck = 0
        self.cs_n = 1
        self.mosi = 0
        self.ui = 0  # ui[7:3]
        self.loop_tx_to_rx = False  # uo[0] -> ui[3]

    async def drive(self):
        while True:
            await FallingEdge(self.dut.clk)
            ui = self.ui
            if self.loop_tx_to_rx:
                ui = (ui & ~0x08) | ((self.uo() & 1) << 3)
            self.dut.ui_in.value = (ui & 0xF8) | (self.mosi << 2) | (self.cs_n << 1) | self.sck

    def uo(self):
        return int(self.dut.uo_out.value)

    async def wait(self, n):
        for _ in range(n):
            await FallingEdge(self.dut.clk)

    async def transfer(self, data):
        self.cs_n = 0
        await self.wait(HALF)
        got = []
        for b in data:
            r = 0
            for k in range(7, -1, -1):
                self.mosi = (b >> k) & 1
                await self.wait(HALF)
                r = (r << 1) | (self.uo() >> 7)
                self.sck = 1
                await self.wait(HALF)
                self.sck = 0
            got.append(r)
        await self.wait(HALF)
        self.cs_n = 1
        await self.wait(2 * HALF)
        return got

    async def write(self, addr, words):
        data = [0x02, addr >> 8, addr & 0xFF]
        for w in words:
            data += [w >> 8, w & 0xFF]
        await self.transfer(data)

    async def read(self, addr, n=1):
        got = await self.transfer([0x03, addr >> 8, addr & 0xFF, 0] + [0] * (2 * n))
        got = got[4:]
        return [(got[2 * k] << 8) | got[2 * k + 1] for k in range(n)]

    async def read1(self, addr):
        return (await self.read(addr))[0]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0b010  # CSn high
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    board = Board(dut)
    cocotb.start_soon(board.drive())
    await board.wait(4)
    return board


@cocotb.test()
async def test_reset_state(dut):
    b = await start(dut)
    assert await b.read1(glob(0x20)) == CHIP_ID
    assert await b.read1(glob(0x10)) == 0, "no engine should run after reset"
    assert int(dut.uio_oe.value) == 0, "no pin should be driven after reset"
    assert b.uo() & 0x7F == 0


@cocotb.test()
async def test_program_readback(dut):
    b = await start(dut)
    rng = random.Random(7)
    words = {e: [rng.randrange(0x10000) for _ in range(8)] for e in (0, 1)}
    for e, w in words.items():
        await b.write(program(e, 200), w)
    for e, w in words.items():
        back = await b.read(program(e, 200), len(w))
        assert back == w, f"engine {e}: wrote {w}, read {back}"


@cocotb.test()
async def test_uart_loopback(dut):
    """uart.s on engine 1, TX on uo[0] wired back to RX on ui[3]."""
    b = await start(dut)
    await b.write(program(1), firmware("uart.hex"))
    await b.write(glob(8), [0b100 | 1])  # pin 8 (uo[0]) belongs to engine 1
    await b.write(glob(0x10), [0b0010])  # run engine 1
    b.loop_tx_to_rx = True
    sent = [0x00, 0xFF, 0x5A, 0xC3]
    pending = list(sent)
    got = []
    for _ in range(100):
        if len(got) == len(sent):
            break
        st = await b.read1(status(1))
        inbox, outbox = (st >> 10) & 3, (st >> 12) & 3
        if outbox:
            got += await b.read(mailbox(1), outbox)
        if inbox < 2 and pending:
            await b.write(mailbox(1), [pending.pop(0)])
    assert got == sent, f"sent {sent}, got {got}"
