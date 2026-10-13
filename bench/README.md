# Benchmarks: C NanoSVG vs Crystal port

Symmetric benchmarks measuring parse and rasterize separately:

- `bench_c.c` — upstream C (`~/nanosvg/src`), `gcc -O2`
- `bench_cr.cr` — this port, `crystal build --release`

Both reuse the rasterizer across iterations (like `example2.c`), rasterize
at icon widths 128/512/1024, and report avg/min over 50 parse / 20 raster
iterations. `min` filters out GC/scheduler noise. Pin to a P-core for
comparable numbers (`taskset -c 0 ...`); this laptop (Core Ultra 7 155H)
still shows ±20% run-to-run from thermal throttling.

## Run

```sh
gcc -O2 -o bench/build/bench_c bench/bench_c.c -lm
crystal build --release -o bench/build/bench_cr bench/bench_cr.cr
taskset -c 0 ./bench/build/bench_c  example_data/nano.svg example_data/drawing.svg example_data/23.svg
taskset -c 0 ./bench/build/bench_cr example_data/nano.svg example_data/drawing.svg example_data/23.svg
```

`verify.cr` hashes the rasterizer output at the same three sizes — use it
to check that optimizations do not change the rendered pixels:

```sh
crystal build --release -o bench/build/verify bench/verify.cr
./bench/build/verify example_data/*.svg
```

## Corpus tools (MathJax validation)

- `mathjax_corpus.cr` — checks parser output against the mathjax.cr
  golden dataset (MathJax v3 SVG output): every file must yield exactly
  count(`<use>`) + count(`<rect>`) visible shapes.
- `render_corpus.cr` — batch-renders a directory of SVGs to PNGs
  (currentColor resolved to black), mirroring the rsvg-convert oracle.
- `render_matching.cr` — renders SVGs at exact pixel sizes from a
  `name<TAB>w<TAB>h` manifest, for pixel-diffing against a reference
  dataset rasterized by another renderer.

## Text pixel-diff (librsvg oracle)

`dataset/text/` — 100 `<text>` SVGs (families, sizes, weights, italic,
anchors, dominant-baselines, letter-spacing, transforms, gradients,
tspans) with reference PNGs rasterized by librsvg with hinting forced
off (`nohint.conf`), so both renderers rasterize raw glyph outlines.

```sh
python3 dataset/text/gen.py                       # regenerate cases + refs
crystal run bench/text_pixel_diff.cr              # full report + worst-case images
crystal run bench/text_profile.cr -- case_name    # column spans ours vs ref
crystal run bench/font_smoke.cr                   # TTF reader sanity
```

Result (mean |Δα|, alpha = glyph coverage): corpus average **0.15**,
plain-text cases 0.26–0.35, worst 1.72 (`dominant-baseline="middle"`,
a ~1px rsvg/Pango metric difference); |Δα|>16 share 0.33% average —
the antialiasing floor between the NanoSVG scanline rasterizer and
Cairo/FreeType coverage. Not byte-identical by construction: two
different AA algorithms produce different edge coverage even for
identical geometry; geometry (glyph positions, advances, kerning)
matches HarfBuzz exactly.

## Before optimization (rasterize, min, ms — C / Crystal)

| file        | w=128        | w=512          | w=1024           |
|-------------|--------------|----------------|------------------|
| nano.svg    | 0.197 / 0.396 | 1.20 / 1.81   | 4.35 / 6.99      |
| drawing.svg | 0.305 / 0.325 | 2.84 / 3.73   | 10.36 / 14.37    |
| 23.svg      | 4.43 / 14.95  | 11.50 / 54.74 | 29.18 / 193.67   |

The gap grew with edge count: up to **6.6x** on 23.svg @1024.

## After optimization (same machine; numbers are noisy, ±20%)

Rasterize (min, ms — C / Crystal):

| file        | w=128         | w=512          | w=1024           |
|-------------|---------------|----------------|------------------|
| nano.svg    | 0.22 / 0.11   | 1.46 / 1.08    | 3.82 / 4.35      |
| drawing.svg | 0.24 / 0.26   | 1.97 / 1.72    | 8.11 / 6.08      |
| 23.svg      | 6.82 / 5.06   | 17.51 / 12.13  | 33.58 / 29.10    |

