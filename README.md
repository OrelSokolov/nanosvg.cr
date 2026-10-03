# nanosvg.cr

Pure Crystal SVG parser and rasterizer, based on
[NanoSVG](https://github.com/memononen/nanosvg) by Mikko Mononen
(zlib license).

Parses SVG files into a list of cubic bezier shapes and rasterizes them to
an RGBA buffer. It started as a faithful port of the C library — on the
test artwork it produces byte-identical output — and has since been
extended beyond the C original: `<use>` with `<defs>` path templates,
nested `<svg>` viewports, and MathJax-compatible rendering (see
"Differences from C").

## Installation

1. Add the dependency to your `shard.yml`:

```yaml
dependencies:
  nanosvg:
    github: OrelSokolov/nanosvg.cr
```

2. Run `shards install`

## Usage

```crystal
require "nanosvg"

# Parse (units: "px", "pt", "pc", "mm", "cm", "in"; DPI controls conversion)
image = NanoSVG.parse_from_file("test.svg", "px", 96.0f32)
puts "size: #{image.width} x #{image.height} (#{image.shapes.size} shapes)"

# Walk the shapes: each path is a flat Float32 array of
# x0,y0, cpx1,cpx1,cpx2,cpy2,x1,y1, ... (npts-1 divisible by 3)
image.shapes.each do |shape|
  shape.paths.each do |path|
    i = 0
    while i < path.npts - 1
      p = i*2
      draw_cubic_bez(path.pts[p], path.pts[p+1], path.pts[p+2], path.pts[p+3],
                     path.pts[p+4], path.pts[p+5], path.pts[p+6], path.pts[p+7])
      i += 3
    end
  end
end

# Rasterize to a non-premultiplied RGBA buffer
scale = 2.0f32
w = (image.width * scale).round.to_i32
h = (image.height * scale).round.to_i32
pixels = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, scale, w, h)
```

A persistent `NanoSVG::Rasterizer` instance can be reused for multiple
images. See `examples/render.cr` for a complete parse → rasterize → PNG
pipeline (built on the stdlib, no external shards):

```sh
crystal run examples/render.cr -- example_data/drawing.svg out.png 512
```

## Supported SVG features

- Elements: `svg` (root and nested — a nested `<svg>` acts as a viewport
  transform, used by MathJax for stretchy delimiters), `g`, `path`, `rect`,
  `circle`, `ellipse`, `line`, `polyline`, `polygon`, `defs`,
  `linearGradient`, `radialGradient`, `stop`, `style` (simple `.class`
  selectors), `use` (references a `<path id>` from `defs` via `href` /
  `xlink:href`, with `x`/`y` and `transform`; forward references are
  resolved after parsing — this is what MathJax SVG output is built on)
- Path commands: all of `MmLlHhVvCcSsQqTtAaZz` (arcs are converted to
  cubic beziers)
- Styles: presentation attributes, inline `style="..."`, CSS classes,
  `display:none`
- Paint: solid colors (`#rgb`, `#rrggbb`, `rgb()`, 147 named colors),
  linear/radial gradients (objectBoundingBox/userSpaceOnUse,
  gradientTransform, stops, `xlink:href` stop inheritance)
- Stroke: width, opacity, caps (butt/round/square), joins
  (miter/round/bevel), miter-limit, dashes + offset, `paint-order`
- `transform` (matrix/translate/scale/rotate/skewX/skewY) with nesting
- `viewBox`, `preserveAspectRatio`, units (`px pt pc mm cm in em ex %`), DPI
- Fill rules: nonzero and evenodd; anti-aliased scanline rasterization
  (5 sub-scanlines, 1/1024 fixed-point)

Not supported (same as the C original): text, `use` referencing
non-`path` elements, `symbol`, clip paths,
masks, filters, patterns, markers, CSS cascade beyond simple classes.

Known limitations of the `<use>`/nested-`<svg>` support:

- A `transform` attribute on the `<path>` template inside `defs` is
  ignored when the template is instantiated by `<use>` (MathJax output
  does not use it).
- `<use>` with a forward reference (the `defs` entry appears after the
  `<use>` in the document) is resolved after parsing and appended to the
  end of the shape list, so it paints on top rather than in document
  order. Invisible with opaque glyphs; may matter for overlapping
  semi-transparent shapes.
- A nested `<svg>` with a `viewBox` but no `width`/`height` falls back
  to scale 1 instead of the spec default (100% of the parent viewport),
  and the implicit clipping of nested viewports is not applied.

## Differences from C

- Extended beyond the C original: `<use href="#id">` referencing a
  `<path id>` from `<defs>` (with `x`/`y`, `transform`, and forward
  references), and nested `<svg>` elements treated as viewport
  transforms — this is what MathJax SVG output is built on.
- Colors use the same bit layout as C: `0xAABBGGRR` (R in the low byte).
- The `NOTE(port)` comments in the sources mark deliberate deviations
  (mostly: C read uninitialized memory in degenerate cases; the port uses
  deterministic values).
- The C memory pool/freelist in the rasterizer is left to the GC.
- The full `NANOSVG_ALL_COLOR_KEYWORDS` list is always enabled.

## Development

```sh
crystal spec                        # run the test suite
crystal run examples/render.cr -- example_data/23.svg out.png 512
```

## License

zlib — same as the original NanoSVG (see `LICENSE`).
The polygon rasterization is based on the stb_truetype rasterizer by
Sean Barrett.
