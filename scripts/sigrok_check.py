#!/usr/bin/env python3
"""Decode the RTL's simulated pads with the stock sigrok protocol decoders and compare what they
read with what each test sent and received.

The lockstep tests (hw/test/test_lockstep.ml) write <name>.vcd (every pad, one sample per clock)
and <name>.expect (the bytes the test itself sent and saw) when PEMU_VCD_DIR is set. This runs
sigrok-cli on each VCD and checks the decoded bytes against the .expect file.

    scripts/sigrok_check.py <vcd dir> [--md table.md]
"""
import argparse
import math
import pathlib
import re
import subprocess
import sys

USB_PIDS = {"DATA0": 0xC3, "DATA1": 0x4B, "ACK": 0xD2, "NAK": 0x5A, "STALL": 0x1E,
            "SETUP": 0x2D, "IN": 0x69, "OUT": 0xE1, "SOF": 0xA5}


def last_hex(line):
    # "55" (uart, spi) or "Data write: 5A" (i2c); other lines (i2c's bare "Write") carry no byte
    m = re.search(r"(?:^|: )([0-9A-Fa-f]{2})$", line)
    return [int(m.group(1), 16)] if m else []


def usb_packet(line, key):
    m = re.match(r"(\w+)(?: \[ ([0-9A-F ]*) \])?$", line)
    if not m or m.group(1) not in USB_PIDS:
        return []
    if key == "pids":
        return [USB_PIDS[m.group(1)]]
    return [int(b, 16) for b in (m.group(2) or "").split()]


def rgb_to_grb(line):
    v = line.strip().lstrip("#")
    r, g, b = int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16)
    return [g, r, b]


def onewire(line, key):
    if key == "write" and line.startswith("ROM command:"):
        return [int(line.split()[2], 16)]
    if key == "read" and line.startswith("ROM:"):
        rom = int(line.split()[1], 16)
        return [(rom >> (8 * k)) & 0xFF for k in range(8)]
    return []


def can_id(line):
    # "Identifier: 291 (0x123)"
    m = re.search(r"\(0x([0-9A-Fa-f]+)\)$", line)
    return [int(m.group(1), 16)] if m and line.startswith("Identifier") else []


def can_data():
    """Data bytes, skipping what the decoder reports inside a remote frame. A CAN 2.0 remote
    frame has a DLC but no data field; the stock decoder (can/pd.py) takes the data length from
    the DLC alone and reads DLC bytes of whatever follows. Those are not data."""
    remote = [False]

    def parse(line):
        if line.startswith("Start of frame"):
            remote[0] = False
        elif line.startswith("Remote transmission request"):
            remote[0] = "remote frame" in line
        elif line.startswith("Data byte") and not remote[0]:
            return [int(line.rsplit("0x", 1)[1], 16)]
        return []
    return parse


def dali(line, key):
    # "Arc Power Level: 128", "Command: 160 (Query Level)", "Reply: 128"
    m = re.match(r"(Arc Power Level|Command|Reply): (\d+)", line)
    if not m:
        return []
    if key == "data" and m.group(1) != "Reply":
        return [int(m.group(2))]
    if key == "reply" and m.group(1) == "Reply":
        return [int(m.group(2))]
    return []


def dmx_first_packet():
    """The slots of the first packet in a recording, start code first. Two limits of the stock
    decoder (dmx512/pd.py) shape this. It only looks for a new break after channel 512: the break
    after a shorter packet is read as one more slot with its stop bits low, and from there it has
    lost its place. So the slots are read up to that first error, and the tests note the first
    packet's slots. And it takes the level at the very end of the second stop bit as the mark
    between slots: with slots back to back (E1.11 allows a mark of 0) that sample is already the
    next start bit, so the recorded tests put a 4 us mark between slots. Back to back is checked
    against the E1.11 model in the other DMX tests."""
    done = [False]

    def parse(line):
        if done[0]:
            return []
        if line.startswith("Invalid"):
            done[0] = True
            return []
        m = re.match(r"(\d+) / 0x", line)
        return [int(m.group(1))] if m else []
    return parse


