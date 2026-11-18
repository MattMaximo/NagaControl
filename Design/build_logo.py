#!/usr/bin/env python3
"""Rebuild every Naga Control "Gamer Boo" logo asset in this folder.

    python3 Design/build_logo.py            # write SVGs, PNGs, .iconset, .icns, preview
    python3 Design/build_logo.py --svg-only # write the SVGs only (no Chrome needed)

Standard library only. Rasterising uses headless Google Chrome; the .icns uses
the system `iconutil`.

The ghost itself is never redrawn: the body, eyes and smile paths are read
verbatim from the locked Boo vector in ~/ghosts at the pinned commit below.
Everything this script adds (headset, boom mic, can) is positioned from that
real contour, so the headset band is a true offset of Boo's own crown.
"""
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GHOSTS_REPO = os.path.expanduser("~/ghosts")
GHOSTS_COMMIT = "f17df54370314e1e962a2e4b498ecfe80eb39171"  # origin/main when designed
BOO_PATH = "src/lib/ghost-avatar/reference/boo.svg"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# ---- palette ---------------------------------------------------------------
INK = "#060505"          # Boo's own outline colour (from boo.svg)
WHITE = "#ffffff"        # Boo's own body fill
GREEN = "#44D62C"        # accent (ear cups, can, mic light)
GREEN_DARK = "#2A9E18"   # accent shade
GREEN_LIGHT = "#A5F291"  # accent highlight
BAND = "#474C56"         # headband / boom charcoal
BAND_LIGHT = "#7C8492"   # headband highlight
PAD = "#2B2E34"          # ear cushions, mic foam
METAL = "#D5D9DF"        # can lid and base
METAL_DARK = "#9AA1AC"
TILE_TOP = "#33373F"     # app icon tile gradient
TILE_BOTTOM = "#121316"
RIM = "#F3F5F8"          # sticker rim round the mascot on the dark tile
SMALL_BAND = "#BCC3CF"   # headband in the 16/32 px icons and nowhere else

# Approved Boo eye recipe (reference-layers.ts): scale .85 about each eye centre.
EYE_CENTERS = {"left": (120.6785, 228.2085), "right": (210.5765, 212.088)}
EYE_SCALE = 0.85


# ---- reference artwork -----------------------------------------------------
def load_boo():
    src = subprocess.run(
        ["git", "-C", GHOSTS_REPO, "show", f"{GHOSTS_COMMIT}:{BOO_PATH}"],
        check=True, capture_output=True, text=True).stdout

    def d(attr):
        m = re.search(r'<path\b[^>]*\s%s\s[^>]*?\bd="([^"]+)"' % re.escape(attr), src)
        if not m:
            raise SystemExit(f"boo.svg: missing {attr}")
        return m.group(1)

    return {
        "body_fill": d('data-contour="body-fill"'),
        "body_outline": d('data-contour="body-outline"'),
        "eye_left": d('data-eye="left"'),
        "eye_right": d('data-eye="right"'),
        "refl_left_primary": d('data-reflection="left-primary"'),
        "refl_left_secondary": d('data-reflection="left-secondary"'),
        "refl_right_primary": d('data-reflection="right-primary"'),
        "refl_right_secondary": d('data-reflection="right-secondary"'),
        "mouth": d('data-part="mouth"'),
    }


def polyline(d):
    return [(float(x), float(y)) for x, y in re.findall(r"(-?[\d.]+) (-?[\d.]+)", d)]


# ---- geometry helpers ------------------------------------------------------
def resample(pts, step):
    out = [pts[0]]
    carry = 0.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        pos = step - carry
        while pos <= seg:
            t = pos / seg
            out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
            pos += step
        carry = (carry + seg) % step
    return out


def smooth(pts, sigma_pts):
    n = len(pts)
    r = int(sigma_pts * 3)
    w = [math.exp(-0.5 * (k / sigma_pts) ** 2) for k in range(-r, r + 1)]
    out = []
    for i in range(n):
        sx = sy = sw = 0.0
        for k in range(-r, r + 1):
            j = min(max(i + k, 0), n - 1)
            sx += pts[j][0] * w[k + r]
            sy += pts[j][1] * w[k + r]
            sw += w[k + r]
        out.append((sx / sw, sy / sw))
    return out


def frames(pts):
    """Point, unit tangent and outward normal (contour runs left -> top -> right)."""
    out = []
    n = len(pts)
    for i in range(n):
        a = pts[max(i - 3, 0)]
        b = pts[min(i + 3, n - 1)]
        tx, ty = b[0] - a[0], b[1] - a[1]
        L = math.hypot(tx, ty)
        tx, ty = tx / L, ty / L
        out.append((pts[i], (tx, ty), (ty, -tx)))
    return out


def offset(fr, dist):
    return [(p[0] + n[0] * dist, p[1] + n[1] * dist) for p, _, n in fr]


def spline(pts, every):
    """Catmull-Rom through every Nth point, as an SVG cubic path."""
    keep = pts[::every]
    if keep[-1] != pts[-1]:
        keep.append(pts[-1])
    P = [keep[0]] + keep + [keep[-1]]
    d = "M%.2f %.2f" % keep[0]
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += " C%.2f %.2f %.2f %.2f %.2f %.2f" % (c1 + c2 + p2)
    return d


