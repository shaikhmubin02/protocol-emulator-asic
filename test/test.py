# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

N_LE = 24

# LUT input sources
EXT0, EXT1, EXT2, B0, SELF, QM1, QM2, QP1 = range(8)


def le_word(fn, ins, use_ff, init):
    """Config word for one fabric element. fn takes the 4 LUT inputs."""
    ins = (ins + [EXT0] * 4)[:4]
    lut = 0
    for idx in range(16):
        if fn(*[(idx >> k) & 1 for k in range(4)]):
            lut |= 1 << idx
    sel = 0
    for k, s in enumerate(ins):
        sel |= s << (3 * k)
    return lut | (sel << 16) | (use_ff << 28) | (init << 29)


EMPTY = le_word(lambda *a: 0, [], 0, 0)


def crc_fabric_config(n, poly_reflected, init):
    """Reflected CRC: LE0 = feedback, LE1..LEn = crc[0..n-1]."""
    w = [EMPTY] * N_LE
    w[0] = le_word(lambda a, b, c, d: a ^ b, [EXT0, QP1], 0, 0)
    for j in range(1, n + 1):
        p = (poly_reflected >> (j - 1)) & 1
        w[j] = le_word(lambda a, b, c, d, p=p: a ^ (p & b), [QP1, B0], 1, (init >> (j - 1)) & 1)
    return w


def crc_ref(bits, poly_reflected, init):
    c = init
    for b in bits:
        fb = (c ^ b) & 1
        c >>= 1
        if fb:
            c ^= poly_reflected
    return c


def reflect(x, n):
    return int(f"{x:0{n}b}"[::-1], 2)


class Harness:
    def __init__(self, dut):
        self.dut = dut
        self.ui = 0

    async def set_ui(self, value):
        self.ui = value
        self.dut.ui_in.value = value
        await ClockCycles(self.dut.clk, 1)

    async def write(self, addr, data):
        word = (addr << 32) | data
        for k in range(37, -1, -1):
            await self.set_ui(0b10 | ((word >> k) & 1))
        await self.set_ui(0b100)
        await self.set_ui(0)
        await self.set_ui(0)

    async def load_fabric(self, words):
        for i, w in enumerate(words):
            await self.write(i, w)

    async def init(self):
        await self.set_ui(0b10000)
        await self.set_ui(0)

    async def step(self, bit):
        await self.set_ui(0b1000 | (bit << 5))
        await self.set_ui(0)

    async def read(self, sel):
        self.dut.uio_in.value = sel
        await ClockCycles(self.dut.clk, 1)
        return int(self.dut.uo_out.value)

    async def fabric_out(self):
        b = [await self.read(s) for s in range(3)]
        return b[0] | (b[1] << 8) | (b[2] << 16)

    async def crc_rev(self):
        b = [await self.read(s) for s in range(3, 7)]
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    return Harness(dut)


async def run_crc(h, n, poly_normal, init, nbits, seed):
    poly_r = reflect(poly_normal, n)
    mask = (1 << n) - 1
    await h.load_fabric(crc_fabric_config(n, poly_r, init))
    # same CRC in the hard unit: left-aligned, MSB-first, read back reversed
    await h.write(62, poly_normal << (32 - n))
    await h.write(63, init << (32 - n))
    await h.init()

    rng = random.Random(seed)
    bits = [rng.randint(0, 1) for _ in range(nbits)]
    for i, b in enumerate(bits):
        await h.step(b)
        exp = crc_ref(bits[: i + 1], poly_r, init)
        fab = (await h.fabric_out() >> 1) & mask
        hard = await h.crc_rev() & mask
        assert fab == exp, f"fabric crc step {i}: got {fab:x}, expected {exp:x}"
        assert hard == exp, f"hard crc step {i}: got {hard:x}, expected {exp:x}"
    return exp


@cocotb.test()
async def test_crc16_usb(dut):
    h = await start(dut)
    final = await run_crc(h, 16, 0x8005, 0xFFFF, 128, seed=1)
    dut._log.info(f"CRC-16/USB after 128 bits: {final:04x} (sent as {final ^ 0xFFFF:04x})")


@cocotb.test()
async def test_crc16_check_value(dut):
    # CRC-16/USB of "123456789" is 0xB4C8
    h = await start(dut)
    poly_r, init = reflect(0x8005, 16), 0xFFFF
    await h.load_fabric(crc_fabric_config(16, poly_r, init))
    await h.write(62, 0x8005 << 16)
    await h.write(63, 0xFFFF << 16)
    await h.init()
    for c in b"123456789":
        for k in range(8):
            await h.step((c >> k) & 1)
    fab = ((await h.fabric_out() >> 1) & 0xFFFF) ^ 0xFFFF
    hard = (await h.crc_rev() & 0xFFFF) ^ 0xFFFF
    assert fab == 0xB4C8, f"fabric {fab:04x}"
    assert hard == 0xB4C8, f"hard {hard:04x}"


@cocotb.test()
async def test_reconfigure_to_crc5(dut):
    # load CRC16, run a bit, then switch the same fabric to CRC-5/USB without a reset
    h = await start(dut)
    await run_crc(h, 16, 0x8005, 0xFFFF, 16, seed=2)
    await run_crc(h, 5, 0x05, 0x1F, 40, seed=3)
