# Connect the SRAM macros to the tile power grid.
#
# The tile grid is a set of vertical Metal4 stripes. The power generator stops each stripe at the
# edge of an SRAM, and the SRAM only exposes power as Metal4 columns, so nothing is connected
# yet. The stripe pitch/spacing and the macro position are chosen so that some stripes sit
# exactly on top of a power column of the same net. For those, this step adds Metal4 over the
# column's pin shapes that touch the macro edge, joining the stripe stub to the SRAM.
# Columns are covered where the macro declares a pin of the right net. Some columns are one net
# in two pieces (VDD! over the periphery, VDDARRAY! over the array, both VPWR, with a gap between
# them); once a stripe has joined such a column, the gap is bridged too, but only if no other
# Metal4 shape of the macro lies in it. Without that, VDDARRAY! is only reached from below the
# SRAM, and with no cell rows under the SRAM nothing powers it.
#
# It also drops the power pins the generator put on the short stubs, since tile power pins
# must run the full height.
#
# Fails if a macro ends up without both a power and a ground connection.

import sys

import click
import odb
from reader import click_odb

POWER_NETS = {"POWER": "VPWR", "GROUND": "VGND"}
EDGE_TOLERANCE_UM = 2.0
PIN_EDGE_MARGIN_UM = 10.0  # TT precheck: power pins must reach within 10 um of top and bottom


def macro_power_shapes(inst, layer_name):
    """Absolute pin shapes of a macro placed R0 or MX (mirrored top to bottom) on one layer,
    as {net: [(x0, y0, x1, y1)]}."""
    bbox = inst.getBBox()
    ox, oy = bbox.xMin(), bbox.yMin()
    height = inst.getMaster().getHeight()
    orient = str(inst.getOrient())
    if orient not in ("R0", "MX"):
        raise SystemExit(f"{inst.getName()}: orientation {orient} not handled")
    mirrored = orient == "MX"
    shapes = {}
    for mterm in inst.getMaster().getMTerms():
        net = POWER_NETS.get(str(mterm.getSigType()))
        if net is None:
            continue
        for mpin in mterm.getMPins():
            for box in mpin.getGeometry():
                if box.getTechLayer().getName() == layer_name:
                    y0, y1 = box.yMin(), box.yMax()
                    if mirrored:
                        y0, y1 = height - y1, height - y0
                    shapes.setdefault(net, []).append(
                        (box.xMin() + ox, y0 + oy, box.xMax() + ox, y1 + oy)
                    )
    return shapes


def macro_layer_shapes(inst, layer_name):
    """Every shape of the macro on one layer, pins of any net and obstructions, as absolute
    (x0, y0, x1, y1), placed the same way as macro_power_shapes."""
    bbox = inst.getBBox()
    ox, oy = bbox.xMin(), bbox.yMin()
    height = inst.getMaster().getHeight()
    mirrored = str(inst.getOrient()) == "MX"
    boxes = []
    for mterm in inst.getMaster().getMTerms():
        for mpin in mterm.getMPins():
            boxes += list(mpin.getGeometry())
    boxes += list(inst.getMaster().getObstructions())
    out = []
    for box in boxes:
        if box.getTechLayer() is None or box.getTechLayer().getName() != layer_name:
            continue
        y0, y1 = box.yMin(), box.yMax()
        if mirrored:
            y0, y1 = height - y1, height - y0
        out.append((box.xMin() + ox, y0 + oy, box.xMax() + ox, y1 + oy))
    return out


def bridge_column_gaps(swire, layer, stripe, same_net, all_shapes, um):
    """Bridge the gaps between consecutive pieces of one net in the column under a stripe.
    A gap is only bridged if no shape of the macro on this layer overlaps it. Returns the count."""
    x0, x1 = stripe.xMin(), stripe.xMax()
    column = sorted((s for s in same_net if s[0] <= x0 and x1 <= s[2]), key=lambda s: s[1])
    added = 0
    for lo, hi in zip(column, column[1:]):
        g0, g1 = lo[3], hi[1]
        if g0 >= g1:
            continue
        blocked = [s for s in all_shapes if s[0] < x1 and x0 < s[2] and s[1] < g1 and g0 < s[3]]
        if blocked:
            print(f"    gap y {um(g0):.3f}-{um(g1):.3f} not bridged: {len(blocked)} shape(s) in it")
            continue
        add_box(swire, layer, x0, g0, x1, g1)
        added += 1
        print(f"    -> bridged column gap y {um(g0):.3f}-{um(g1):.3f}")
    return added


def add_box(swire, layer, x0, y0, x1, y1):
    try:
        odb.dbSBox_create(swire, layer, x0, y0, x1, y1, "STRIPE")
    except TypeError:
        odb.dbSBox_create(swire, layer, x0, y0, x1, y1, odb.dbWireShapeType("STRIPE"))