def nearest_y(fr, y, side):
    """Index of the crown frame closest to height y on the 'left' or 'right' half."""
    top = min(range(len(fr)), key=lambda i: fr[i][0][1])
    idx = range(0, top) if side == "left" else range(top, len(fr))
    return min(idx, key=lambda i: abs(fr[i][0][1] - y))


# ---- gamer kit -------------------------------------------------------------
# All numbers are in boo.svg user units (Boo's head is ~200 wide).
CAN_CENTER = (320.0, 258.0)
CAN_TILT = 14.0
CAN_SCALE = 0.94
CAN_LINE = 6.0


class Kit:
    """Headset proportions, in boo.svg units."""

    def __init__(self, gap=8.5, band=25.0, band_end=19.0, end_gap=10.5, cup=1.0, line=6.5,
                 cup_y=(221.0, 186.0)):
        self.gap = gap            # clear space between crown outline and band
        self.band = band          # band thickness over the crown, outline included
        self.band_end = band_end  # band thickness where it enters the hinges
        self.end_gap = end_gap    # gap at the hinges (the band lifts slightly into them)
        self.cup = cup            # ear-cup scale
        self.line = line          # outline weight (Boo's own outline is ~7.5)
        self.cup_y = {"left": cup_y[0], "right": cup_y[1]}


MASTER_KIT = Kit()


def crown_frames(boo):
    outer = polyline(boo["body_fill"])
    # Points 12..72 run from the left arm joint, over the crown, to the right arm joint.
    crown = smooth(resample(outer[12:73], 2.0), 3.0)
    return frames(crown)


CUP_FOLLOW = 0.15  # 0 = cups share the face's tilt exactly, 1 = each lies flat on its side of the head


def cup_frame(fr, kit, side):
    """Local frame for one ear cup. Origin on the head contour, x pointing away from
    the head, y pointing down it. The cup takes the tilt of Boo's face (the eye line),
    eased a little toward the local head contour so it still sits flat on the head."""
    i = nearest_y(fr, kit.cup_y[side], side)
    lo, hi = max(i - 10, 0), min(i + 10, len(fr) - 1)
    top, bottom = (fr[hi][0], fr[lo][0]) if side == "left" else (fr[lo][0], fr[hi][0])
    cx, cy = bottom[0] - top[0], bottom[1] - top[1]
    L = math.hypot(cx, cy)
    (lx, ly), (rx, ry) = EYE_CENTERS["left"], EYE_CENTERS["right"]
    E = math.hypot(rx - lx, ry - ly)
    hx, hy = -(ry - ly) / E, (rx - lx) / E          # "down the face"
    tx = hx * (1 - CUP_FOLLOW) + cx / L * CUP_FOLLOW
    ty = hy * (1 - CUP_FOLLOW) + cy / L * CUP_FOLLOW
    L = math.hypot(tx, ty)
    tx, ty = tx / L, ty / L
    nx, ny = ty, -tx
    if nx * fr[i][2][0] + ny * fr[i][2][1] < 0:
        nx, ny = -nx, -ny
    return {"i": i, "c": fr[i][0], "n": (nx, ny), "t": (tx, ty), "k": kit.cup}


def to_global(frame, x, y):
    c, n, t, k = frame["c"], frame["n"], frame["t"], frame["k"]
    return (c[0] + (n[0] * x + t[0] * y) * k, c[1] + (n[1] * x + t[1] * y) * k)


def to_local(frame, gx, gy):
    c, n, t, k = frame["c"], frame["n"], frame["t"], frame["k"]
    dx, dy = gx - c[0], gy - c[1]
    return ((dx * n[0] + dy * n[1]) / k, (dx * t[0] + dy * t[1]) / k)


def frame_matrix(frame):
    c, n, t, k = frame["c"], frame["n"], frame["t"], frame["k"]
    return "matrix(%.4f %.4f %.4f %.4f %.3f %.3f)" % (n[0] * k, n[1] * k, t[0] * k, t[1] * k, c[0], c[1])


CUP_BLOCK = "M0 -25 H18 Q30 -25 30 -13 V13 Q30 25 18 25 H0 Q-12 25 -12 13 V-13 Q-12 -25 0 -25 Z"


def cup_markup(frame, kit, side):
    """One ear cup: a single rounded block, dark cushion against the head, green shell outside."""
    m = frame_matrix(frame)
    w = kit.line / kit.cup
    return f"""
  <g data-part="headset-cup-{side}" transform="{m}" stroke-linejoin="round" stroke-linecap="round">
    <path data-part="cup-cushion" d="{CUP_BLOCK}" fill="{PAD}"/>
    <path data-part="cup-shell" d="M8 -25 H18 Q30 -25 30 -13 V13 Q30 25 18 25 H8 Z" fill="{GREEN}"/>
    <path data-part="cup-shade" d="M8 11 H30 V13 Q30 25 18 25 H8 Z" fill="{GREEN_DARK}"/>
    <path data-part="cup-highlight" d="M15 -18.5 H18 Q23.5 -18.5 23.5 -13" fill="none" stroke="{GREEN_LIGHT}" stroke-width="3.2"/>
    <path data-part="cup-outline" d="{CUP_BLOCK} M8 -25 V25" fill="none" stroke="{INK}" stroke-width="{w:.2f}"/>
  </g>"""


