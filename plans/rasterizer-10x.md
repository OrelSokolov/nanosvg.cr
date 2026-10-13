# Rasterizer ×10 plan

Goal: cut large-bake rasterize time ~10× (e.g. the 2048×2048 icon bake
egui-cr's zoom canvas does) while keeping pixel output **unchanged**
unless a stage explicitly says otherwise. Parser is out of scope.

Context: egui-cr now pre-warms its raster buckets at startup
(`examples/multitouch_demo.cr`), so bakes are off the gesture path —
this plan is about startup latency and heavy artwork, not frame drops.
The C twin stays the reference: the port must stay within reach of
`bench_c` numbers before threads are considered.

## Stage 0 — baseline and guardrails (do first)

```sh
gcc -O2 -o bench/build/bench_c bench/bench_c.c -lm
crystal build --release -o bench/build/bench_cr bench/bench_cr.cr
./bench/build/bench_c  example_data/nano.svg example_data/drawing.svg example_data/23.svg
./bench/build/bench_cr example_data/nano.svg example_data/drawing.svg example_data/23.svg
# pixel-identity gate — must stay green after every stage:
crystal build --release -o bench/build/verify bench/verify.cr
./bench/build/verify example_data/*.svg
```

Record `rast min/avg` at 128/512/1024 for both builds in this file as
they land. Note: `taskset -c 0` is Linux; on macOS pin nothing, run
each bench 3× and take the min.

## Stage 1 — single-thread low-hanging fruit (est. 2.5–4×)

All in `src/nanosvg/rasterizer.cr`, pixel-identical, no contract change.

1a. **Incremental gradient stepping** (`scanline_solid`, the linear
    and radial branches, ~line 959). The per-pixel loop recomputes
    `gy = fx*t[1] + fy*t[3] + t[5]` in floats (and the radial branch
    its squares/sqrt). The gradient argument changes by a constant
    delta per pixel along the scanline: compute a fixed-point start
    and step once per line (this is what C nanosvgrast does), then
    walk an integer. Kills a float mul-add chain + the
    `clampf(...).to_i32` per pixel. Expected 1.5–2× on
    gradient-heavy art (the multitouch demo artwork is all gradients).

1b. **Make the solid blend loop auto-vectorizable.** `scanline_solid`'s
    color? branch blends per pixel with byte loads/stores and
    `div255`. Split coverage accumulation (fill_scanline) from
    painting (it already is), then paint spans in a branch-free pass:
    read 4 pixels as UInt32, blend with UInt32 SWAR
    (`((x*255+127)/255` patterns or the existing div255 identity
    `(x+1)*257>>16` in UInt32 lanes), unrolled ×4. LLVM then
    vectorizes it. Verify with `otool -tvV` / llvm-mca that the loop
    is SIMD; if not, hand-unroll to 8. Expected 2–3× on fill-heavy
    scenes.

1c. **Kill the double clear and the per-bake 16 MB alloc.**
    `rasterize` clears `dst` line by line (rasterizer.cr ~121) right
    after `Bytes.new(w*h*4)` already zeroed it (Crystal zeroes fresh
    Bytes). Remove the manual clear, and add a reusable class-level
    grow-only output buffer for the one-shot
    `Rasterizer.rasterize(image, tx, ty, scale, w, h)` so a bake
    doesn't hand 16 MB of garbage to the GC each call. Keep the
    caller-provided-buffer overload as the source of truth.

1d. **Hoist loop invariants** in `rasterize_sorted_edges` /
    `fill_active_edges`: `@ae_*` array pointers are re-fetched per
    scanline; take `.to_unsafe` once per shape pass (the flatten code
    already does this — the scan loop mostly doesn't). Bound-check
    removal via raw pointers in the innermost while loops.

## Stage 2 — output contract change (est. +25–40% off large bakes)

**Premultiplied output.** The pipeline composites straight-alpha, then
`unpremultiply_alpha` (rasterizer.cr ~1194) walks the whole buffer one
more time. Blending directly into premultiplied RGBA removes that
pass AND the per-pixel `div255(ia &* ...)` alpha round-trips in the
blend loops.

This is a **breaking output change**: `verify` hashes change, and
egui-cr's `Svg` bake + shader sampling must be coordinated (upload
flag or straight↔premultiplied switch in `Egui::NanoSvgCr.rasterize`
only). Land it as an opt-in (`premultiplied: Bool = false` argument)
first, flip egui-cr when its side is ready, then default it here.

## Stage 3 — parallelism (est. 3–5× wall-clock on ≥4 cores)

3a. **Parallel bakes across buckets (do this first — it's free).**
    The four zoom buckets 256/512/1024/2048 are independent bakes of
    the same immutable parsed `Image`. egui-cr's prewarm can bake them
    concurrently; nothing inside nanosvg.cr changes except thread
    safety of READS: `NanoSVG.parse` output and the rasterizer must
    not share mutable state across instances (they don't — one-shot
    Rasterizer per call; `NanoSvgCr.image`'s memo hash needs a mutex
    or pre-warm parse before spawning). Caveat: Crystal fibers are
    cooperative — CPU-bound work needs real threads
    (`crystal build --preview_mt` or host-side C threads). Measure
    first: if Stage 1+2 bring a 2048 bake under ~15 ms, skip 3b.

3b. **Band-parallel scan conversion inside one bake.**
    `rasterize_sorted_edges` walks scanlines top→bottom activating
    edges in y0 order; a horizontal band `[y0, y1)` can start by
    activating every edge with `ey0 < band_top` and run independently.
    The `@ae_*` active-edge pools become per-band. Bitmap bands are
    disjoint so no write contention. Auto-disable below 512×512
    (thread handoff costs more than the bake).

Priority note: 3a without 3b already covers the egui-cr startup case;
3b only matters for single huge bakes.

## Stage 4 — optional, only if the corpus gate is kept green

- **Flatten cache in user units.** `flatten_shape` re-tessellates
  per bake; the flatness test `(d2+d3)² < tess_tol·(dx²+dy²)` is
  scale-invariant, so flattening once at parse time and scaling the
  cached points is nearly identical — but not byte-identical.
  Gate: `bench/render_matching` + `dataset/` pixel-diff against
  librsvg within the existing tolerance, and `bench/verify` hashes
  regenerated ONCE, deliberately.
- **Tighter ACTIVE-edge walking** (skip-list or bucketed activation)
  only if profiling shows the scan walk dominating after 1d — on icon
  art it usually doesn't.

## Non-goals

- Don't touch the parser (separate cost center, already measured by
  bench: parse is not the bake bottleneck).
- Don't change `SUBSAMPLES`/`FIXSHIFT`/tess tolerances — they define
  the pixel-identical contract with C.
- No C fallback inside this shard: release builds are pure Crystal by
  design (egui-cr's dev-only C twin stays the A/B oracle).

## Expected combined result

Stage 1 (2.5–4×, identical pixels) → Stage 2 (+~1.3×, coordinated
contract flip) ≈ **3–5× single-threaded**, within sight of the C twin.
Stage 3a on top ≈ **×4 buckets in parallel** → startup warm time
effectively that of one mid-size bake. That is the 10× the zoom
canvas cares about; 3b is the stretch goal.

## Ledger

| Date | Stage | bench_cr 1024 rast min (ms) | bench_c 1024 rast min (ms) | verify |
|------|-------|------------------------------|----------------------------|--------|
| 2026-10-13 | 0 (baseline) | nano 3.24 / drawing 4.55 / 23.svg 26.0 | nano 2.30 / drawing 3.77 / 23.svg 24.8 | green |
| 2026-10-13 | 1a(hoist)+1c(pool)+1d | nano 2.74 / drawing 4.46 / 23.svg 26.3 | (same) | green |

Stage-1 measurements (macOS, ARM64, 3 interleaved runs, min; `bench_cr_base`
built from the pre-stage-1 source, so every round ran base/opt/C back to back):

| file        | w=128 base→opt | w=512 base→opt | w=1024 base→opt | w=1024 C |
|-------------|----------------|----------------|-----------------|----------|
| nano.svg    | 0.113 → 0.100  | 0.874 → 0.716  | 3.24 → 2.74     | 2.30     |
| drawing.svg | 0.161 → 0.146  | 1.381 → 1.239  | 4.55 → 4.46     | 3.77     |
| 23.svg      | 5.09 → 5.49*   | 11.51 → 11.67* | 26.02 → 26.34*  | 24.76    |

*23.svg is flatten/scan-dominated (solid fills), so the paint-loop hoisting
barely touches it; a focused re-run showed base/opt within noise there.
Paint-heavy files gain 12–18%.

### What landed from stage 1, and what didn't

- **1a (landed, reduced scope).** Gradient loops: `t[1]/t[3]/t[5]…` array
  fetches and `cache.colors[…]` bounds-checked lookups hoisted out of the
  per-pixel loops (locals + raw pointer). Float math order unchanged, so
  pixels are identical. The plan's fixed-point gradient stepping was NOT
  done: it changes float rounding and would break the pixel-identity gate
  against the C twin, which also computes per-pixel floats.
- **1b (attempted, reverted).** A UInt64 4×16-lane SWAR blend was
  implemented and proven bit-identical (exhaustive 2M-case check over
  cover × color × dst), but benchmarked ~10–15% SLOWER than the byte-wise
  loop: LLVM already auto-vectorizes the byte loop, and the SWAR's
  expand/repack + 64-bit multiplies defeat it. Reverted; kept the byte
  loop. Do not retry without NEON-expressible lanes.
- **1c (landed, partial).** The "double clear" is NOT removable: Crystal's
  `Bytes.new(n)` does NOT guarantee zeroed memory (std lib calls
  `Pointer.malloc`; the GC recycles dirty pages — verified by pixel diff).
  What landed: a grow-only pooled buffer behind the one-shot
  `Rasterizer.rasterize(image, …)` (returns a view; reused across calls —
  documented on the method), so repeated bakes stop handing 16 MB to the
  GC. The caller-buffer and instance overloads keep their clearing.
- **1d (landed).** `unpremultiply_alpha` walks pointers incrementally
  instead of recomputing `y*stride + x*4` per pixel; the scan-loop pointer
  hoisting turned out to be already done (previous round).

C-twin note: bench_c.c expects upstream headers at `~/nanosvg/src`; this
machine has them vendored in `~/egui.cr/vendor/nanosvg`. Build with:
`sed 's|../../nanosvg/src/|~/egui.cr/vendor/nanosvg/|g' bench/bench_c.c >
bench/build/bench_c.c && gcc -O2 -o bench/build/bench_c bench/build/bench_c.c -lm`

### Honest verdict vs the plan's estimates

Stage 1 promised 2.5–4×; reality is ~1.1–1.2× on paint-heavy art and
neutral elsewhere. The earlier flat-pool round (see bench/README.md)
already claimed the big wins; the remaining single-thread gap to C is
codegen quality on loops LLVM already vectorizes. The realistic levers
left are stage 2 (premultiplied output, +25–40%, contract change) and
stage 3a (parallel bucket bakes).
