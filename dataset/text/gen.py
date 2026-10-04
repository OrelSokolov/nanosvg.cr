#!/usr/bin/env python3
"""Text rendering dataset: 100 SVGs with <text>, reference PNGs from
librsvg (the same renderer stack Pango apps use).

The references are rendered with hinting disabled (a local fontconfig
that assigns hintstyle=hintnone), so both renderers rasterize raw
glyph outlines at linear size — the only fair comparison for an
outline-based rasterizer like NanoSVG.

Layout:
  cases/NNN.svg      the test SVGs (480x200 unless noted)
  reference/NNN.png  librsvg rasterization at 1:1
  manifest.tsv       name <tab> width <tab> height

Run:  python3 gen.py [outdir]
"""

import os
import sys

# Must be set before fontconfig initializes (i.e. before gi imports
# Pango/Cairo through librsvg).
HERE = os.path.dirname(os.path.abspath(__file__))
FC_CONF = os.path.join(HERE, "nohint.conf")
os.environ["FONTCONFIG_FILE"] = FC_CONF

import gi  # noqa: E402

gi.require_version("Rsvg", "2.0")
gi.require_version("PangoCairo", "1.0")
gi.require_version("Pango", "1.0")
import cairo  # noqa: E402  (pycairo; contexts interop with PyGObject)
from gi.repository import Rsvg, GLib  # noqa: E402

W, H = 480, 200

# Static instances only: variable fonts (Ubuntu ships as
# Ubuntu[wdth,wght].ttf) would need gvar instancing, which the
# TrueType reader does not do.
FAMILIES = [
    "Liberation Sans",
    "Liberation Serif",
    "Liberation Mono",
    "DejaVu Sans",
    "DejaVu Serif",
    "Lato",
]

# No "fi/fl/ff/ffi/ffl" sequences anywhere (DejaVu ligates them; our
# engine does not substitute glyphs).
TEXTS = [
    "Sphinx of black quartz, judge my vow",
    "AVATAR WAVY ToToro",
    "Jackdaws love my big sphinx o1 quartz",
    "0123456789 +-* (25.04)",
    "WAVE, Avenue & Torque!",
    "mixed CASE Text 42%",
]


def esc(s: str) -> str:
    # The Crystal scanner does not decode XML entities; keep the corpus
    # free of &<> characters.
    return s.replace("&", " and ")


def case_svg(body: str, w: int = W, h: int = H) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}">\n{body}\n</svg>\n'
    )


def text_el(x, y, s, family, size, fill="#000000", weight=None, style=None,
            anchor=None, baseline=None, spacing=None, transform=None, extra=""):
    attrs = f'x="{x}" y="{y}" font-family="{family}" font-size="{size}" fill="{fill}"'
    if weight:
        attrs += f' font-weight="{weight}"'
    if style:
        attrs += f' font-style="{style}"'
    if anchor:
        attrs += f' text-anchor="{anchor}"'
    if baseline:
        attrs += f' dominant-baseline="{baseline}"'
    if spacing is not None:
        attrs += f' letter-spacing="{spacing}"'
    if transform:
        attrs += f' transform="{transform}"'
    return f"<text {attrs}{extra}>{esc(s)}</text>"


def slug(fam):
    return fam.lower().replace(" ", "_")