def band_markup(span, kit):
    """Headband as a true offset of Boo's crown: constant gap, tapering toward the cups."""
    n = len(span)
    inner, outer, shine = [], [], []
    for i, (p, _, nm) in enumerate(span):
        u = min(i, n - 1 - i) / (n - 1)            # 0 at the cups .. 0.5 over the crown
        s = min(u / 0.22, 1.0)
        s = s * s * (3 - 2 * s)
        g = kit.end_gap + (kit.gap - kit.end_gap) * s
        w = kit.band_end + (kit.band - kit.band_end) * s
        lo = g + kit.line / 2                      # stroke centre; its inner edge sits at the gap
        hi = g + w - kit.line / 2
        inner.append((p[0] + nm[0] * lo, p[1] + nm[1] * lo))
        outer.append((p[0] + nm[0] * hi, p[1] + nm[1] * hi))
        shine.append((p[0] + nm[0] * (hi - 5.8), p[1] + nm[1] * (hi - 5.8)))
    d = spline(inner, 6) + " L" + spline(outer[::-1], 6)[1:] + " Z"
    trim = int(n * 0.14)
    return f"""
  <g data-part="headset-band">
    <path d="{d}" fill="{BAND}" stroke="{INK}" stroke-width="{kit.line}" stroke-linejoin="round"/>
    <path d="{spline(shine[trim:-trim], 6)}" fill="none" stroke="{BAND_LIGHT}" stroke-width="2.8" stroke-linecap="round"/>
  </g>""", outer


MIC_AT = (145.0, 265.0)


def headset(boo, kit):
    """Returns (band, mic, cups, extent points)."""
    fr = crown_frames(boo)
    left = cup_frame(fr, kit, "left")
    right = cup_frame(fr, kit, "right")
    reach = int(round(5 * kit.cup))
    span = fr[left["i"] + reach:right["i"] - reach + 1]
    band, outer = band_markup(span, kit)
    # The band runs down behind each cup, so there is no separate joint to line up.
    cups = cup_markup(left, kit, "left") + cup_markup(right, kit, "right")
    # Boom mic: comes out from behind the left cushion, turns under the eye and stops
    # below-left of the smile, so the Boo face stays untouched. It is drawn before the
    # cups, so its start is hidden and nothing has to line up on the cup itself.
    sx, sy = to_global(left, -4, 2)
    ox, oy = to_global(left, -24, 2)          # straight out of the cup, toward the face
    mx, my = MIC_AT
    boom = "M%.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f" % (sx, sy, ox, oy, mx - 49, my + 6, mx - 7, my)
    mic = f"""
  <g data-part="headset-mic">
    <path d="{boom}" fill="none" stroke="{INK}" stroke-width="11.4" stroke-linecap="round"/>
    <path d="{boom}" fill="none" stroke="{BAND}" stroke-width="4.6" stroke-linecap="round"/>
    <g transform="translate({mx} {my}) rotate(4)" stroke="{INK}" stroke-width="5" stroke-linejoin="round">
      <rect x="-11.5" y="-7.75" width="23" height="15.5" rx="7.75" fill="{PAD}"/>
      <path d="M-4 -7.25 V7.25" fill="none" stroke="{GREEN}" stroke-width="3.6"/>
    </g>
  </g>"""
    pad = kit.line / 2
    pts = [(x + dx, y + dy) for x, y in outer for dx, dy in ((-pad, -pad), (pad, pad))]
    for f in (left, right):
        for cx, cy in ((-12, -25), (30, -25), (30, 25), (-12, 25)):
            gx, gy = to_global(f, cx, cy)
            pts += [(gx - pad, gy - pad), (gx + pad, gy + pad)]
    return band, mic, cups, pts


def can_xy(x, y):
    a = math.radians(CAN_TILT)
    x, y = x * CAN_SCALE, y * CAN_SCALE
    return (CAN_CENTER[0] + x * math.cos(a) - y * math.sin(a),
            CAN_CENTER[1] + x * math.sin(a) + y * math.cos(a))


GRIP_SPAN = (76, 99)     # body-fill points round Boo's right mitten: top of the arm .. underside
GRIP_REACH = 26.0        # how far the mitten tip is pulled over the can
GRIP_LINE = 7.6          # Boo's own outline weight at the mitten


def mitten_grip(boo):
    """Boo's right mitten, pulled a little further out so its tip sits in front of the
    can. Built from the centre line of Boo's own arm outline, displaced toward the can
    by a bump that is zero (with zero slope) at both ends, so the line leaves the arm
    and returns to it without a seam. The locked body path under it is unchanged."""
    a, b = GRIP_SPAN
    fr = frames(smooth(resample(polyline(boo["body_fill"])[a:b + 1], 1.0), 2.0))
    centre = offset(fr, -GRIP_LINE / 2)
    n = len(centre) - 1
    t = math.radians(CAN_TILT)
    dx, dy = math.cos(t), math.sin(t)          # along the can's short axis
    pts = []
    for i, (x, y) in enumerate(centre):
        w = math.sin(math.pi * i / n) ** 2
        pts.append((x + dx * GRIP_REACH * w, y + dy * GRIP_REACH * w))
    return spline(pts, 4)