def lin():
    """IDs with good parity, the response bytes, and the IDs whose checksum the decoder calls
    invalid. The decoder reports a frame at the next break or when the UART decoder reports the
    line idle, so the last header of a recording is reported too."""
    last = [None]

    def parse(line, key):
        m = re.match(r"ID: ([0-9A-F]{2}) Parity: \d \((ok|bad)\)", line)
        if m:
            last[0] = int(m.group(1), 16)
            return [last[0]] if key == "ids" and m.group(2) == "ok" else []
        m = re.match(r"Data: 0x([0-9A-F]{2})$", line)
        if m and key == "data":
            return [int(m.group(1), 16)]
        if line == "Checksum invalid" and key == "invalid":
            return [last[0]]
        return []
    return parse


def jtag(line, key):
    # "DR TDO: 0001...1 (0x1c0ffee1), 32 bits": the hex value has the first bit in bit 0
    m = re.match(r"(DR|IR) (TDI|TDO): [01]* \(0x([0-9a-f]+)\), \d+ bits$", line)
    if m and f"{m.group(1)}_{m.group(2)}".lower() == key:
        return [int(m.group(3), 16)]
    return []


def swd(line, key):
    # ACKs as 1 OK, 2 WAIT, 4 FAULT, 7 no reply; data as "0x2ba01477"
    if key == "acks":
        return {"OK": [1], "WAIT": [2], "FAULT": [4], "NOREPLY": [7]}.get(line, [])
    m = re.match(r"0x([0-9a-f]{8})$", line)
    return [int(m.group(1), 16)] if m and key == "data" else []


def nec(line, key):
    """Addresses and commands. The stock decoder checks the address byte against its inverse,
    so a frame with an extended (16-bit) address comes out as "Address# error: 0x1234" and its
    command is not decoded; the address is read from that line."""
    m = re.match(r"(Address#|Address# error|Command): 0x([0-9A-F]+)$", line)
    if not m:
        return []
    if key == "commands" and m.group(1) == "Command":
        return [int(m.group(2), 16)]
    if key == "addresses" and m.group(1) == "Address#":
        return [int(m.group(2), 16) ^ 0xFF]  # the inverse byte, checked
    if key == "addresses" and m.group(1) == "Address# error":
        return [int(m.group(2), 16)]
    return []


def first_audio(n):
    """The first n subframes' 24-bit samples ("Audio 0x123456"), left and right in turn."""
    seen = [0]

    def parse(line):
        m = re.match(r"Audio 0x([0-9a-f]+)$", line)
        if not m or seen[0] >= n:
            return []
        seen[0] += 1
        return [int(m.group(1), 16)]
    return parse


def wiegand_bits(line):
    # "26 bits 10011...": the bits of a message, first sent first
    m = re.match(r"\d+ bits ([01]+)$", line)
    return [int(c) for c in m.group(1)] if m else []


def rc5(line):
    # "Address: 5 (...)", "Command: 53 (...)": address and command in turn
    m = re.match(r"(?:Address|Command): (\d+)", line)
    return [int(m.group(1))] if m else []


def ps2_data(line):
    # "Data: 1c". The stock decoder ends a frame only at the next falling edge of CLK, so in a
    # burst it takes the next byte's start bit for that; the recording's host holds CLK low
    # after each byte, as hosts may, which gives it that edge (hw/test/test_post2.ml).
    m = re.match(r"Data: ([0-9a-f]{2})$", line)
    return [int(m.group(1), 16)] if m else []


def modbus(line, key):
    """Every frame's server ID (0 for a broadcast), every frame's CRC verdict (1 right, 0 wrong),
    and the exception codes of replies."""
    if key == "ids":
        m = re.match(r"Slave ID: (\d+)$", line)
        return [int(m.group(1))] if m else [0] if line == "Broadcast message" else []
    if key == "crc":
        return [1] if line == "CRC correct" else [0] if line.startswith("CRC should be") else []
    m = re.match(r"Error (\d+): ", line)
    return [int(m.group(1))] if m and key == "exceptions" else []


def spi(clk, mosi, cs, miso, mode):
    return [f"spi:clk={clk}:mosi={mosi}:cs={cs}:miso={miso}:cpol={mode >> 1}:cpha={mode & 1}"]


