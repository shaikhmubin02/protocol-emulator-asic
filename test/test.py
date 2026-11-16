# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0

# Drives the chip only through its pins, like a board would: everything goes over the host
# SPI port (ui[0] SCK, ui[1] CSn, ui[2] MOSI, uo[7] MISO). Address map: hw/src/chip.ml.

import os
import random
import re

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
    words = {e: [rng.randrange(0x10000) for _ in range(8)] for e in (0, 3)}
    for e, w in words.items():
        await b.write(program(e, 200), w)
    for e, w in words.items():
        back = await b.read(program(e, 200), len(w))
        assert back == w, f"engine {e}: wrote {w}, read {back}"


def flop_names():
    """The registers in each module of src/pemu.v: everything assigned in a clocked block."""
    with open(os.path.join(HERE, "..", "src", "pemu.v")) as f:
        src = f.read()
    names = {}
    for module, body in re.findall(r"^module (\w+) \((.*?)^endmodule", src, re.S | re.M):
        blocks = re.findall(r"always @\(posedge \w+ or negedge \w+\) begin(.*?)\n    end\n", body, re.S)
        names[module] = sorted({n for b in blocks for n in re.findall(r"(\w+) <=", b)})
    return names


# Allowed to hold unwritten data: the word the host port reads next. It is loaded every cycle
# from whatever the address points at, and only used when the host reads that word.
UNWRITTEN_OK = {"host_read_word"}


def unknown_flops(dut, allow=()):
    """Flops holding X or Z. On silicon such a flop would hold whatever the latches and SRAM
    happened to power up with."""
    names = flop_names()
    allow = UNWRITTEN_OK | set(allow)
    top = dut.user_project
    where = [("top", top, names["tt_um_shaikhmubin02_pemu"])]
    where += [(f"engine{e}", getattr(top, f"engine{e}"), names["engine"]) for e in range(4)]
    bad = []
    for label, inst, regs in where:
        for r in regs:
            if r in allow:
                continue
            v = str(getattr(inst, r).value)
            if any(c not in "01" for c in v):
                bad.append(f"{label}.{r} = {v}")
    return bad


@cocotb.test(skip=os.environ.get("GATES") == "yes")
async def test_power_up_state(dut):
    """The 1,248 configuration latches and the SRAMs aren't reset, and the simulator starts them
    as X. Run uart.s on all four engines with no fabric or CRC configuration written: no driven
    pin may ever depend on those unwritten values, and the only flops that may are the fabric
    flops, which BEN 1 loads from the configuration (and which nothing reads while the fabric is
    off). Then write the configuration, restart, and every flop must be known."""
    b = await start(dut)
    assert not unknown_flops(dut), "after reset"

    async def watch_pins():
        while True:
            await FallingEdge(dut.clk)
            oe = str(dut.uio_oe.value)
            out = str(dut.uio_out.value)
            assert set(str(dut.uo_out.value)) <= {"0", "1"}, f"uo_out = {dut.uo_out.value}"
            assert set(oe) <= {"0", "1"}, f"uio_oe = {oe}"
            assert all(o == "0" or v in "01" for o, v in zip(oe, out)), f"uio_out = {out}"

    cocotb.start_soon(watch_pins())
    for e in range(4):
        await b.write(program(e), firmware("uart.hex"))
    await b.write(glob(8), [0b100 | 1])  # pin 8 (uo[0]) belongs to engine 1
    await b.write(glob(0x10), [0b1111])  # run all four engines
    b.loop_tx_to_rx = True
    for byte in (0x00, 0xFF, 0x5A):
        await b.write(mailbox(1), [byte])
        for _ in range(50):
            st = await b.read1(status(1))
            if (st >> 12) & 3:
                break
        assert await b.read1(mailbox(1)) == byte
    fabric = [f"fab_q{k}" for k in range(8)]
    bad = unknown_flops(dut, allow=fabric)
    assert not bad, f"{len(bad)} flops depend on power-up values: {bad[:20]}"
    assert len(unknown_flops(dut)) == 4 * 8, "the fabric flops should still be unknown"

    await b.write(glob(0x10), [0])  # stop, write every configuration word, run again
    for e in range(4):
        await b.write(engine_addr(e, 1, 0), [0] * 16)  # fabric elements 0-7
        await b.write(engine_addr(e, 1, 32), [0] * 4)  # CRC polynomial and init
    await b.write(glob(0x10), [0b1111])
    await b.wait(100)
    bad = unknown_flops(dut)
    assert not bad, f"after writing the configuration: {bad[:20]}"


UART_PULL = 17  # address of `send: pull r0` in uart.s


@cocotb.test()
async def test_debug_breakpoint_join_step(dut):
    """uart.s on engines 0-2. A breakpoint on engine 1's pull stops engines 0 and 2 too (join);
    one step takes the host byte into r0, the host replaces it, and after resume the UART sends
    the replacement."""
    b = await start(dut)
    for e in range(3):
        await b.write(program(e), firmware("uart.hex"))
    await b.write(glob(8), [0b100 | 1])
    await b.write(engine_addr(1, 2, 1), [0x100 | UART_PULL])  # breakpoint on
    for e in (0, 2):
        await b.write(engine_addr(e, 2, 1), [0x200])  # join only
    await b.write(glob(0x10), [0b0111])
    b.loop_tx_to_rx = True
    await b.wait(200)
    assert await b.read1(glob(0x14)) == 0, "nothing stopped yet"

    await b.write(mailbox(1), [0x5A])
    for _ in range(20):
        if await b.read1(glob(0x14)) & 0b0111 == 0b0111:
            break
    dbg = await b.read1(glob(0x14))
    assert dbg == 0b0111_0111, f"engines 0-2 stopped by the breakpoint, got {dbg:#x}"
    st = await b.read1(status(1))
    assert st & 0xFF == UART_PULL and st >> 15, f"engine 1 status {st:#x}"
    assert (await b.read1(engine_addr(1, 2, 1))) >> 10 == 0b11

    await b.write(glob(0x14), [1 << (8 + 1)])  # one cycle of engine 1: the pull
    assert await b.read1(status(1)) & 0xFF == UART_PULL + 1
    assert await b.read1(engine_addr(1, 2, 0x10)) == 0x5A
    await b.write(engine_addr(1, 2, 0x10), [0x41])  # r0 = 'A'

    await b.write(glob(0x14), [0b0111 << 4])  # resume all three
    assert await b.read1(glob(0x14)) == 0
    for _ in range(50):
        if (await b.read1(status(1)) >> 12) & 3:
            break
    assert await b.read1(mailbox(1)) == 0x41, "the UART should send the byte the host put in r0"


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