def can_markup(boo):
    """An unbranded energy can tucked into Boo's right mitten. Local frame: can centre,
    y down the can. Original art only: a plain lightning bolt, no brand marks."""
    cx, cy = CAN_CENTER
    body = "M-17 -45 C-17 -40 -22 -40 -22 -33 V37 Q-22 45 -14 46 H14 Q22 45 22 37 V-33 C22 -40 17 -40 17 -45 Z"
    return f"""
  <g data-part="energy-can" transform="translate({cx} {cy}) rotate({CAN_TILT}) scale({CAN_SCALE})" stroke-linejoin="round" stroke-linecap="round">
    <path data-part="can-metal" d="{body}" fill="{METAL}"/>
    <path data-part="can-label" d="M-22 -33 H22 V37 H-22 Z" fill="{GREEN}"/>
    <path data-part="can-shade" d="M20 -33 H22 V37 H20 Z" fill="{GREEN_DARK}"/>
    <path data-part="can-highlight" d="M-15.5 24 V30" fill="none" stroke="{GREEN_LIGHT}" stroke-width="3.4"/>
    <path data-part="can-rims" d="M-22 -33 H22 M-22 37 H22" fill="none" stroke="{INK}" stroke-width="3"/>
    <path data-part="can-outline" d="{body}" fill="none" stroke="{INK}" stroke-width="{CAN_LINE}"/>
    <ellipse data-part="can-lid" cx="0" cy="-45" rx="17" ry="4.8" fill="{METAL}" stroke="{INK}" stroke-width="4.6"/>
    <path data-part="can-tab" d="M-7 -45.2 H2" fill="none" stroke="{METAL_DARK}" stroke-width="3"/>
    <circle data-part="can-rivet" cx="6.5" cy="-45.2" r="1.3" fill="{METAL_DARK}"/>
    <path data-part="can-bolt" transform="translate(9.5 3) scale(.8) translate(-6.25 -2)" d="M10 -22 L-3 5 H5.5 L1.5 26 L15.5 -3 H7.5 Z" fill="{INK}" stroke="{INK}" stroke-width="2.6"/>
  </g>
  <path data-part="mitten-grip" d="{mitten_grip(boo)}" fill="{WHITE}" stroke="{INK}" stroke-width="{GRIP_LINE}" stroke-linecap="round" stroke-linejoin="round"/>"""


def can_extent():
    pad = CAN_LINE / 2
    return [(x + dx, y + dy) for x, y in (can_xy(-22, -51), can_xy(22, -51), can_xy(22, 46), can_xy(-22, 46))
            for dx, dy in ((-pad, -pad), (pad, pad))]


def eye_markup(boo):
    out = []
    for side in ("left", "right"):
        x, y = EYE_CENTERS[side]
        inner = (
            f'<path data-eye="{side}" d="{boo["eye_" + side]}" fill="#020202" fill-rule="evenodd"/>'
            f'<path data-reflection="{side}-primary" d="{boo["refl_" + side + "_primary"]}" fill="#fafafa"/>'
            f'<path data-reflection="{side}-secondary" d="{boo["refl_" + side + "_secondary"]}" fill="#b8baba"/>')
        out.append(
            f'    <g data-boo-eye-scale="{side}" transform="translate({x} {y}) scale({EYE_SCALE}) '
            f'translate({-x} {-y})">{inner}</g>')
    return "\n".join(out)


def character(boo, kit=MASTER_KIT):
    """Returns (markup, bbox). Layers: body, face, band, ear cups, mic boom, can + mitten grip."""
    band, mic_art, cups, pts = headset(boo, kit)
    pts = pts + polyline(boo["body_fill"]) + can_extent()
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    markup = f"""
  <g data-part="body">
    <path data-contour="body-fill" d="{boo["body_fill"]}" fill="{WHITE}"/>
    <path data-contour="body-outline" d="{boo["body_outline"]}" fill="{INK}" fill-rule="evenodd"/>
  </g>
  <g data-part="eyes" fill-rule="evenodd">
{eye_markup(boo)}
  </g>
  <path data-part="mouth" d="{boo["mouth"]}" fill="#060607" fill-rule="evenodd"/>{band}{mic_art}{cups}{can_markup(boo)}"""
    return markup, (min(xs), min(ys), max(xs), max(ys))


def square_box(bbox, pad):
    x0, y0, x1, y1 = bbox
    side = max(x1 - x0, y1 - y0) * (1 + 2 * pad)
    return ((x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2, side)


# ---- documents -------------------------------------------------------------
def gamer_boo_svg(boo):
    art, bbox = character(boo)
    x, y, side = square_box(bbox, 0.035)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x:.2f} {y:.2f} {side:.2f} {side:.2f}" role="img" aria-labelledby="gb-title gb-desc">
  <title id="gb-title">Gamer Boo — Naga Control mascot</title>
  <desc id="gb-desc">The locked white Boo ghost (body, eyes and smile unchanged from boo.svg at ghosts@{GHOSTS_COMMIT[:7]}) wearing a gaming headset fitted to its crown, with a boom mic, holding an unbranded energy-drink can. Generated by build_logo.py.</desc>{art}
