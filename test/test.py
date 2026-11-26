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
        self.devices = []  # models of what is wired to the protocol pins (see step below)
        self.dev_low = 0
        self.line = 0xFF
        self.cycle = 0

    async def drive(self):
        while True:
            await FallingEdge(self.dut.clk)
            self.cycle += 1
            ui = self.ui
            if self.loop_tx_to_rx:
                ui = (ui & ~0x08) | ((self.uo() & 1) << 3)
            if self.devices:
                # open-drain uio pins: low if the chip drives them low or a device pulls them
                # low, otherwise the pull-up holds them high
                oe, out = int(self.dut.uio_oe.value), int(self.dut.uio_out.value)
                chip_low = oe & ~out & 0xFF
                self.chip_low = chip_low
                self.line = ~(chip_low | self.dev_low) & 0xFF  # what the devices see now
                dev_low, dev_ui = 0, 0
                for d in self.devices:
                    lo, u = d.step(self)
                    dev_low |= lo
                    dev_ui |= u
                self.dev_low = dev_low
                self.uio = ~(chip_low | dev_low) & 0xFF
                self.dut.uio_in.value = self.uio
                ui |= dev_ui
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


# ---- models of the devices on the other end, written from the protocol rules ----
# Each step() runs once a clock (on the falling edge) and returns (uio pins it pulls low,
# ui bits it drives).


class SpiTarget:
    """SPI mode 0 target on SCK = uo[1], MOSI = uo[2], CS = uo[3], MISO = ui[4]: samples MOSI on
    the rising edge, changes MISO on the falling edge, first bit out as soon as CS goes low.
    A reply byte is used up only once all 8 of its bits have been clocked: the chip holds every
    uo pin it doesn't own low, so CS reads low until the firmware takes the pin, with no clock."""

    def __init__(self, reply):
        self.reply, self.k = reply, 0
        self.received, self.sh, self.n = [], 0, 0
        self.miso, self.prev = 1, (0, 1)

    def bit(self):
        return (self.reply[self.k % len(self.reply)] >> (7 - self.n)) & 1

    def step(self, b):
        uo = b.uo()
        sck, mosi, cs = (uo >> 1) & 1, (uo >> 2) & 1, (uo >> 3) & 1
        psck, pcs = self.prev
        self.prev = (sck, cs)
        if pcs and not cs:
            self.n, self.sh = 0, 0
            self.miso = self.bit()
        elif not cs and sck and not psck:
            self.sh = ((self.sh << 1) | mosi) & 0xFF
            self.n += 1
            if self.n == 8:
                self.received.append(self.sh)
                self.n, self.k = 0, self.k + 1
        elif not cs and psck and not sck:
            self.miso = self.bit()
        return 0, self.miso << 4


class I2cTarget:
    """I2C target with 256 bytes of memory on SCL = uio[0], SDA = uio[1]. The first byte written
    after the address sets the pointer, the rest are stored; reads come from the pointer.
    SDA only changes while SCL is low."""

    def __init__(self, addr):
        self.addr, self.mem, self.ptr = addr, [0] * 256, 0
        self.state, self.prev, self.low = "idle", (1, 1), 0
        self.n, self.sh, self.acked = 0, 0, False

    def send_byte(self):
        self.byte = self.mem[self.ptr]
        self.ptr = (self.ptr + 1) & 0xFF
        self.state, self.n = "read", 0
        self.low = 1 - (self.byte >> 7)

    def step(self, b):
        scl, sda = b.line & 1, (b.line >> 1) & 1
        pscl, psda = self.prev
        self.prev = (scl, sda)
        rise, fall = scl and not pscl, pscl and not scl
        if scl and pscl and psda and not sda:  # START or repeated START
            self.state, self.n, self.sh, self.low = "addr", 0, 0, 0
        elif scl and pscl and not psda and sda:  # STOP
            self.state, self.low = "idle", 0
        elif self.state in ("addr", "write") and rise and self.n < 8:
            self.sh = ((self.sh << 1) | sda) & 0xFF
            self.n += 1
        elif self.state in ("addr", "write") and fall and self.n == 8:
            if self.state == "addr":
                if self.sh >> 1 != self.addr:
                    self.state = "idle"
                    return 0, 0
                self.reading, self.first = self.sh & 1, True
            elif self.first:
                self.ptr, self.first = self.sh, False
            else:
                self.mem[self.ptr] = self.sh
                self.ptr = (self.ptr + 1) & 0xFF
            self.state, self.low = "ack", 1
        elif self.state == "ack" and fall:
            self.low = 0
            if self.reading:
                self.send_byte()
            else:
                self.state, self.n, self.sh = "write", 0, 0
        elif self.state == "read" and rise and self.n == 8:
            self.acked = sda == 0  # the master's ACK bit
        elif self.state == "read" and fall:
            self.n += 1
            if self.n < 8:
                self.low = 1 - ((self.byte >> (7 - self.n)) & 1)
            elif self.n == 8:
                self.low = 0  # let go for the master's ACK
            elif self.acked:
                self.send_byte()
            else:
                self.state, self.low = "idle", 0
        return self.low << 1, 0


