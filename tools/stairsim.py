# A faithful copy of main.luau's walking rules (canStand, groundAt, the step/slide, ground follow),
# to find where pressing a direction leaves you stuck near the stair. FIX=1 adds the proposed easeIn.
import math, sys
FIX = len(sys.argv) > 1 and sys.argv[1] == "fix"
STEP_UP, R, WALK_SPEED = 0.55, 0.35, 2.5
ROOM_X0, ROOM_X1, HZ = -10, 38, 7.0
WALK = [
 dict(x0=-9.4, x1=26.8, z0=5.6, z1=6.9, y0=6, y1=6, sx0=-9.15, sx1=26.9, sz0=5.82, sz1=6.62),
 dict(x0=4.65, x1=5.85, z0=-6.9, z1=5.6, y0=6, y1=6, sx0=4.87, sx1=5.63, sz0=-6.65, sz1=6.2),
 dict(x0=20.15, x1=21.35, z0=-6.9, z1=5.6, y0=6, y1=6, sx0=20.37, sx1=21.13, sz0=-6.65, sz1=6.2),
 dict(x0=26.8, x1=35.8, z0=5.6, z1=6.9, y0=6, y1=0, stair=True, sx0=26.7, sx1=36.3, sz0=5.82, sz1=6.62),
]
clamp = lambda v, a, b: max(a, min(b, v))
def surf(w, x): return w["y0"] + (w["y1"] - w["y0"]) * clamp((x - w["x0"]) / (w["x1"] - w["x0"]), 0, 1)
def groundAt(feet, x, z):
    best = 0
    for w in WALK:
        if w["x0"] < x < w["x1"] and min(w["z0"], w["sz0"]) < z < max(w["z1"], w["sz1"]):
            h = surf(w, x)
            if h <= feet + STEP_UP and h > best: best = h
    return best
def canStand(feet, x, z):
    if feet > STEP_UP:
        return any(w["sx0"] < x < w["sx1"] and w["sz0"] < z < w["sz1"] and abs(surf(w, x) - feet) < STEP_UP + 0.3 for w in WALK)
    for w in WALK:
        if w.get("stair") and w["x0"] - R < x < w["x1"] + R and w["z0"] - R < z < w["z1"] + R:
            h = surf(w, x)
            if feet + STEP_UP < h < feet + 2.0: return False
    return True
def easeIn(feet, ox, oz, x, z):
    """Up on the stair or a walkway, a step that misses every standing area by a little is eased into
    the nearest one that still carries you forward (at least a fifth of the step), within 0.5 m."""
    if feet <= STEP_UP: return None
    dx, dz = x - ox, z - oz
    want = dx * dx + dz * dz
    # From a spot you can't stand on (it happens as your feet rise past STEP_UP), take the nearest one.
    need = 0.2 * want if canStand(feet, ox, oz) else -1e9
    best = None
    for w in WALK:
        if w["sx0"] - 0.5 < x < w["sx1"] + 0.5 and w["sz0"] - 0.5 < z < w["sz1"] + 0.5:
            cx = clamp(x, w["sx0"] + 0.01, w["sx1"] - 0.01); cz = clamp(z, w["sz0"] + 0.01, w["sz1"] - 0.01)
            if (cx - ox) * dx + (cz - oz) * dz >= need and canStand(feet, cx, cz):
                d = (cx - x) ** 2 + (cz - z) ** 2
                if best is None or d < best[0]: best = (d, cx, cz)
    return None if best is None else (best[1], best[2])
def pushOutOfStair(feet, x, z):
    # On the floor, the part of a stair too high to step onto and too low to walk under is solid:
    # if you end up inside it (walking off its side), you're moved out to its nearest edge.
    for w in WALK:
        if not w.get("stair"): continue
        z0, z1 = w["z0"] - R, w["z1"] + R
        if not (z0 < z < z1): continue
        h = surf(w, x)
        if feet + STEP_UP < h < feet + 2.0:
            # x where the surface is feet+STEP_UP (step onto it) and feet+2 (walk under it)
            def xat(y): return w["x0"] + (y - w["y0"]) / (w["y1"] - w["y0"]) * (w["x1"] - w["x0"])
            xs = sorted((xat(feet + STEP_UP), xat(feet + 2.0)))
            opts = [(z - z0, x, z0 - 0.001), (abs(x - xat(feet + STEP_UP)), xat(feet + STEP_UP) + (0.001 if xat(feet+STEP_UP) > xat(feet+2.0) else -0.001), z),
                    (abs(x - xat(feet + 2.0)), xat(feet + 2.0) + (-0.001 if xat(feet+STEP_UP) > xat(feet+2.0) else 0.001), z)]
            if z1 < HZ - R: opts.append((z1 - z, x, z1 + 0.001))
            _, x, z = min(opts)
    return x, z