</svg>
"""


def squircle(x, y, s, r):
    """Continuous-corner rounded square (the usual Apple corner constants)."""
    a, b, c, d_, e, f, g = 1.528665, 1.08849296, 0.86840694, 0.63149379, 0.07491139, 0.37282383, 0.16905956

    def corner(ox, oy, ux, uy, vx, vy):
        # (ox, oy) is the corner; u runs along the incoming edge, v along the outgoing one.
        def P(du, dv):
            return "%.2f %.2f" % (ox + ux * du * r + vx * dv * r, oy + uy * du * r + vy * dv * r)
        return (f"L{P(-a, 0)} C{P(-b, 0)} {P(-c, 0)} {P(-d_, e)} "
                f"C{P(-f, g)} {P(-g, f)} {P(-e, d_)} C{P(0, c)} {P(0, b)} {P(0, a)} ")

    d = "M%.2f %.2f " % (x + a * r, y)
    d += corner(x + s, y, 1, 0, 0, 1)
    d += corner(x + s, y + s, 0, 1, -1, 0)
    d += corner(x, y + s, -1, 0, 0, -1)
    d += corner(x, y, 0, -1, 1, 0)
    return d + "Z"


RIM_WIDTH = 5.0   # boo.svg units


def app_icon_svg(boo):
    """macOS icon grid: 1024 canvas, 824 tile, 185.4 corner radius. Boo's outline is
    near-black, so on the dark tile the mascot gets a thin light sticker rim; without
    it the headband and the can outline sink into the tile."""
    tile = squircle(100, 100, 824, 185.4)
    art, (x0, y0, x1, y1) = character(boo)
    scale = 650.0 / max(x1 - x0, y1 - y0)
    tx, ty = 512 - (x0 + x1) / 2 * scale, 512 - (y0 + y1) / 2 * scale
    sigma = RIM_WIDTH / 1.28   # the alpha threshold below (0.1) lands 1.28 sigma outside the art
    m = 4 * RIM_WIDTH
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Naga Control app icon: Gamer Boo">
  <defs>
    <linearGradient id="tile" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{TILE_TOP}"/><stop offset="1" stop-color="{TILE_BOTTOM}"/>
    </linearGradient>
    <radialGradient id="glow" cx="512" cy="450" r="400" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{GREEN}" stop-opacity=".46"/><stop offset=".55" stop-color="{GREEN}" stop-opacity=".13"/><stop offset="1" stop-color="{GREEN}" stop-opacity="0"/>
    </radialGradient>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10"/>
      <feComponentTransfer><feFuncA type="linear" slope=".3"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="rim" filterUnits="userSpaceOnUse" x="{x0 - m:.1f}" y="{y0 - m:.1f}" width="{x1 - x0 + 2 * m:.1f}" height="{y1 - y0 + 2 * m:.1f}" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="{sigma:.2f}"/>
      <feComponentTransfer result="grown"><feFuncA type="linear" slope="14" intercept="-0.9"/></feComponentTransfer>
      <feFlood flood-color="{RIM}"/><feComposite in2="grown" operator="in"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <clipPath id="tile-clip"><path d="{tile}"/></clipPath>
  </defs>
  <g filter="url(#drop)">
    <path d="{tile}" fill="url(#tile)"/>
    <g clip-path="url(#tile-clip)">
      <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
    </g>
    <path d="{squircle(103, 103, 818, 182.4)}" fill="none" stroke="#fff" stroke-opacity=".13" stroke-width="6"/>
  </g>
  <g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.4f})">
    <g data-part="gamer-boo" filter="url(#rim)">{art}
    </g>
  </g>
</svg>
"""


# ---- small app icons -------------------------------------------------------
# At 64 px and below the full mascot is a white blob with green flecks, so those
# sizes get their own drawing: the same upright, simplified Boo as the menu-bar glyph,
# in colour on the tile, with nothing but the head, eyes, headband and green cups.
# Units are pixels of the 16 px icon; the 32 px icon is the same drawing at 2x.
def small_tile():
    return f"""<defs><linearGradient id="tile" x1="0" y1="1" x2="0" y2="15" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{TILE_TOP}"/><stop offset="1" stop-color="{TILE_BOTTOM}"/></linearGradient></defs>
  <path d="{squircle(1, 1, 14, 3.15)}" fill="url(#tile)"/>
  <path d="{squircle(1.25, 1.25, 13.5, 2.9)}" fill="none" stroke="#fff" stroke-opacity=".16" stroke-width=".5"/>"""


def app_icon_32_svg():
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" role="img" aria-label="Naga Control app icon, 32 px">
  {small_tile()}
  <g transform="translate(0 .5)">{small_boo('<path data-part="mouth" d="M7 8.5 h.5 v.5 h1 v-.5 h.5 v.5 h-.5 v.5 h-1 v-.5 h-.5 Z" fill="' + INK + '" shape-rendering="crispEdges"/>')}
  </g>
