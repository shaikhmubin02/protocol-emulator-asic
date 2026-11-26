#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Mubin
# SPDX-License-Identifier: Apache-2.0
"""Attach the USB keyboard that `pemu_sim usb` exports to this Linux machine through the
kernel's vhci_hcd, the way `usbip attach` does (USB/IP 1.1.1): import the device over TCP, then
hand the connected socket to the kernel. Needs root.

    python3 usbip_attach.py [host] [port]   attach busid 1-1 (prints the vhci port)
    python3 usbip_attach.py --detach N      detach vhci port N
"""
import socket
import struct
import sys

VHCI = "/sys/devices/platform/vhci_hcd.0"


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        part = s.recv(n - len(b))
        if not part:
            raise SystemExit("the server closed the connection")
        b += part
    return b


def free_port(speed):
    hub = "ss" if speed >= 5 else "hs"  # low, full and high speed devices go on the USB 2 hub
    with open(f"{VHCI}/status") as f:
        for line in f:
            fields = line.split()
            if len(fields) > 2 and fields[0] == hub and fields[2] == "004":  # VDEV_ST_NULL
                return int(fields[1])
    raise SystemExit("no free vhci port")


def attach(host, port):
    s = socket.create_connection((host, port))
    s.sendall(struct.pack(">HHI", 0x0111, 0x8003, 0) + b"1-1".ljust(32, b"\0"))
    _, _, status = struct.unpack(">HHI", recv_exact(s, 8))
    if status:
        raise SystemExit(f"import refused ({status})")
    dev = recv_exact(s, 312)
    busnum, devnum, speed = struct.unpack(">III", dev[288:300])
    vid, pid = struct.unpack(">HH", dev[300:304])
    p = free_port(speed)
    with open(f"{VHCI}/attach", "w") as f:
        f.write(f"{p} {s.fileno()} {(busnum << 16) | devnum} {speed}")
    print(f"attached {vid:04x}:{pid:04x} (speed {speed}) on vhci port {p}")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--detach":
        with open(f"{VHCI}/detach", "w") as f:
            f.write(sys.argv[2])
        print(f"detached vhci port {sys.argv[2]}")
    else:
        attach(sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1",
               int(sys.argv[2]) if len(sys.argv) > 2 else 3240)