def step(s, fwd, strafe, yaw, dt=1/60):
    x, z, feet = s
    fx, fz = math.sin(yaw), -math.cos(yaw); rx, rz = math.cos(yaw), math.sin(yaw)
    ln = math.hypot(fwd, strafe); st = WALK_SPEED * dt / ln
    nx, nz = x + (fx * fwd + rx * strafe) * st, z + (fz * fwd + rz * strafe) * st
    if feet < 0.05 and nx < x:
        for w in WALK:
            if w.get("stair") and w["x1"] - 1.2 < nx < w["x1"] + 0.6 and w["sz0"] - 0.7 < nz < w["sz1"] + 0.7 and surf(w, nx) <= feet + STEP_UP:
                nz = clamp(nz, w["sz0"] + 0.12, w["sz1"] - 0.12)
    e = easeIn(feet, x, z, nx, nz) if FIX and not canStand(feet, nx, nz) else None
    if canStand(feet, nx, nz): x, z = nx, nz
    elif e: x, z = e
    elif canStand(feet, nx, z): x = nx
    elif canStand(feet, x, nz): z = nz
    x = clamp(x, ROOM_X0 + R, ROOM_X1 - R); z = clamp(z, -HZ + R, HZ - R)
    if FIX and feet <= STEP_UP:
        x, z = pushOutOfStair(feet, x, z)
    g = groundAt(feet, x, z)
    feet = g if g >= feet else max(g, feet - dt * 7)
    return (x, z, feet)
# Scenario: start somewhere on or beside the stair/walkway at a valid spot, hold one direction.
stuck = trials = 0
examples = []
for sx in [i * 0.25 for i in range(int(25.5 * 4), int(36.5 * 4))]:
    for sz in [5.4 + i * 0.05 for i in range(30)]:
        for feet0 in (0.0, None):
            feet = feet0 if feet0 is not None else groundAt(6.0, sx, sz)
            if feet0 is None:
                # on the stair/walkway at its surface
                on = [w for w in WALK if w["sx0"] < sx < w["sx1"] and w["sz0"] < sz < w["sz1"]]
                if not on: continue
                feet = max(surf(w, sx) for w in on)
            if not canStand(feet, sx, sz): continue
            for yaw in [k * math.pi / 8 for k in range(16)]:
                s = (sx, sz, feet); trials += 1
                hist = [s]
                for f in range(240):
                    s = step(s, 1, 0, yaw); hist.append(s)
                a, b = hist[-61], hist[-1]
                if math.hypot(b[0] - a[0], b[1] - a[1]) < 0.02:
                    fx, fz = math.sin(yaw), -math.cos(yaw)
                    ax, az = b[0] + 0.3 * fx, b[1] + 0.3 * fz
                    inroom = ROOM_X0 + R < ax < ROOM_X1 - R and -HZ + R < az < HZ - R
                    fa = groundAt(b[2], ax, az)
                    ahead_ok = False
                    for lat in (-0.3, -0.15, 0.0, 0.15, 0.3):
                        bx, bz = ax + lat * -fz, az + lat * fx
                        fb = groundAt(b[2], bx, bz)
                        if ROOM_X0 + R < bx < ROOM_X1 - R and -HZ + R < bz < HZ - R and (canStand(b[2], bx, bz) or canStand(fb, bx, bz)) and abs(fb - b[2]) < 0.6:
                            ahead_ok = True
                    # A real barrier: up high, a handrail (straight ahead is off every deck); on the floor, the stair's solid side.
                    if b[2] > STEP_UP:
                        legit = not any(w["x0"] < ax < w["x1"] and w["z0"] < az < w["z1"] and abs(surf(w, ax) - b[2]) < 0.85 for w in WALK)
                    else:
                        legit = True
                    if not canStand(b[2], b[0], b[1]) or (ahead_ok and not legit):
                        stuck += 1
                        if len(examples) < 8: examples.append((round(sx,2), round(sz,2), round(feet,2), round(yaw,2), tuple(round(v,2) for v in b), canStand(b[2], b[0], b[1])))
print("FIX" if FIX else "CURRENT", "trials", trials, "snags", stuck)
for e in examples: print("  start x,z,feet,yaw", e[:4], "-> stuck at", e[4], "standable:", e[5])
