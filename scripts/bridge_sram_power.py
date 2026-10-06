# Connect the SRAM macros to the tile power grid.
#
# The tile grid is a set of vertical Metal4 stripes. The power generator stops each stripe at the
# edge of an SRAM, and the SRAM only exposes power as Metal4 columns, so nothing is connected
# yet. The stripe pitch/spacing and the macro position are chosen so that some stripes sit
# exactly on top of a power column of the same net. For those, this step adds Metal4 over the
# column's pin shapes that touch the macro edge, joining the stripe stub to the SRAM.
# Columns are only covered where the macro declares a pin of the right net, never across gaps.
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
    """Absolute pin shapes of an R0-placed macro on one layer, as {net: [(x0, y0, x1, y1)]}."""
    bbox = inst.getBBox()
    ox, oy = bbox.xMin(), bbox.yMin()
    shapes = {}
    for mterm in inst.getMaster().getMTerms():
        net = POWER_NETS.get(str(mterm.getSigType()))
        if net is None:
            continue
        for mpin in mterm.getMPins():
            for box in mpin.getGeometry():
                if box.getTechLayer().getName() == layer_name:
                    shapes.setdefault(net, []).append(
                        (box.xMin() + ox, box.yMin() + oy, box.xMax() + ox, box.yMax() + oy)
                    )
    return shapes


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
        print(f"  pin shapes on {layer_name}: " + ", ".join(f"{n}: {len(s)}" for n, s in shapes.items()))
        bridged = {"VPWR": 0, "VGND": 0}
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
        print(f"{inst.getName()}: bridges {bridged}")
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