</svg>
"""


def small_boo(mouth, extra=""):
    def bump(x_from, x_to):
        return f"C{x_from} 13.45 {x_to} 13.45 {x_to} 12"

    def notch(x_to):
        return f"V11.8 A.5 .5 0 0 0 {x_to} 11.8 V12"

    body = ("M4 8 A4 4 0 0 1 12 8 V12 " + bump(12, 10) + " " + notch(9) + " " + bump(9, 7) + " "
            + notch(6) + " " + bump(6, 4) + " Z")
    return f"""
    <path data-part="headset-band" d="M3 8.4 V8 A5 5.5 0 0 1 13 8 V8.4" fill="none" stroke="{SMALL_BAND}"/>
    <path data-part="ghost" d="{body}" fill="{WHITE}"/>
    <circle data-eye="left" cx="5.75" cy="7.25" r=".78" fill="{INK}"/>
    <circle data-eye="right" cx="10.25" cy="7.25" r=".78" fill="{INK}"/>
    {mouth}
    <rect data-part="headset-cup-left" x="2" y="6" width="2" height="4" rx=".8" fill="{GREEN}"/>
    <rect data-part="headset-cup-right" x="12" y="6" width="2" height="4" rx=".8" fill="{GREEN}"/>{extra}"""


def app_icon_64_svg():
    """The 64 px slot (32 pt on Retina) is shown physically small, and the full mascot's
    outline, mic and can break up there, so it gets the simplified Boo too: same tile
    proportion and glow as the big icon, a smooth smile and eye catchlights."""
    tile = squircle(1.5, 1.5, 13, 2.925)       # 824 / 1024 of the canvas, like app-icon.svg
    mouth = f'<path data-part="mouth" d="M7.1 8.55 Q8 9.65 8.9 8.55" fill="none" stroke="{INK}" stroke-width=".52" stroke-linecap="round"/>'
    glints = "".join(f'\n    <circle data-reflection="{side}" cx="{x - .27}" cy="6.95" r=".23" fill="#fafafa"/>'
                     for side, x in (("left", 5.75), ("right", 10.25)))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" role="img" aria-label="Naga Control app icon, 64 px">
  <defs>
    <linearGradient id="tile" x1="0" y1="1.5" x2="0" y2="14.5" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{TILE_TOP}"/><stop offset="1" stop-color="{TILE_BOTTOM}"/>
    </linearGradient>
    <radialGradient id="glow" cx="8" cy="7" r="6.2" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{GREEN}" stop-opacity=".46"/><stop offset=".55" stop-color="{GREEN}" stop-opacity=".13"/><stop offset="1" stop-color="{GREEN}" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="tile-clip"><path d="{tile}"/></clipPath>
  </defs>
  <path d="{tile}" fill="url(#tile)"/>
  <rect x="1.5" y="1.5" width="13" height="13" fill="url(#glow)" clip-path="url(#tile-clip)"/>
  <path d="{squircle(1.625, 1.625, 12.75, 2.8)}" fill="none" stroke="#fff" stroke-opacity=".13" stroke-width=".25"/>
  <g transform="translate(8 8) scale(.875) translate(-8 -7.6)">{small_boo(mouth, glints)}
  </g>
</svg>
"""


# The 16 px icon is set pixel by pixel on the tile: B band, W ghost, K eye, G cup.
ICON_16 = """
................
................
.....BBBBBB.....
...BB......BB...
...B..WWWW..B...
...B.WWWWWW.B...
..GGWWWWWWWWGG..
..GGWKKWWKKWGG..
..GGWKKWWKKWGG..
..GGWWWWWWWWGG..
....WWWWWWWW....
....WWWWWWWW....
....WWWWWWWW....
....WW.WW.WW....
................
................
"""


def pixel_cells(grid, size, fills):
    """Run-length rects for a character grid. Digits are black at that alpha in tenths."""
    rows = grid.split()
    assert len(rows) == size and all(len(r) == size and r == r[::-1] for r in rows), "grid must be square and symmetric"
    cells = []
    for y, row in enumerate(rows):
        x = 0
        while x < size:
            ch = row[x]
            run = 1
            while x + run < size and row[x + run] == ch:
                run += 1
            if ch != ".":
                paint = f'fill="#000" fill-opacity=".{ch}"' if ch.isdigit() else f'fill="{fills[ch]}"'
                cells.append(f'<rect x="{x}" y="{y}" width="{run}" height="1" {paint}/>')
            x += run
    return "\n    ".join(cells)


def app_icon_16_svg():
    cells = pixel_cells(ICON_16, 16, {"B": SMALL_BAND, "W": WHITE, "K": INK, "G": GREEN})
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" role="img" aria-label="Naga Control app icon, 16 px">
  {small_tile()}
  <g shape-rendering="crispEdges">
    {cells}
  </g>
