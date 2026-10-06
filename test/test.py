# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

NOP, LDI, ADD, OUT, JMP, DJNZ, WAITP, IN, JNZ = range(9)


def ins(op, rd=0, rs=0, imm=0):
    return (op << 12) | (rd << 8) | (rs << 4) | imm if op in (ADD, OUT) else (op << 12) | (rd << 8) | imm


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def load(dut, program, extra_ui=0):
    for addr, word in enumerate(program):
        w = (addr << 16) | word
        for k in range(23, -1, -1):
            dut.ui_in.value = extra_ui | 0b10 | ((w >> k) & 1)
            await ClockCycles(dut.clk, 1)
        dut.ui_in.value = extra_ui | 0b100
        await ClockCycles(dut.clk, 1)
        dut.ui_in.value = extra_ui
        await ClockCycles(dut.clk, 2)


async def run_and_trace(dut, cycles, extra_ui=0):
    """Start the core and record (pc, uo) after every clock edge."""
    dut.ui_in.value = extra_ui | 0b1000
    trace = []
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        trace.append((int(dut.uio_out.value), int(dut.uo_out.value)))
    return trace


@cocotb.test()
async def test_loop_timing(dut):
    # r1 = 5, r3 = 1; loop: r2 += r3; out r2; djnz r1, loop; then spin
    prog = [
        ins(LDI, rd=1, imm=5),
        ins(LDI, rd=3, imm=1),
        ins(ADD, rd=2, rs=3),  # 2: loop
        ins(OUT, rs=2),
        ins(DJNZ, rd=1, imm=2),
        ins(JMP, imm=5),  # 5: spin
    ]
    await start(dut)
    await load(dut, prog)
    trace = await run_and_trace(dut, 30)
    changes = [i for i in range(1, len(trace)) if trace[i][1] != trace[i - 1][1]]
    values = [trace[i][1] for i in changes]
    dut._log.info(f"uo changed at cycles {changes} to {values}")
    assert values == [1, 2, 3, 4, 5], values
    gaps = [b - a for a, b in zip(changes, changes[1:])]
    # 3 instructions per iteration, the taken DJNZ included: exactly 3 cycles apart
    assert gaps == [3, 3, 3, 3], gaps
    assert trace[-1][0] == 5, f"should end spinning at pc 5, got {trace[-1][0]}"


@cocotb.test()
async def test_waitp_exact(dut):
    # wait for ui[7] = 1, then out r1 (= 0x55)
    prog = [ins(LDI, rd=1, imm=0x55), ins(WAITP, rd=7, imm=1), ins(OUT, rs=1), ins(JMP, imm=3)]
    await start(dut)
    await load(dut, prog)
    dut.ui_in.value = 0b1000
    for _ in range(10):
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.uio_out.value) == 1, "should be waiting at pc 1"
    assert int(dut.uo_out.value) == 0
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0b1000_1000  # pin goes high between edges
    await RisingEdge(dut.clk)  # WAITP sees it: pc -> 2
    await ReadOnly()
    assert int(dut.uio_out.value) == 2
    await RisingEdge(dut.clk)  # OUT executes
    await ReadOnly()
    assert int(dut.uo_out.value) == 0x55


@cocotb.test()
async def test_jnz_and_in(dut):
    # r1 = ui; if r1 != 0 jump to 4 (out 7) else out 1
    prog = [
        ins(IN, rd=1),
        ins(JNZ, rd=1, imm=4),
        ins(LDI, rd=2, imm=1),
        ins(JMP, imm=5),
        ins(LDI, rd=2, imm=7),
        ins(OUT, rs=2),
        ins(JMP, imm=6),
    ]
    await start(dut)
    await load(dut, prog)
    trace = await run_and_trace(dut, 12)
    # ui = 0b1000 (run) so r1 = 8, nonzero -> out 7
    assert trace[-1][1] == 7, trace
