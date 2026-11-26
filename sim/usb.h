// SPDX-FileCopyrightText: © 2026 Mubin
// SPDX-License-Identifier: Apache-2.0
//
// The chip as a USB low-speed keyboard (usb_dev_rx.s on engine 0, usb_dev_tx.s on engine 1),
// with this program as its host controller and board processor. See usb.cpp.
#pragma once

namespace usb {
// enumerate the keyboard and read its key reports, all in this program
int selftest();
// a USB/IP server on 127.0.0.1:<port>: Linux attaches the keyboard through vhci_hcd
int serve(int port);
}  // namespace usb