# name: (decoder stack, [(key in .expect, annotation selector, line -> values)])
I2C = [("addr_w", "i2c=address-write", last_hex), ("data_w", "i2c=data-write", last_hex),
       ("addr_r", "i2c=address-read", last_hex), ("data_r", "i2c=data-read", last_hex)]
USB = ["usb_signalling:dp=uio4:dm=uio5:signalling=low-speed", "usb_packet"]
CASES = {
    "uart_loopback": (["uart:rx=uo0:baudrate=5000000"], [("tx", "uart=rx-data", last_hex)]),
    **{f"spi_master_mode{m}": (spi("uo1", "uo2", "uo3", "ui4", m),
                               [("mosi", "spi=mosi-data", last_hex),
                                ("miso", "spi=miso-data", last_hex)]) for m in range(4)},
    "spi_target": (spi("ui5", "ui6", "ui7", "uio0", 3),
                   [("mosi", "spi=mosi-data", last_hex), ("miso", "spi=miso-data", last_hex)]),
    "i2c_master": (["i2c:scl=uio0:sda=uio1"], I2C),
    "i2c_target": (["i2c:scl=uio0:sda=uio1"], I2C),
    "onewire": (["onewire_link:owr=uio2", "onewire_network"],
                [(k, "onewire_network", lambda l, k=k: onewire(l, k)) for k in ("write", "read")]),
    "ws2812": (["rgb_led_ws281x:din=uo0"], [("grb", "rgb_led_ws281x=rgb", rgb_to_grb)]),
    "usb_tx": (USB, [(k, "usb_packet=packet", lambda l, k=k: usb_packet(l, k))
                     for k in ("pids", "data")]),
    "usb_rx": (USB, [(k, "usb_packet=packet", lambda l, k=k: usb_packet(l, k))
                     for k in ("pids", "data")]),
    # after the RTL freeze
    "can_rx": (["can:can_rx=ui3:nominal_bitrate=500000"],
               [("id", "can=id", can_id), ("data", "can=sof:rtr:data", can_data())]),
    "can_tx": (["can:can_rx=ui3:nominal_bitrate=500000"],
               [("id", "can=id", can_id), ("data", "can=sof:rtr:data", can_data())]),
    "midi_out": (["uart:rx=uo0:baudrate=31250"], [("bytes", "uart=rx-data", last_hex)]),
    "midi_in": (["uart:rx=ui3:baudrate=31250"], [("bytes", "uart=rx-data", last_hex)]),
    "dmx_tx": (["dmx512:dmx=uo0"], [("slots", "dmx512=data:error", dmx_first_packet())]),
    "dmx_rx": (["dmx512:dmx=ui3"], [("slots", "dmx512=data:error", dmx_first_packet())]),
    "lin_commander": (["uart:rx=ui3:baudrate=19200", "lin"],
                      [(k, "lin", lambda l, k=k, f=lin(): f(l, k)) for k in ("ids", "data", "invalid")]),
    # the commander here runs 12% slow: 19200 / 1.12 bit/s, and the responder follows it
    "lin_responder": (["uart:rx=ui3:baudrate=17143", "lin"],
                      [(k, "lin", lambda l, k=k, f=lin(): f(l, k)) for k in ("ids", "data", "invalid")]),
    "jtag": (["jtag:tdi=ui6:tdo=ui7:tck=ui4:tms=ui5"],
             [(k, "jtag=bitstring-tdi:bitstring-tdo", lambda l, k=k: jtag(l, k))
              for k in ("ir_tdi", "ir_tdo", "dr_tdi", "dr_tdo")]),
    "swd": (["swd:swclk=uo0:swdio=uio0"],
            [(k, "swd=ack:data", lambda l, k=k: swd(l, k)) for k in ("acks", "data")]),
    # the LED pin itself, 38 kHz carrier and all: the decoder demodulates it
    "nec_tx": (["ir_nec:ir=uo0:cd_freq=38000:polarity=active-high"],
               [(k, "ir_nec=addr-inv:cmd:warnings", lambda l, k=k: nec(l, k))
                for k in ("addresses", "commands")]),
    "spdif": (["spdif:data=uo0"], [("audio", "spdif=samples", first_audio(8))]),
    "wiegand": (["wiegand:d0=uio0:d1=uio1:bitwidth_ms=1"], [("bits", "wiegand=state", wiegand_bits)]),
    "rc5": (["ir_rc5:ir=ui3:polarity=active-low:protocol=extended"],
            [("frames", "ir_rc5=address:command", rc5)]),
    "ps2_dev": (["ps2:clk=uio0:data=uio1"], [("bytes", "ps2=word", ps2_data)]),
    # requests come in on RX (ui3), replies go out on TX (uo0)
    "modbus": (["uart:rx=ui3:tx=uo0:baudrate=115200:parity=even", "modbus:scchannel=TX:cschannel=RX"],
               [(k, "modbus", lambda l, k=k: modbus(l, k)) for k in ("ids", "crc", "exceptions")]),
    "dali": (["dali:dali=ui3"],
             [(k, "dali=address:command:reply", lambda l, k=k: dali(l, k)) for k in ("data", "reply")]),
}


