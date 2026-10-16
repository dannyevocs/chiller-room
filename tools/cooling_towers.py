# The cooling tower yard south of the building: three crossflow cells (CT-1..CT-3) on a pad, with
# condenser water piping back to the south wall, valves, supports and the tower control cabinets.
# Outdoor surfaces are kind 12 (room.wgsl shades them by the sun and sky); params: 0 painted/metal,
# 1 corrugated casing, 2 concrete, 3 dark fill. Re-runnable. Run inside Blender:
#   exec(open(os.path.expanduser("~/chiller-room/tools/cooling_towers.py")).read()); print(cooling_towers())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/walkways.py")).read())   # web_mat, box, cyl, quad, new_obj, rails_along...

YARD = "Yard"
TX0, TX1 = 4.0, 22.0          # the tower row along x
TZ0, TZ1 = 25.0, 33.0         # inlet face to inlet face
CELLS = (7.0, 13.0, 19.0)     # cell centres (6 m cells)
PLEN0, PLEN1 = 27.3, 30.7     # the plenum between the two fill sections
BASIN = 0.75                  # top of the cold water basin
DECK_T = 4.75                 # fan deck
STACK_R, STACK_TOP = 1.9, 6.6
FAN_Z = (PLEN0 + PLEN1) / 2


def yard_collection():
    c = bpy.data.collections.get(YARD)
    if c is None:
        c = bpy.data.collections.new(YARD)
        bpy.context.scene.collection.children.link(c)
    return c


def out_mat(name, rgb, rough, metal, param=0):
    m = web_mat(name, rgb, rough, metal, kind=12)
    m["web_param"] = param
    return m