@click.command()
@click.option("--layer", "layer_name", default="Metal4")
@click_odb
def main(reader, layer_name):
    block = reader.block
    layer = reader.tech.findLayer(layer_name)
    dbu = block.getDbUnitsPerMicron()
    um = lambda v: v / dbu
    tol = int(EDGE_TOLERANCE_UM * dbu)
    macros = [i for i in block.getInsts() if i.getMaster().getName().startswith("RM_IHPSG13")]
    failed = False

    for inst in macros:
        bbox = inst.getBBox()
        print(
            f"{inst.getName()}: orient {inst.getOrient()} bbox "
            f"({um(bbox.xMin()):.3f}, {um(bbox.yMin()):.3f}) - ({um(bbox.xMax()):.3f}, {um(bbox.yMax()):.3f})"
        )
        shapes = macro_power_shapes(inst, layer_name)
        all_shapes = macro_layer_shapes(inst, layer_name)
        print(f"  pin shapes on {layer_name}: " + ", ".join(f"{n}: {len(s)}" for n, s in shapes.items()))
        bridged = {"VPWR": 0, "VGND": 0}
        gaps = 0
        for net_name in ("VPWR", "VGND"):
            net = block.findNet(net_name)
            if net is None:
                print(f"  no net {net_name}")
                continue
            for swire in net.getSWires():
                for b in list(swire.getWires()):
                    if b.isVia() or b.getTechLayer().getName() != layer_name:
                        continue
                    if not (b.xMin() >= bbox.xMin() and b.xMax() <= bbox.xMax()):
                        continue
                    ends_below = bbox.yMin() - tol <= b.yMax() <= bbox.yMin()
                    starts_above = bbox.yMax() <= b.yMin() <= bbox.yMax() + tol
                    print(
                        f"  {net_name} stripe x {um(b.xMin()):.3f}-{um(b.xMax()):.3f} "
                        f"y {um(b.yMin()):.3f}-{um(b.yMax()):.3f}"
                        f"{' (stub below)' if ends_below else ''}{' (stub above)' if starts_above else ''}"
                    )
                    if not (ends_below or starts_above):
                        continue
                    joined_before = bridged[net_name]
                    for x0, y0, x1, y1 in shapes.get(net_name, []):
                        if not (x0 <= b.xMin() and b.xMax() <= x1):
                            continue
                        if ends_below and y0 == bbox.yMin():
                            add_box(swire, layer, b.xMin(), b.yMax(), b.xMax(), y1)
                        elif starts_above and y1 == bbox.yMax():
                            add_box(swire, layer, b.xMin(), y0, b.xMax(), b.yMin())
                        else:
                            continue
                        bridged[net_name] += 1
                        print(f"    -> joined to pin shape y {um(y0):.3f}-{um(y1):.3f}")
                    if bridged[net_name] > joined_before:
                        gaps += bridge_column_gaps(
                            swire, layer, b, shapes.get(net_name, []), all_shapes, um
                        )
        print(f"{inst.getName()}: bridges {bridged}, column gaps bridged {gaps}")
        if bridged["VPWR"] == 0 or bridged["VGND"] == 0:
            print(f"ERROR: {inst.getName()} is not connected to both power nets", file=sys.stderr)
            failed = True

    if not macros:
        print("no SRAM macros found")

    # The power generator puts a pin on every stripe piece, including the short stubs it cut at
    # the SRAM. The tile rules want power pins that run (almost) the full height, so drop the
    # pins on stubs. The stub metal stays and is still connected through the rails.
    die = block.getDieArea()
    margin = int(PIN_EDGE_MARGIN_UM * dbu)
    for net_name in ("VPWR", "VGND"):
        bterm = block.findBTerm(net_name)
        if bterm is None:
            continue
        # One pin holds a box per stripe piece. Rebuild each pin with only the full-height boxes.
        kept = 0
        for bpin in list(bterm.getBPins()):
            boxes = [
                (b.getTechLayer(), b.xMin(), b.yMin(), b.xMax(), b.yMax()) for b in bpin.getBoxes()
            ]
            full = [
                b for b in boxes if b[2] - die.yMin() <= margin and die.yMax() - b[4] <= margin
            ]
            for b in boxes:
                if b not in full:
                    print(f"  dropping short {net_name} pin box x {um(b[1]):.3f} y {um(b[2]):.3f}-{um(b[4]):.3f}")
            if len(full) == len(boxes):
                kept += len(full)
                continue
            status = bpin.getPlacementStatus()
            odb.dbBPin.destroy(bpin)
            if full:
                new_pin = odb.dbBPin_create(bterm)
                for layer_, x0, y0, x1, y1 in full:
                    odb.dbBox_create(new_pin, layer_, x0, y0, x1, y1)
                new_pin.setPlacementStatus(status)
                kept += len(full)
        print(f"{net_name}: {kept} full-height pin boxes kept")
        if kept == 0:
            print(f"ERROR: no full-height pin left on {net_name}", file=sys.stderr)
            failed = True

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