class OneWireDevice:
    """1-Wire device on uio[2] that answers a reset with a presence pulse and READ ROM (0x33)
    with its 8-byte ROM, LSB first. [us] is clock cycles per microsecond."""

    def __init__(self, us, rom):
        self.us, self.rom = us, rom
        self.bits = [(rom[k // 8] >> (k % 8)) & 1 for k in range(64)]
        self.fell, self.low_from, self.low_until = 0, 0, 0
        self.mode, self.written, self.was_low = "idle", [], False
        self.i, self.n, self.sh = 0, 0, 0

    def step(self, b):
        now, us = b.cycle, self.us
        master_low = (b.chip_low >> 2) & 1
        if master_low and not self.was_low:
            self.fell = now
            if self.mode == "rom":
                if self.bits[self.i] == 0:
                    self.low_from, self.low_until = now, now + 30 * us
                self.i += 1
                if self.i == 64:
                    self.mode = "idle"
        elif self.was_low and not master_low:
            width = now - self.fell
            if width >= 480 * us:
                self.low_from, self.low_until = now + 30 * us, now + 150 * us
                self.mode, self.sh, self.n = "cmd", 0, 0
            elif self.mode == "cmd":
                self.sh |= (1 if width < 15 * us else 0) << self.n
                self.n += 1
                if self.n == 8:
                    self.written.append(self.sh)
                    self.mode, self.i = ("rom", 0) if self.sh == 0x33 else ("idle", 0)
        self.was_low = master_low
        return (1 << 2) if self.low_from <= now < self.low_until else 0, 0


def crc8_maxim(data):
    crc = 0
    for byte in data:
        for k in range(8):
            mix = (crc ^ (byte >> k)) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8C
    return crc


@cocotb.test()
async def test_four_protocols_at_once(dut):
    """All four engines at once, each a different protocol, through the pins only: SPI master
    (engine 0), UART looped back (engine 1), I2C master with a repeated START (engine 2) and
    1-Wire reading a ROM ID (engine 3), against device models on the far side."""
    b = await start(dut)
    spi = SpiTarget([0x12, 0x34, 0x56])
    i2c = I2cTarget(0x50)
    i2c.mem[0x11] = 0x77
    rom = [0x28, 1, 2, 3, 4, 5, 6]
    rom.append(crc8_maxim(rom))
    ow = OneWireDevice(5, rom)
    b.devices = [spi, i2c, ow]
    b.loop_tx_to_rx = True
    fw = {0: "spi_master.hex", 1: "uart.hex", 2: "i2c_master.hex", 3: "onewire.hex"}
    owners = {9: 0, 10: 0, 11: 0, 8: 1, 0: 2, 1: 2, 2: 3}
    for e, name in fw.items():
        await b.write(program(e), firmware(name))
    for pin, e in owners.items():
        await b.write(glob(pin), [0b100 | e])
    await b.write(glob(0x10), [0b1111])
    words = {
        0: [0x1A5, 0x03C, 0x2F0],  # CS low, A5, 3C, F0, CS high
        1: [0x00, 0xFF, 0x5A, 0xC3],
        # Q = 8; write 0x10 <- 5A, 6B; then set the pointer, repeated START, read two bytes
        2: [0x608, 0x100, 0x2A0, 0x210, 0x25A, 0x26B, 0x500,
            0x100, 0x2A0, 0x210, 0x100, 0x2A1, 0x300, 0x400, 0x500],
        3: [0x405, 0x100, 0x233] + [0x300] * 8,  # 5 cycles a us, reset, READ ROM, 8 bytes
    }
    want = {0: [0x12, 0x34, 0x56], 1: [0x00, 0xFF, 0x5A, 0xC3],
            2: [0] * 7 + [0x5A, 0x6B], 3: [0] + rom}
    pending = {e: list(w) for e, w in words.items()}
    got = {e: [] for e in words}
    for _ in range(400):
        if all(len(got[e]) >= len(want[e]) for e in want):
            break
        for e in words:
            st = await b.read1(status(e))
            inbox, outbox = (st >> 10) & 3, (st >> 12) & 3
            if outbox:
                got[e] += await b.read(mailbox(e), outbox)
            if inbox < 2 and pending[e]:
                n = min(2 - inbox, len(pending[e]))
                await b.write(mailbox(e), pending[e][:n])
                del pending[e][:n]
    dut._log.info(f"{b.cycle} cycles; replies {got}")
    assert got[0] == want[0] and spi.received == [0xA5, 0x3C, 0xF0], (got[0], spi.received)
    assert got[1] == want[1], got[1]
    assert got[2] == want[2] and i2c.mem[0x10:0x12] == [0x5A, 0x6B], (got[2], i2c.mem[0x10:0x12])
    assert got[3] == want[3] and ow.written == [0x33], (got[3], ow.written)


# ---- protocols written after the RTL freeze, through the pins only. CI runs these on the
# gate-level netlist too. Firmware and fabric configurations come from hw/firmware and
# hw/post (test/firmware/*.hex, *.fabric).


def fabric(name):
    with open(os.path.join(HERE, "firmware", name + ".fabric")) as f:
        return [int(line, 16) for line in f if line.strip()]


async def configure(b, e, words, poly=None, init=None):
    """Load a fabric configuration and CRC settings into engine e (0 or 1) over the host port:
    region 1, offset 2 * word + half; words 16 and 17 are the CRC polynomial and start value."""
    for k, w in list(enumerate(words)) + [(16, poly), (17, init)]:
        if w is not None:
            await b.write(engine_addr(e, 1, 2 * k), [w & 0xFFFF, w >> 16])


async def exchange(b, e, to_send, n_back, rounds=400, idle=200):
    """Feed words to engine e's inbox and collect n_back words from its outbox."""
    pending, got = list(to_send), []
    for _ in range(rounds):
        if len(got) >= n_back and not pending:
            break
        st = await b.read1(status(e))
        inbox, outbox = (st >> 10) & 3, (st >> 12) & 3
        if outbox:
            got += await b.read(mailbox(e), outbox)
        if inbox < 2 and pending:
            await b.write(mailbox(e), [pending.pop(0)])
        await b.wait(idle)
    return got


def can_bits(ident, data):
    """A CAN 2.0A data frame as the bus carries it, from the Bosch spec: stuffed from the start of
    frame to the end of the CRC, then CRC delimiter, ACK slot (recessive from the sender), ACK
    delimiter, end of frame and intermission."""
    bits = [0] + [(ident >> (10 - k)) & 1 for k in range(11)] + [0, 0, 0]
    bits += [(len(data) >> (3 - k)) & 1 for k in range(4)]
    for d in data:
        bits += [(d >> (7 - k)) & 1 for k in range(8)]
    crc = 0
    for x in bits:
        fb = x ^ ((crc >> 14) & 1)
        crc = (crc << 1) & 0x7FFF
        if fb:
            crc ^= 0x4599
    bits += [(crc >> (14 - k)) & 1 for k in range(15)]
    out, run, last = [], 0, None
    for x in bits:
        out.append(x)
        run = run + 1 if x == last else 1
        last = x
        if run == 5:
            out.append(1 - x)
            last, run = 1 - x, 1
    ack_slot = len(out) + 1
    return out + [1, 1, 1] + [1] * 10, ack_slot


class CanNode:
    """Sends one frame on the bus (seen by the chip on ui[3]); the chip's TXD is uio[0], pulled
    up, so the bus is dominant if either drives it. Records the bus in the middle of the ACK slot."""

    def __init__(self, bits, ack_slot, start, bit=100):
        self.bits, self.ack_slot, self.start, self.bit = bits, ack_slot, start, bit
        self.ack = None

    def step(self, b):
        k = (b.cycle - self.start) // self.bit
        level = self.bits[k] if 0 <= k < len(self.bits) else 1
        bus = level & (0 if b.chip_low & 1 else 1)
        if k == self.ack_slot and (b.cycle - self.start) % self.bit == self.bit // 2:
            self.ack = bus
        return 0, bus << 3


@cocotb.test()
async def test_post_can_rx(dut):
    """can_rx.s (written after the freeze) receives a CAN frame and acknowledges it: the fabric
    configuration and CRC-15 settings are written over the host port, as a board would."""
    b = await start(dut)
    await b.write(program(0), firmware("can_rx.hex"))
    await configure(b, 0, fabric("can_rx"), poly=0x4599 << 17, init=0)
    await b.write(glob(0), [0b100 | 0])  # uio[0], the TXD, belongs to engine 0
    await b.write(glob(0x10), [0b0001])
    bits, ack_slot = can_bits(0x123, [0xDE, 0xAD])
    node = CanNode(bits, ack_slot, start=b.cycle + 3000)
    b.devices = [node]
    got = await exchange(b, 0, [], 6)
    dut._log.info(f"{b.cycle} cycles; words {[hex(w) for w in got]}, ACK slot {node.ack}")
    assert got[:6] == [0x123, 0x102, 0, 0, 0, 0xDEAD], got
    assert node.ack == 0, "not acknowledged"


class JtagController:
    """Clocks a list of (TMS, TDI) bits into the TAP: TCK on ui[4], TMS ui[5], TDI ui[6]; TDO
    (uio[0], released outside the shift states) read just before TCK rises."""

    def __init__(self, bits, start, half=25):
        self.bits, self.start, self.half = bits, start, half
        self.tdo = []

    def step(self, b):
        t = b.cycle - self.start
        k, ph = divmod(t, 2 * self.half) if t >= 0 else (-1, 0)
        if not 0 <= k < len(self.bits):
            return 0, 1 << 5
        tms, tdi = self.bits[k]
        tck = 1 if ph >= self.half else 0
        if ph == self.half - 1:
            self.tdo.append((b.line & 1) if not (b.chip_low & 1) else 0)
        return 0, (tck << 4) | (tms << 5) | (tdi << 6)


@cocotb.test()
async def test_post_jtag_tap(dut):
    """jtag_tap.s (written after the freeze): a JTAG controller resets the TAP and reads its
    IDCODE, then writes USER and reads it back, at 1 MHz TCK."""
    b = await start(dut)
    await b.write(program(1), firmware("jtag_tap.hex"))
    await b.write(glob(0), [0b100 | 1])  # TDO
    await b.write(glob(0x10), [0b0010])
    await exchange(b, 1, [0xFEE1, 0x1C0F, 0x1234], 0, rounds=10, idle=10)
    reset = [(1, 0)] * 5 + [(0, 0)]
    dr, ir, idle = [(1, 0), (0, 0), (0, 0)], [(1, 0), (1, 0), (0, 0), (0, 0)], [(1, 0), (0, 0)]
    shift = lambda n, v: [(int(k == n - 1), (v >> k) & 1) for k in range(n)]
    bits = reset + dr + shift(32, 0) + idle + ir + shift(4, 0b1000) + idle + dr + shift(16, 0xBEEF) + idle
    bits += dr + shift(16, 0) + idle
    ctl = JtagController(bits, start=b.cycle + 100)
    b.devices = [ctl]
    await b.wait(100 + 2 * 25 * len(bits) + 100)
    value = lambda pos, n: sum(ctl.tdo[pos + k] << k for k in range(n))
    idcode = value(len(reset + dr), 32)
    user_before = value(len(reset + dr) + 32 + len(idle + ir) + 4 + len(idle + dr), 16)
    user_after = value(len(bits) - len(idle) - 16, 16)
    dut._log.info(f"IDCODE {idcode:08x}, USER {user_before:04x} then {user_after:04x}")
    assert idcode == 0x1C0FFEE1 and user_before == 0x1234 and user_after == 0xBEEF


@cocotb.test()
async def test_post_dmx_tx(dut):
    """dmx_tx.s (written after the freeze): a DMX512 packet on uo[0]: the break and the mark
    after break are the bit engine's idle level, so they are whole 4 us bits."""
    b = await start(dut)
    await b.write(program(2), firmware("dmx_tx.hex"))
    await b.write(glob(8), [0b100 | 2])
    await b.write(glob(0x10), [0b0100])
    line = []

    class Probe:
        def step(self, b):
            line.append(b.uo() & 1)
            return 0, 0

    b.devices = [Probe()]
    await exchange(b, 2, [200, 23, 3, 0, 3, 0x00, 0x5A, 0xA5], 0, rounds=20, idle=20)
    await b.wait(20000)
    # runs of equal levels after the first break starts
    s = next(i for i in range(1, len(line)) if line[i] == 0 and line[i - 1] == 1)
    runs, i = [], s
    while i < len(line):
        j = i
        while j < len(line) and line[j] == line[i]:
            j += 1
        runs.append((line[i], j - i))
        i = j
    (brk_l, brk), (mab_l, mab) = runs[0], runs[1]
    slots, k = [], s + brk + mab
    for _ in range(3):
        bitv = [line[k + 100 + 200 * n] for n in range(11)]
        assert bitv[0] == 0 and bitv[9] == 1 and bitv[10] == 1, bitv
        slots.append(sum(bitv[1 + n] << n for n in range(8)))
        k += 11 * 200
    dut._log.info(f"break {brk} cycles, MAB {mab} cycles, slots {[hex(x) for x in slots]}")
    assert brk_l == 0 and brk == 23 * 200 and mab_l == 1 and mab == 3 * 200
    assert slots == [0x00, 0x5A, 0xA5]


@cocotb.test()
async def test_post_spdif_tx(dut):
    """spdif_tx.s (written after the freeze): S/PDIF on uo[0], biphase-mark from the fabric
    configuration bmc_tx, read back from the edges alone. At 40 cycles a half bit: at 48 kHz (8
    cycles) the program needs two host words every 520 cycles, faster than a host that reads
    the status before each write can send them over the port."""
    b = await start(dut)
    await b.write(program(1), firmware("spdif_tx.hex"))
    await configure(b, 1, fabric("bmc_tx"))
    await b.write(glob(8), [0b100 | 1])
    await b.write(glob(0x10), [0b0010])
    line = []

    class Probe:
        def step(self, b):
            line.append(b.uo() & 1)
            return 0, 0

    b.devices = [Probe()]
    samples = [0x123456, 0x765432, 0x0ABCDE, 0x543210, 0x111111, 0x222222]
    words = [40, 0]
    for i, x in enumerate(samples):
        words += [x & 0xFFFF, (x >> 16) | ((2 if i == 0 else (1 if i % 2 else 0)) << 12)]
    await exchange(b, 1, words, 0, rounds=40, idle=5)
    await b.wait(6000)
    ui = 40
    edges = [i for i in range(1, len(line)) if line[i] != line[i - 1]]
    cells = []
    for a, c in zip(edges, edges[1:]):
        n = round((c - a) / ui)
        assert 1 <= n <= 3, (c - a)
        cells += [line[a]] * n
    pats = {"B": [1, 1, 1, 0, 1, 0, 0, 0], "M": [1, 1, 1, 0, 0, 0, 1, 0], "W": [1, 1, 1, 0, 0, 1, 0, 0]}
    found, i = [], 0
    while i + 64 <= len(cells):
        first = cells[i]
        name = next((p for p, v in pats.items()
                     if all(cells[i + j] == (v[j] if first else 1 - v[j]) for j in range(8))), None)
        if name is None:
            i += 1
            continue
        bits = [int(cells[i + 8 + 2 * k] != cells[i + 9 + 2 * k]) for k in range(28)]
        found.append((name, sum(bits[k] << k for k in range(24)), sum(bits) % 2 == 0))
        i += 64
    dut._log.info(f"subframes {[(n, hex(v), p) for n, v, p in found]}")
    assert [n for n, _, _ in found[:4]] == ["B", "W", "M", "W"]
    assert [v for _, v, _ in found[:4]] == samples[:4] and all(p for _, _, p in found[:4])
