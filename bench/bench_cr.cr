# Crystal benchmark: NanoSVG parse + rasterize, timed separately.
# Mirrors bench/bench_c.c.
#
# Build: crystal build --release bench/bench_cr.cr
# Usage: ./bench_cr <file.svg> [file2.svg ...]

require "../src/nanosvg"

N_PARSE = 50
N_RAST  = 20

ARGV.each do |path|
  data = File.read(path)
  image = uninitialized NanoSVG::Image
  parse_min = Float64::MAX
  parse_sum = 0.0

  # --- parse benchmark (parser mirrors C, run on a fresh copy semantics each iter) ---
  N_PARSE.times do
    copy = data.dup
    t0 = Time.instant
    image = NanoSVG.parse(copy, "px", 96.0f32)
    dt = (Time.instant - t0).total_milliseconds
    parse_min = dt if dt < parse_min
    parse_sum += dt
  end
  printf("%-12s parse:  avg %8.3f ms  min %8.3f ms\n",
    File.basename(path), parse_sum / N_PARSE, parse_min)

  iw = image.width.round.to_i32
  ih = image.height.round.to_i32
  rast = NanoSVG::Rasterizer.new

  # --- rasterize benchmark at icon widths 128/512/1024 ---
  {128, 512, 1024}.each do |target_w|
    scale = target_w.to_f32 / iw
    w = (iw * scale).round.to_i32
    h = (ih * scale).round.to_i32
    w = 1 if w < 1
    h = 1 if h < 1
    pix = Bytes.new(w * h * 4)
    rast_min = Float64::MAX
    rast_sum = 0.0
    N_RAST.times do
      t0 = Time.instant
      rast.rasterize(image, 0.0f32, 0.0f32, scale, pix, w, h, w * 4)
      dt = (Time.instant - t0).total_milliseconds
      rast_min = dt if dt < rast_min
      rast_sum += dt
    end
    printf("%-12s raster w=%4d (%dx%d): avg %8.3f ms  min %8.3f ms\n",
      File.basename(path), target_w, w, h, rast_sum / N_RAST, rast_min)
  end
end
