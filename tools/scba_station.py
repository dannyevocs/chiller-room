# The refrigerant safety station by the plant room door (south wall, x 2.75..5.45): backboard and
# header, SCBA cabinet with the air pack and mask inside, SDS box, handheld leak detector, a DANGER
# sign and a floor outline. Re-runnable. Run inside Blender:
#   exec(open(os.path.expanduser("~/chiller-room/tools/scba_station.py")).read()); print(scba_station())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/pumpout_hoist.py")).read())   # mat, sphere, polyline, label_quad, box, cyl...

WALL = 6.94          # the station's face; kept off z > 6.97, which room.wgsl lights as a window reveal
CX0, CX1, CY0, CY1, CZ = 3.6, 4.4, 1.0, 2.0, 6.6   # SCBA cabinet (front at CZ)


def wall_label(name, x0, x1, y0, y1, z, pick):
    """A label on the south wall, read facing south (your right is -x)."""
    label_quad(name, [(x1, y0, z), (x0, y0, z), (x0, y1, z), (x1, y1, z)], pick)


def scba_station():
    red = mat("SS Cabinet Red", (196, 30, 28), 0.4, 0.2)
    board = mat("SS Backboard", (236, 236, 232), 0.6, 0.0)
    black = mat("SS Rubber Black", (24, 25, 27), 0.7, 0.0)
    tank = mat("SS Air Cylinder", (60, 66, 62), 0.35, 0.5)
    silver = mat("SS Silver", (190, 192, 196), 0.25, 0.9)
    visor = mat("SS Visor", (170, 195, 210), 0.05, 0.0, kind=5)
    yellow = mat("SS Yellow", (238, 186, 20), 0.45, 0.1)
    steel = mat("SS Steel", (70, 74, 80), 0.5, 0.6)
    binder = [mat("SS Binder Blue", (30, 70, 160), 0.6, 0.0), mat("SS Binder Red", (170, 30, 30), 0.6, 0.0),
              mat("SS Binder Green", (30, 120, 60), 0.6, 0.0)]
    stripe = bpy.data.materials["RM Safety Stripe"]
    for ob in [o for o in bpy.data.objects if o.name.startswith("SCBA Binder ")]:
        bpy.data.objects.remove(ob, do_unlink=True)

    bd, cb, pk, ms, vs, sv, yl, st, fl = (bmesh.new() for _ in range(9))
    # Backboard with a red edge.
    box(bd, 2.75, 5.45, 0.95, 2.45, WALL, 6.995)
    for a, b, c, d in ((2.72, 5.48, 0.92, 0.95), (2.72, 5.48, 2.45, 2.48), (2.72, 2.75, 0.92, 2.48), (5.45, 5.48, 0.92, 2.48)):
        box(cb, a, b, c, d, WALL - 0.005, 6.995)
    # Cabinet: back, sides, top and bottom, open at the front; a door frame (no glass: the window reads clear).
    t = 0.025
    box(cb, CX0, CX1, CY0, CY1, WALL - t, WALL)
    box(cb, CX0, CX0 + t, CY0, CY1, CZ + 0.02, WALL)
    box(cb, CX1 - t, CX1, CY0, CY1, CZ + 0.02, WALL)
    box(cb, CX0, CX1, CY1 - t, CY1, CZ + 0.02, WALL)
    box(cb, CX0, CX1, CY0, CY0 + t, CZ + 0.02, WALL)
    for a, b, c, d in ((CX0, CX1, CY0, CY0 + 0.07), (CX0, CX1, CY1 - 0.16, CY1),
                       (CX0, CX0 + 0.06, CY0, CY1), (CX1 - 0.06, CX1, CY0, CY1)):
        box(cb, a, b, c, d, CZ, CZ + 0.02)
    for y in (CY0 + 0.15, CY1 - 0.25):
        cyl(st, (CX0 + 0.005, y, CZ + 0.01), (CX0 + 0.005, y + 0.08, CZ + 0.01), 0.012, seg=8, caps=True)   # hinges
    box(st, CX1 - 0.05, CX1 - 0.03, 1.4, 1.6, CZ - 0.04, CZ)   # handle
    box(st, CX1 - 0.05, CX1 - 0.03, 1.4, 1.42, CZ - 0.04, CZ - 0.02)
    # The air pack: backplate, cylinder (valve down), straps and belt.
    box(pk, 3.88, 4.18, 1.12, 1.84, WALL - 0.08, WALL - 0.03)
    cyl(vs, (4.03, 1.22, 6.8), (4.03, 1.76, 6.8), 0.085, seg=24, caps=True)
    sphere(vs, (4.03, 1.76, 6.8), 0.085, scale=(1, 0.5, 1), seg=20)
    cyl(sv, (4.03, 1.12, 6.8), (4.03, 1.22, 6.8), 0.03, seg=12, caps=True)
    cyl(sv, (4.03, 1.15, 6.8), (4.1, 1.15, 6.8), 0.022, seg=10, caps=True)   # valve handwheel stem
    for x in (3.95, 4.11):
        box(pk, x - 0.022, x + 0.022, 1.42, 1.86, 6.695, 6.712)
    box(pk, 3.84, 4.22, 1.18, 1.24, 6.69, 6.72)
    box(sv, 4.0, 4.06, 1.19, 1.23, 6.685, 6.69)   # buckle
    cyl(sv, (4.11, 1.52, 6.69), (4.11, 1.52, 6.682), 0.025, seg=14, caps=True)   # gauge on the strap
    # Face mask on a hook to the left of the pack, with its visor, regulator and hose to the valve.
    box(st, 3.7, 3.73, 1.78, 1.8, 6.78, WALL - 0.02)
    sphere(ms, (3.76, 1.6, 6.77), 0.1, scale=(0.85, 1.25, 0.6), seg=20)
    sphere(sv, (3.76, 1.62, 6.73), 0.075, scale=(0.85, 1.15, 0.45), seg=18)
    box(sv, 3.735, 3.785, 1.46, 1.5, 6.7, 6.73)
    cyl(ms, (3.76, 1.47, 6.72), (3.76, 1.42, 6.72), 0.03, seg=12, caps=True)   # regulator
    polyline(ms, [(3.76, 1.42, 6.72), (3.78, 1.25, 6.73), (3.86, 1.14, 6.76), (4.0, 1.12, 6.79)], 0.012)
    # SDS box with binders, the leak detector on its bracket.
    box(yl, 2.95, 3.4, 1.2, 1.75, WALL - 0.11, WALL)
    for k, m in enumerate(binder):
        b = bmesh.new()
        x = 3.0 + k * 0.13
        box(b, x, x + 0.1, 1.72, 1.8, WALL - 0.09, WALL - 0.02)
        new_obj(f"SCBA Binder {k + 1}", b, m, "Plant", smooth=False, props={"pick": "safety:REFSTATION", "no_collide": True})
    box(st, 4.66, 5.0, 1.2, 1.23, WALL - 0.14, WALL)
    box(st, 4.66, 4.68, 1.12, 1.2, WALL - 0.02, WALL)
    box(yl, 4.74, 4.86, 1.23, 1.43, WALL - 0.1, WALL - 0.03)
    polyline(ms, [(4.8, 1.43, WALL - 0.065), (4.8, 1.52, WALL - 0.065), (4.84, 1.6, WALL - 0.08), (4.9, 1.63, WALL - 0.1)], 0.006)
    cyl(sv, (4.9, 1.63, WALL - 0.1), (4.94, 1.645, WALL - 0.115), 0.008, seg=8, caps=True)
    # Keep-clear outline on the floor in front.
    for a, b, c, d in ((2.7, 5.5, 6.0, 6.06), (2.7, 2.76, 6.0, 6.95), (5.44, 5.5, 6.0, 6.95)):
        box(fl, a, b, 0.0, 0.004, c, d)

    s1 = {"pick": "safety:SCBA"}
    s2 = {"pick": "safety:REFSTATION"}
    nc = {"no_collide": True}
    for name, bm_, m, p in (("SCBA Station Backboard", bd, board, s2), ("SCBA Cabinet", cb, red, s1),
                            ("SCBA Air Pack", pk, black, dict(s1, **nc)), ("SCBA Cylinder", vs, tank, dict(s1, **nc)),
                            ("SCBA Mask and Hose", ms, black, dict(s1, **nc)), ("SCBA Fittings", sv, silver, dict(s1, **nc)),
                            ("SCBA Station Yellow", yl, yellow, dict(s2, **nc)), ("SCBA Station Hardware", st, steel, dict(s2, **nc)),
                            ("SCBA Floor Outline", fl, stripe, {"pick": "pass", "no_collide": True})):
        new_obj(name, bm_, m, "Plant", smooth=name in ("SCBA Cylinder", "SCBA Mask and Hose"), props=p)
    # The visor is the mask's front: its own glassy material.
    vz = bmesh.new()
    sphere(vz, (3.76, 1.63, 6.725), 0.066, scale=(0.8, 1.05, 0.42), seg=18)
    new_obj("SCBA Mask Visor", vz, visor, "Plant", smooth=True, props=dict(s1, **nc))

    z = WALL - 0.003
    wall_label("Label Station Header", 2.85, 5.35, 2.29, 2.42, z, "safety:REFSTATION")
    wall_label("Label Sign Refrigerant Leak", 4.62, 5.32, 1.72, 2.2, z, "safety:REFSTATION")
    wall_label("Label SDS Box", 3.0, 3.35, 1.42, 1.68, WALL - 0.113, "safety:REFSTATION")
    wall_label("Label SCBA Door", CX0 + 0.07, CX1 - 0.07, CY1 - 0.15, CY1 - 0.02, CZ - 0.002, "safety:SCBA")
    wall_label("Label SCBA Tag", CX1 - 0.062, CX1 - 0.004, 1.17, 1.32, CZ - 0.002, "safety:SCBA")
    return "safety station built"