</svg>
"""


# ---- menu-bar glyph --------------------------------------------------------
# Boo's real contour (tilted, with arms) turns to grey mush at 18 px, so the glyph is
# drawn for the pixel grid instead: an upright Boo with the same proportions (round
# crown, eyes a third of the way down, three hem scallops), a solid body with the eyes
# knocked out, and the headset as a band with a clear gap above the crown plus two cups.
# Solid means macOS shows it as a white ghost with dark eyes on a dark menu bar.
# Units are points on an 18 x 18 canvas; edges sit on half points, so @2x is crisp.
def menu_bar_svg():
    """Template glyph for @2x and up: opaque black on transparent; macOS supplies the tint."""
    def bump(x_from, x_to):   # one hem scallop, drawn right to left along y = 15.4
        return f"C{x_from} 17.55 {x_to} 17.55 {x_to} 15.4"

    def notch(x_to):          # the slot between two scallops
        return f"V15.1 A.5 .5 0 0 0 {x_to} 15.1 V15.4"

    # Sides drop straight from the crown, then flare half a point into the hem.
    body = ("M3.5 15.4 C3.5 14 4 13.4 4 12 V8.5 A5 5 0 0 1 14 8.5 V12 C14 13.4 14.5 14 14.5 15.4 "
            + bump(14.5, 11.5) + " " + notch(10.5) + " " + bump(10.5, 7.5) + " " + notch(6.5) + " "
            + bump(6.5, 3.5) + " Z")
    eyes = " ".join(f"M{x - 1.1} 8 a1.1 1.1 0 1 0 2.2 0 a1.1 1.1 0 1 0 -2.2 0 Z" for x in (7, 11))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" role="img" aria-label="Naga Control menu-bar glyph">
  <path data-part="ghost" fill-rule="evenodd" d="{body} {eyes}"/>
  <path data-part="headset-band" d="M2.25 8.4 V8 A6.75 6.75 0 0 1 15.75 8 V8.4" fill="none" stroke="#000" stroke-width="1.5"/>
  <rect data-part="headset-cup-left" x=".5" y="5" width="2.5" height="6" rx="1.1"/>
  <rect data-part="headset-cup-right" x="15" y="5" width="2.5" height="6" rx="1.1"/>
</svg>
"""


# The @1x glyph is the same drawing set pixel by pixel, with no grey pixels at all,
# because 18 px leaves no room for anti-aliased curves.
GLYPH_1X = """
..................
......######......
....##......##....
...#...####...#...
..#..########..#..
..#.##########.#..
.##.##########.##.
.##.##..##..##.##.
.##.##..##..##.##.
.##.##########.##.
..#.##########.#..
....##########....
....##########....
....##########....
....##########....
....###.##.###....
....###.##.###....
..................
"""


def menu_bar_1x_svg():
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" shape-rendering="crispEdges" '
            'role="img" aria-label="Naga Control menu-bar glyph, 18 px">\n    '
            + pixel_cells(GLYPH_1X, 18, {"#": "#000"}) + "\n</svg>\n")


def write(name, text):
    with open(os.path.join(HERE, name), "w") as f:
        f.write(text)


# ---- rasterising -----------------------------------------------------------
def shoot(html, png_path, w, h):
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "page.html")
        with open(page, "w") as f:
            f.write(html)
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--user-data-dir=" + os.path.join(tmp, "profile"), "--screenshot=" + png_path,
             f"--window-size={w},{h}", "--force-device-scale-factor=1",
             "--default-background-color=00000000", "file://" + page],
            check=True, capture_output=True)


def page_height(html, w):
    """Lay the page out in Chrome and return its full height in px."""
    probe = html.replace("</body>", "<script>document.title = document.documentElement.scrollHeight</script></body>")
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "page.html")
        with open(page, "w") as f:
            f.write(probe)
        dom = subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--user-data-dir=" + os.path.join(tmp, "profile"),
             f"--window-size={w},800", "--dump-dom", "file://" + page],
            check=True, capture_output=True, text=True).stdout
    return int(re.search(r"<title>(\d+)</title>", dom).group(1))


def render(svg_name, png_path, size):
    src = "file://" + os.path.join(HERE, svg_name)
    shoot(f'<html><body style="margin:0;background:transparent"><img src="{src}" '
          f'style="display:block;width:{size}px;height:{size}px"></body></html>', png_path, size, size)


ICONSET = [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
           ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
           ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
           ("icon_512x512@2x.png", 1024)]
SOURCES = {16: "app-icon-16.svg", 32: "app-icon-32.svg", 64: "app-icon-64.svg"}   # larger sizes use app-icon.svg


def build_iconset():
    iconset = os.path.join(HERE, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    done = {}
    for name, px in ICONSET:
        out = os.path.join(iconset, name)
        if px in done:
            shutil.copyfile(done[px], out)
        else:
            render(SOURCES.get(px, "app-icon.svg"), out, px)
            done[px] = out
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, "AppIcon.icns")], check=True)