def downsample(vcd):
    """The VCDs have a 1 ns timescale, so sigrok would make 20 or more samples per simulated
    cycle. Take the largest factor that still puts every edge exactly on a sample (a divisor of
    every timestamp), keeping the sample period at 200 ns or less."""
    g = 0
    for line in vcd.read_text().splitlines():
        if line.startswith("#"):
            g = math.gcd(g, int(line[1:]))
            if g == 1:
                return 1
    return max((k for k in range(1, 201) if g % k == 0), default=1)


# The stock S/PDIF decoder learns the clock from the first three pulse widths it sees, and
# counts the idle time before the stream's first edge as one of them. A real capture starts in
# the middle of a stream, so its recording is read from the data line's first edge on. Learning
# the clock uses up the first preamble, so its first sample is the second subframe's.
START_AT_FIRST_EDGE = {"spdif": "uo0"}


def first_edge(vcd, channel):
    ident, t, seen_start = None, 0, False
    for line in vcd.read_text().splitlines():
        f = line.split()
        if line.startswith("$var") and f[4] == channel:
            ident = f[3]
        elif line.startswith("#"):
            t = int(line[1:])
            seen_start = seen_start or t > 0
        elif ident and seen_start and line[1:] == ident:
            return t
    return 0


def decode(vcd, stack, selector, name=None):
    opts = f"vcd:downsample={downsample(vcd)}"
    if name in START_AT_FIRST_EDGE:
        opts += f":skip={first_edge(vcd, START_AT_FIRST_EDGE[name])}"
    cmd = ["sigrok-cli", "-I", opts, "-i", str(vcd), "-P", ",".join(stack), "-A", selector]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [l.split(": ", 1)[1] for l in out.splitlines() if ": " in l]


def hexes(vs):
    return " ".join(f"{v:02x}" for v in vs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", type=pathlib.Path)
    ap.add_argument("--md", type=pathlib.Path)
    ap.add_argument("--skip-missing", action="store_true",
                    help="leave out cases with no recording (a run of one test file)")
    a = ap.parse_args()
    rows, bad = [], 0
    for name, (stack, checks) in CASES.items():
        vcd, exp = a.dir / f"{name}.vcd", a.dir / f"{name}.expect"
        if not vcd.exists():
            if a.skip_missing:
                continue
            rows.append((name, "-", "-", "-", "NO VCD"))
            bad += 1
            continue
        want = dict((l.split()[0], [int(x, 16) for x in l.split()[1:]])
                    for l in exp.read_text().splitlines() if l.strip())
        for key, selector, parse in checks:
            got = [v for line in decode(vcd, stack, selector, name) for v in parse(line)]
            ok = got == want.get(key)
            bad += not ok
            rows.append((name, stack[-1].split(":")[0], key, hexes(want.get(key, [])),
                         "agree" if ok else f"DIFFERS: sigrok read {hexes(got)}"))
    table = ["| test | decoder | field | the test's own data | sigrok |",
             "|---|---|---|---|---|"] + [f"| {' | '.join(r)} |" for r in rows]
    print("\n".join(table))
    if a.md:
        a.md.write_text("\n".join(table) + "\n")
    print(f"\n{len(rows) - bad} of {len(rows)} fields agree")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