I.e. roughly **parity** — sometimes faster, sometimes ~15% slower
(23.svg @128 remains the weakest case). Rendered output is byte-identical
to the pre-optimization version (checked with `verify.cr` on all three
files at all three sizes) and the spec suite passes.

Parse remains ~1.5–2x slower than C (1.6ms vs ~1.0ms on 23.svg, tens of
microseconds elsewhere); the parser was not the target here.

## Stage-1 round (rasterizer-10x plan, 2026-10-13)

Interleaved base/opt/C runs (3 rounds each, min; see the ledger in
`plans/rasterizer-10x.md` for methodology and the full story):

Rasterize (min, ms — base / opt / C):

| file        | w=128                | w=512                 | w=1024                  |
|-------------|----------------------|-----------------------|-------------------------|
| nano.svg    | 0.113 / 0.100 / 0.082 | 0.874 / 0.716 / 0.623 | 3.24 / 2.74 / 2.30      |
| drawing.svg | 0.161 / 0.146 / 0.120 | 1.381 / 1.239 / 1.026 | 4.55 / 4.46 / 3.77      |
| 23.svg      | 5.09 / 5.49 / 4.22   | 11.51 / 11.67 / 10.25 | 26.02 / 26.34 / 24.76   |

Changes: gradient-loop invariant hoisting (xform/ color-table fetches out
of the per-pixel loop), a grow-only pooled buffer behind the one-shot
`Rasterizer.rasterize`, and an incremental pointer walk in
`unpremultiply_alpha`. Output byte-identical (pixel-level A/B diff against
the pre-change source on all files/sizes, plus `verify.cr` hashes). A
UInt64 SWAR blend was tried, proven bit-identical, but ~10–15% slower than
the byte loop LLVM already vectorizes — reverted. Note: `Bytes.new(n)`
does NOT guarantee zeroed memory; the rasterize clear is load-bearing.

## What was changed in the rasterizer (`src/nanosvg/rasterizer.cr`)

1. **Active-edge list → flat pool.** The linked list of heap-allocated
   `ActiveEdge` objects (nilable `next`, `not_nil!` on every hop) became
   parallel primitive arrays (`@ae_x/@ae_dx/@ae_ey/@ae_dir/@ae_next`)
   with integer `next` links, bump-allocated per pass — mirrors the C
   memory pool without GC allocations or nil checks. This was ~84% of
   rasterize time before.
2. **Edge storage → structure-of-arrays.** `Edge` heap classes became
   `@e_x0/@e_y0/@e_x1/@e_y1/@e_dir` Float32/Int32 arrays plus an
   `@ord` permutation sorted by y0 (replacing the `sort!` with a Proc
   comparator over objects).
3. **Raw pointers in hot loops.** `fill_scanline`, `fill_active_edges`,
   `scanline_solid` and `unpremultiply_alpha` operate on
   `Pointer(UInt8)`/`Pointer(Int32)` instead of bounds-checked `Array`
   indexing; the scanline is a `Bytes` cleared with `Pointer#clear`
   (memset).
4. `flatten_shape` walks `path.pts` and `@points` via raw pointers.
5. **RPoint is a value struct** stored inline in `Array(RPoint)` (flat
   C-like array, no per-point GC allocation). Stroke outline accumulators
   (`left`/`right` in C) became four Float32 values passed to and returned
   from the cap/join helpers as tuples; `prepare_stroke` mutates points
   through a raw pointer — with structs, `pts[i].field = v` would silently
   mutate a temporary copy (Crystal semantics, verified by test).

## Remaining known costs

- `flatten_cubic_bez` + stroke flattening ≈ 20% of rasterize time on
  23.svg; at w=128 (flatten-dominated) Crystal is still ~12% behind C,
  at w≥512 it is at parity or faster.
- The parser (string handling, `String::Builder`) is ~1.5–2x off C.

## Where the original gap came from

`perf` showed both versions spending most time in the same function
(`nsvg__rasterizeSortedEdges` / `rasterize_sorted_edges`) with GC under
1% — the cost was per-iteration overhead (nil checks, property accessors
on heap nodes, bounds-checked array writes), not the algorithm or GC.