def build_preview():
    def u(name):
        return "file://" + os.path.join(HERE, name)

    icons = (("icon_128x128.png", 128), ("icon_32x32@2x.png", 64), ("icon_32x32.png", 32), ("icon_16x16.png", 16))

    def sizes(extra=""):
        cells = "".join(f'<div><img src="{u("AppIcon.iconset/" + n)}" width="{px}" height="{px}">{px} px</div>'
                        for n, px in icons)
        return f'<div class="sizes">{cells}{extra}</div>'

    zooms = (f'<div style="margin-left:36px"><img class="px" src="{u("AppIcon.iconset/icon_32x32.png")}" width="192" height="192">32 px, enlarged 6×</div>'
             f'<div><img class="px" src="{u("AppIcon.iconset/icon_16x16.png")}" width="192" height="192">16 px, enlarged 12×</div>')

    def bar(theme):
        dark = theme == "dark"
        bg = "#1d1e22" if dark else "#e9e9ec"
        fg = "#f2f2f2" if dark else "#1c1c1e"
        inv = "filter:invert(1);" if dark else ""
        one, two = u("MenuBarIcon.png"), u("MenuBarIcon@2x.png")
        return f"""
      <div class="bar" style="background:{bg};color:{fg}">
        <div><div class="strip"><span>Wi-Fi</span><img src="{one}" width="18" height="18" style="{inv}"><span>Tue 6:42 PM</span></div>in a menu bar, 18 px file</div>
        <div><div class="strip"><img src="{two}" width="36" height="36" style="{inv}"></div>36 px file (Retina)</div>
        <div><img class="px" src="{one}" width="126" height="126" style="{inv}">18 px, enlarged 7×</div>
        <div><img class="px" src="{two}" width="126" height="126" style="{inv}">36 px, enlarged 3.5×</div>
      </div>"""

    html = f"""<html><head><style>
      body {{ margin:0; width:1800px; background:#f4f4f6; color:#222;
             font:15px -apple-system, 'Helvetica Neue', sans-serif; }}
      h1 {{ font-size:30px; margin:0; }} h2 {{ font-size:13px; letter-spacing:.09em; text-transform:uppercase;
             color:#777; margin:0 0 16px; font-weight:600; }}
      .wrap {{ padding:40px 44px; }} .row {{ display:flex; gap:28px; align-items:stretch; }}
      .col {{ display:flex; flex-direction:column; gap:28px; flex:1; }}
      .card {{ background:#fff; border:1px solid #e2e2e6; border-radius:18px; padding:24px; box-sizing:border-box; }}
      .grow {{ flex:1; display:flex; flex-direction:column; }} .grow > :last-child {{ flex:1; }}
      .dark {{ background:#17181b; border-color:#17181b; }} .dark h2 {{ color:#9a9aa2; }}
      .sizes {{ display:flex; gap:40px; align-items:flex-end; justify-content:center; }}
      .sizes div {{ text-align:center; font-size:12px; color:#777; }} .sizes img {{ display:block; margin:0 auto 8px; }}
      .px {{ image-rendering:pixelated; }}
      .wall {{ background:linear-gradient(135deg,#2b5d8a,#7a4fa0 55%,#d9796a); border-radius:12px; padding:0 40px;
               display:flex; align-items:center; }}
      .wall .sizes {{ margin:0 auto; gap:72px; }} .wall .sizes div {{ color:#fff; opacity:.9; }}
      .bar {{ display:flex; align-items:flex-end; justify-content:space-around; gap:44px; padding:20px 28px 16px; border-radius:12px; flex:1; }}
      .bar > div {{ text-align:center; font-size:11.5px; opacity:.6; }}
      .bar img {{ display:block; margin:0 auto 8px; }}
      .strip {{ display:flex; align-items:center; gap:14px; font-size:13.5px; font-weight:500; margin-bottom:8px; height:36px; }}
      .strip img {{ margin:0; }}
      .bars {{ display:flex; flex-direction:column; gap:14px; }}
      .char {{ width:340px; height:340px; display:block; }}
    </style></head><body><div class="wrap">
      <h1>Naga Control — Gamer Boo</h1>
      <p style="color:#666;margin:6px 0 26px">App icon, menu-bar template glyph and master character. Every image here is rendered by build_logo.py from the SVGs in this folder.</p>
      <div class="row">
        <div class="card"><h2>App icon · 1024 px artwork</h2><img src="{u('AppIcon.iconset/icon_512x512@2x.png')}" style="width:520px;height:520px;display:block"></div>
        <div class="col">
          <div class="card"><h2>App icon sizes (64 px and below use a simplified Boo)</h2>{sizes(zooms)}</div>
          <div class="card grow"><h2>On a coloured backdrop</h2><div class="wall">{sizes()}</div></div>
        </div>
      </div>
      <div class="row" style="margin-top:28px">
        <div class="card grow" style="flex:1"><h2>Menu-bar glyph · template image (black + alpha; macOS tints it)</h2>
          <div class="bars">{bar('light')}{bar('dark')}</div>
        </div>
        <div class="card"><h2>Master character</h2><img class="char" src="{u('gamer-boo.svg')}"></div>
        <div class="card dark"><h2>Master character on dark</h2><img class="char" src="{u('gamer-boo.svg')}"></div>
      </div>
    </div></body></html>"""
    shoot(html, os.path.join(HERE, "preview.png"), 1800, page_height(html, 1800))


def main():
    boo = load_boo()
    write("gamer-boo.svg", gamer_boo_svg(boo))
    write("app-icon.svg", app_icon_svg(boo))
    write("app-icon-64.svg", app_icon_64_svg())
    write("app-icon-32.svg", app_icon_32_svg())
    write("app-icon-16.svg", app_icon_16_svg())
    write("menu-bar-glyph.svg", menu_bar_svg())
    write("menu-bar-glyph-1x.svg", menu_bar_1x_svg())
    if "--svg-only" in sys.argv:
        return
    build_iconset()
    render("menu-bar-glyph-1x.svg", os.path.join(HERE, "MenuBarIcon.png"), 18)
    render("menu-bar-glyph.svg", os.path.join(HERE, "MenuBarIcon@2x.png"), 36)
    build_preview()
    print("built:", ", ".join(sorted(os.listdir(HERE))))


if __name__ == "__main__":
    main()