def cooling_towers():
    yard_collection()
    galv = out_mat("YD Galvanized", (150, 156, 160), 0.45, 0.6, 1)
    galv_plain = out_mat("YD Galvanized Plain", (165, 170, 173), 0.5, 0.5, 0)
    fill = out_mat("YD Fill", (34, 40, 42), 0.9, 0.0, 3)
    concrete = out_mat("YD Concrete", (168, 166, 160), 0.9, 0.0, 2)
    frp = out_mat("YD Fan Stack", (196, 196, 186), 0.5, 0.0, 0)
    dark = out_mat("YD Stack Inside", (40, 44, 46), 0.8, 0.2, 0)
    pipe_m = out_mat("YD CW Pipe", (56, 133, 84), 0.4, 0.1, 0)
    steel = out_mat("YD Steel", (76, 80, 86), 0.5, 0.6, 0)
    yellow = out_mat("YD Rail Yellow", (232, 178, 24), 0.45, 0.2, 0)
    panel = out_mat("YD Panel", (200, 203, 205), 0.5, 0.3, 0)

    con, cas, gp, fl, st, ins, pp, sl, rl, pn = (bmesh.new() for _ in range(10))

    # Pad and sleepers.
    box(con, 1.5, 24.5, 0.0, 0.15, 23.0, 35.0)
    # Cold water basin and casing.
    box(gp, TX0, TX1, 0.15, BASIN, TZ0, TZ1)
    box(cas, TX0 + 0.08, TX1 - 0.08, BASIN, DECK_T, PLEN0, PLEN1)
    for x in (TX0, TX1 - 0.08):
        box(cas, x, x + 0.08, BASIN, DECK_T, TZ0, TZ1)
    # Fill behind the louvres, hot water basins above it with their covers.
    for z0, z1 in ((TZ0 + 0.12, PLEN0), (PLEN1, TZ1 - 0.12)):
        box(fl, TX0 + 0.08, TX1 - 0.08, BASIN, 4.4, z0, z1)
        box(gp, TX0 + 0.08, TX1 - 0.08, 4.4, DECK_T, z0 - 0.12 if z0 < PLEN0 else z0, z1 + 0.12 if z1 > PLEN1 else z1)
        for cx in CELLS:
            box(gp, cx - 2.85, cx + 2.85, DECK_T, DECK_T + 0.05, z0 + 0.05, z1 - 0.05)
    # Louvres on both inlet faces: blades sloping up and inward, between cell posts.
    for face, inward in ((TZ0, 1.0), (TZ1, -1.0)):
        for k, x in enumerate((TX0, 10.0, 16.0, TX1)):
            box(gp, x - 0.06, x + 0.06, BASIN, 4.4, min(face, face + inward * 0.14), max(face, face + inward * 0.14))
        y = BASIN + 0.1
        while y < 4.3:
            quad(gp, [(TX0 + 0.08, y, face), (TX1 - 0.08, y, face),
                      (TX1 - 0.08, y + 0.16, face + inward * 0.12), (TX0 + 0.08, y + 0.16, face + inward * 0.12)])
            y += 0.2
    # Fan stacks: open cylinders, dark inside, a rim, a guard and the fan below it.
    for cx in CELLS:
        cyl(st, (cx, DECK_T, FAN_Z), (cx, STACK_TOP, FAN_Z), STACK_R, seg=40)
        cyl(ins, (cx, DECK_T + 0.05, FAN_Z), (cx, STACK_TOP - 0.02, FAN_Z), STACK_R - 0.03, seg=40)
        cyl(st, (cx, STACK_TOP - 0.08, FAN_Z), (cx, STACK_TOP + 0.02, FAN_Z), STACK_R + 0.06, seg=40)
        box(ins, cx - 0.1, cx + 0.1, DECK_T + 0.05, DECK_T + 0.4, FAN_Z - 0.1, FAN_Z + 0.1)
        for ang in range(0, 180, 30):
            a = math.radians(ang)
            dx, dz = math.cos(a) * (STACK_R + 0.02), math.sin(a) * (STACK_R + 0.02)
            cyl(sl, (cx - dx, STACK_TOP + 0.03, FAN_Z - dz), (cx + dx, STACK_TOP + 0.03, FAN_Z + dz), 0.015, seg=6)
        for ang in range(0, 360, 60):
            a = math.radians(ang + 15)
            cyl(ins, (cx, DECK_T + 0.6, FAN_Z), (cx + math.cos(a) * (STACK_R - 0.12), DECK_T + 0.66, FAN_Z + math.sin(a) * (STACK_R - 0.12)), 0.07, seg=6)
        # Gearbox and motor on the deck beside the stack.
        box(sl, cx + STACK_R + 0.3, cx + STACK_R + 0.9, DECK_T, DECK_T + 0.55, FAN_Z - 0.35, FAN_Z + 0.35)
    # Deck handrail and the caged ladder on the west end.
    rails_along(rl, [(TX0 + 0.05, DECK_T, TZ0 + 0.05), (TX1 - 0.05, DECK_T, TZ0 + 0.05), (TX1 - 0.05, DECK_T, TZ1 - 0.05),
                     (TX0 + 0.05, DECK_T, TZ1 - 0.05), (TX0 + 0.05, DECK_T, TZ0 + 0.05)], DECK_T)
    lx = TX0 - 0.35
    for z in (28.7, 29.3):
        cyl(rl, (lx, 0.15, z), (lx, DECK_T + 1.1, z), 0.03, seg=8)
    y = 0.45
    while y < DECK_T:
        cyl(rl, (lx, y, 28.7), (lx, y, 29.3), 0.016, seg=6)
        y += 0.3
    y = 2.3
    while y < DECK_T + 1.0:
        pts = [(TX0 - 0.05, y, 28.55), (lx - 0.55, y, 28.55), (lx - 0.55, y, 29.45), (TX0 - 0.05, y, 29.45)]
        for a, b in zip(pts, pts[1:]):
            cyl(rl, a, b, 0.02, seg=6)
        y += 0.75
    for z in (28.55, 29.0, 29.45):
        cyl(rl, (lx - 0.55, 2.3, z), (lx - 0.55, DECK_T + 0.95, z), 0.015, seg=6)

    # Condenser water return: out of the south wall high, south to the towers, up and across the top.
    R0 = (13.0, 2.6, 7.15)   # starts just outside the wall, so it never shows through
    cyl(pp, R0, (13.0, 2.6, 23.8), 0.2, seg=20)
    cyl(pp, (13.0, 2.6, 23.8), (13.0, 5.3, 23.8), 0.2, seg=20)
    cyl(pp, (TX0 + 0.6, 5.3, 23.8), (TX1 - 3.0, 5.3, 23.8), 0.18, seg=20)
    for cx in CELLS:
        bx = cx - 2.4
        cyl(pp, (bx, 5.3, 23.8), (bx, 5.3, 32.2), 0.11, seg=14)
        for z in (26.2, 31.8):
            cyl(pp, (bx, 5.3, z), (bx, DECK_T + 0.05, z), 0.11, seg=14)
        # Isolation valve on each branch, with its handwheel.
        cyl(pp, (bx, 5.3, 24.3), (bx, 5.3, 24.75), 0.17, seg=14, caps=True)
        cyl(st, (bx, 5.62, 24.52), (bx, 5.66, 24.52), 0.24, seg=20, caps=True)
        cyl(sl, (bx, 5.3, 24.52), (bx, 5.62, 24.52), 0.03, seg=6)
    # Condenser water supply: out of each basin low, a header along the north face, back to the wall.
    for cx in CELLS:
        cyl(pp, (cx + 1.5, 0.45, TZ0 + 0.05), (cx + 1.5, 0.45, 24.2), 0.15, seg=16)
        cyl(pp, (cx + 1.5, 0.45, 24.65), (cx + 1.5, 0.45, 24.95), 0.21, seg=16, caps=True)   # flange
    cyl(pp, (8.5, 0.45, 24.2), (20.5, 0.45, 24.2), 0.2, seg=20)
    cyl(pp, (15.0, 0.45, 24.2), (15.0, 0.45, 7.15), 0.2, seg=20)
    # Sleeves where they pass through the wall, flanges along the runs.
    for x, y in ((13.0, 2.6), (15.0, 0.45)):
        cyl(pp, (x, y, 7.03), (x, y, 7.15), 0.28, seg=20, caps=True)
        for z in (11.0, 15.0, 19.0):
            cyl(pp, (x, y, z), (x, y, z + 0.06), 0.25, seg=20, caps=True)
    # Supports: T-frames under the high return, sleepers under the low supply.
    for z in (9.5, 13.5, 17.5, 21.5):
        box(sl, 12.94, 13.06, 0.0, 2.4, z - 0.06, z + 0.06)
        box(sl, 12.6, 13.4, 2.34, 2.4, z - 0.08, z + 0.08)
        box(con, 14.6, 15.4, 0.0, 0.25, z - 0.2, z + 0.2)
    for x in (10.0, 13.0, 18.0):
        box(con, x - 0.2, x + 0.2, 0.15, 0.25, 23.8, 24.6)
    # Tower control cabinets on the pad, west of the row, with a conduit up to the deck.
    for k in range(3):
        z0 = 23.6 + k * 0.9
        box(pn, 2.2, 2.75, 0.15, 2.0, z0, z0 + 0.82)
        box(sl, 2.17, 2.2, 1.0, 1.15, z0 + 0.6, z0 + 0.66)   # handle
    box(pn, 2.1, 2.85, 2.0, 2.06, 23.5, 26.3)   # rain hood
    cyl(sl, (2.5, 2.06, 25.0), (2.5, 3.2, 25.0), 0.03, seg=6)
    cyl(sl, (2.5, 3.2, 25.0), (TX0 + 0.1, 3.2, 25.0), 0.03, seg=6)

    props = {"no_collide": True, "pick": "pass"}
    for name, bm_, m in (("Yard Pad", con, concrete), ("Tower Casing", cas, galv), ("Tower Basins and Louvres", gp, galv_plain),
                         ("Tower Fill", fl, fill), ("Tower Fan Stacks", st, frp), ("Tower Stack Insides", ins, dark),
                         ("Yard CW Piping", pp, pipe_m), ("Yard Steel", sl, steel), ("Tower Handrails and Ladder", rl, yellow),
                         ("Tower Control Cabinets", pn, panel)):
        new_obj(name, bm_, m, YARD, smooth=name in ("Yard CW Piping", "Tower Fan Stacks", "Tower Handrails and Ladder"), props=props)
    return "towers built"