def cases():
    out = []

    # 1) 30 basic: family x size x text.
    for i, size in enumerate([12, 16, 20, 24, 32, 48, 64, 96]):
        for j, fam in enumerate(FAMILIES[:4] if i % 2 else FAMILIES[2:]):
            out.append((
                f"basic_{slug(fam)}_{size}",
                text_el(20, 100 + size // 3, TEXTS[(i + j) % len(TEXTS)], fam, size),
            ))
    out = out[:30]

    # 2) 12 bold/italic.
    for i, fam in enumerate(FAMILIES):
        out.append((f"bold_{i}", text_el(20, 80, "Bold AV Wave", fam, 28, weight="bold")))
        out.append((f"italic_{i}", text_el(20, 80, "Italic AV Wave", fam, 28, style="italic")))
    out = out[:30 + 12]

    # 3) 12 text-anchor.
    for i, anchor in enumerate(["start", "middle", "end"]):
        for j, size in enumerate([16, 32, 64, 96]):
            out.append((
                f"anchor_{anchor}_{size}",
                text_el(240, 60 + j * 40, "Anchor AV", "Liberation Sans", size,
                        anchor=anchor, fill="#1a6ac4"),
            ))

    # 4) 9 dominant-baseline.
    for i, base in enumerate(["alphabetic", "central", "middle"]):
        for j, fam in enumerate(["Liberation Sans", "DejaVu Serif", "Liberation Mono"]):
            body = (
                text_el(20, 100, "Baseline " + base, fam, 32, baseline=base)
                + f'<line x1="10" y1="100" x2="470" y2="100" stroke="#cccccc"/>'
            )
            out.append((f"baseline_{base}_{j}", body))

    # 5) 8 letter-spacing.
    for i, sp in enumerate([1, 2, 4, 8]):
        out.append((f"spacing_sans_{sp}", text_el(20, 100, "SPACED AV Wave", "Liberation Sans", 28, spacing=sp)))
        out.append((f"spacing_serif_{sp}", text_el(20, 100, "SPACED AV Wave", "DejaVu Serif", 28, spacing=sp)))

    # 6) 8 kerning-heavy.
    for i, s in enumerate(["AVAVA", "ToToTo", "WAVEWAY", "yVvVyV"]):
        out.append((f"kern_plain_{i}", text_el(20, 100, s, "Liberation Sans", 48)))
        out.append((f"kern_mixed_{i}", text_el(20, 100, s, "Liberation Serif", 48)))

    # 7) 6 transforms on the text element.
    for i, tr in enumerate(["rotate(-8 240 100)", "rotate(15 240 100)",
                            "translate(40 -20) scale(1.5)", "scale(1 2)",
                            "skewX(-12)", "matrix(0.9 0.2 -0.3 1.05 30 10)"]):
        out.append((f"xform_{i}", text_el(20, 100, "Rotated AV Text", "Liberation Sans", 32, transform=tr)))

    # 8) 4 gradient fills.
    for i, fam in enumerate(FAMILIES[:4]):
        body = (
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">'
            '<stop offset="0" stop-color="#1668c4"/><stop offset="1" stop-color="#c41668"/>'
            "</linearGradient></defs>"
            + text_el(20, 100, "Gradient AV Wave", fam, 36, fill="url(#g)")
        )
        out.append((f"gradient_{i}", body))

    # 9) 4 opacity.
    for i, op in enumerate([0.25, 0.5, 0.75, 1]):
        out.append((f"opacity_{op}",
                    f'<text x="20" y="100" font-family="Liberation Sans" font-size="36" '
                    f'fill="#000000" opacity="{op}">Ghost AV Wave</text>'))

    # 10) 4 tspan variations (no boundary whitespace).
    out.append(("tspan_size",
                '<text x="20" y="100" font-family="Liberation Sans" font-size="28" fill="#000000">'
                "Mixed<tspan font-size=\"44\">Big</tspan><tspan font-size=\"18\">tiny</tspan>End</text>"))
    out.append(("tspan_dy",
                '<text x="20" y="100" font-family="DejaVu Serif" font-size="28" fill="#000000">'
                "Up<tspan dy=\"-20\">High</tspan><tspan dy=\"40\">Low</tspan>Flat</text>"))
    out.append(("tspan_color",
                '<text x="20" y="100" font-family="Liberation Mono" font-size="28">'
                '<tspan fill="#c41668">Red</tspan><tspan fill="#1668c4">Blue</tspan></text>'))
    out.append(("tspan_bold",
                '<text x="20" y="100" font-family="Liberation Sans" font-size="28">'
                "Plain<tspan font-weight=\"bold\">Bold</tspan>Plain</text>"))

    # 11) 5 multi-element compositions.
    for i, fam in enumerate(FAMILIES[:5]):
        body = "\n".join([
            text_el(20, 50, TEXTS[i % len(TEXTS)][:24], fam, 20),
            text_el(20, 100, "Second line AV", fam, 28, anchor="middle", fill="#1a6ac4"),
            text_el(460, 160, "end 96px", fam, 24, anchor="end"),
        ])
        out.append((f"multi_{i}", body))

    return out


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else HERE
    cases_dir = os.path.join(out_dir, "cases")
    ref_dir = os.path.join(out_dir, "reference")
    os.makedirs(cases_dir, exist_ok=True)
    os.makedirs(ref_dir, exist_ok=True)

    # Exactly 100 cases: dedupe by name, deterministic trim.
    seen, unique = set(), []
    for name, svg in cases():
        if name not in seen:
            seen.add(name)
            unique.append((name, svg))
    unique = unique[:100]

    manifest = []
    for name, svg in unique:
        with open(os.path.join(cases_dir, name + ".svg"), "w") as f:
            f.write(case_svg(svg))

        handle = Rsvg.Handle.new_from_data(case_svg(svg).encode())
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
        ctx = cairo.Context(surface)
        vp = Rsvg.Rectangle()
        vp.x, vp.y, vp.width, vp.height = 0.0, 0.0, float(W), float(H)
        ok = handle.render_document(ctx, vp)
        if not ok:
            raise SystemExit(f"render failed: {name}")
        surface.write_to_png(os.path.join(ref_dir, name + ".png"))
        manifest.append(f"{name}\t{W}\t{H}")

    with open(os.path.join(out_dir, "manifest.tsv"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    print(f"{len(manifest)} cases generated in {out_dir}")


if __name__ == "__main__":
    main()
