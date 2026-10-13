# Stage-3a verification: parallel bucket bakes on real Crystal threads.
# Mirrors the egui-cr zoom-canvas prewarm: one immutable parsed Image,
# four independent bakes (256/512/1024/2048), each fiber with its own
# Rasterizer and output buffer. Checks that every parallel result is
# byte-identical to the single-threaded reference, and times sequential
# vs parallel prewarm wall-clock.
#
# Build: crystal build --release -Dpreview_mt \
#          -o bench/build/parallel_bake bench/parallel_bake.cr
# Usage: ./bench/build/parallel_bake <file.svg> [reps]

require "digest/crc32"
require "../src/nanosvg"

path = ARGV[0]? || abort("usage: parallel_bake <file.svg> [reps]")
reps = (ARGV[1]? || "5").to_i32

image = NanoSVG.parse(File.read(path), "px", 96.0f32)
iw = image.width.round.to_i32
ih = image.height.round.to_i32
BUCKETS = {256, 512, 1024, 2048}

# Single-threaded reference
ref = {} of Int32 => Bytes
BUCKETS.each do |tw|
  scale = tw.to_f32 / iw
  w = {(iw * scale).round.to_i32, 1}.max
  h = {(ih * scale).round.to_i32, 1}.max
  ref[tw] = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, scale, w, h).dup
end

name = File.basename(path)

# Warm (JIT-less, but touches code paths / allocates pools once) — sequential
BUCKETS.each do |tw|
  scale = tw.to_f32 / iw
  w = {(iw * scale).round.to_i32, 1}.max
  h = {(ih * scale).round.to_i32, 1}.max
  rast = NanoSVG::Rasterizer.new
  pix = Bytes.new(w * h * 4)
  rast.rasterize(image, 0.0f32, 0.0f32, scale, pix, w, h, w * 4)
end

bake = ->(tw : Int32, rast : NanoSVG::Rasterizer, pix : Bytes) do
  scale = tw.to_f32 / iw
  w = {(iw * scale).round.to_i32, 1}.max
  h = {(ih * scale).round.to_i32, 1}.max
  rast.rasterize(image, 0.0f32, 0.0f32, scale, pix, w, h, w * 4)
end

# Timing: sequential prewarm vs parallel prewarm (min of `reps` rounds)
seq_min = Float64::MAX
par_min = Float64::MAX
rasters = BUCKETS.map { |tw| NanoSVG::Rasterizer.new }
buffers = BUCKETS.map do |tw|
  scale = tw.to_f32 / iw
  w = {(iw * scale).round.to_i32, 1}.max
  h = {(ih * scale).round.to_i32, 1}.max
  Bytes.new(w * h * 4)
end

reps.times do
  t0 = Time.instant
  BUCKETS.each_with_index { |tw, k| bake.call(tw, rasters[k], buffers[k]) }
  dt = (Time.instant - t0).total_milliseconds
  seq_min = dt if dt < seq_min
end

reps.times do
  t0 = Time.instant
  done = Channel(Nil).new(BUCKETS.size)
  BUCKETS.each_with_index do |tw, k|
    spawn(same_thread: false) do
      bake.call(tw, rasters[k], buffers[k])
      done.send(nil)
    end
  end
  BUCKETS.size.times { done.receive }
  dt = (Time.instant - t0).total_milliseconds
  par_min = dt if dt < par_min
end

ok = Atomic(Int32).new(0)
reps.times do
  done = Channel(Nil).new(BUCKETS.size)
  BUCKETS.each do |tw|
    spawn(same_thread: false) do
      scale = tw.to_f32 / iw
      w = {(iw * scale).round.to_i32, 1}.max
      h = {(ih * scale).round.to_i32, 1}.max
      rast = NanoSVG::Rasterizer.new        # per-thread state
      pix = Bytes.new(w * h * 4)            # per-thread output
      rast.rasterize(image, 0.0f32, 0.0f32, scale, pix, w, h, w * 4)
      ok.add(1) if Digest::CRC32.checksum(pix) == Digest::CRC32.checksum(ref[tw])
      done.send(nil)
    end
  end
  BUCKETS.size.times { done.receive }
end

expected = BUCKETS.size * reps
got = ok.get
printf("%s: prewarm min %.2f ms sequential / %.2f ms parallel\n", name, seq_min, par_min)
if got == expected
  puts "#{name}: #{expected}/#{expected} parallel bucket bakes byte-identical to reference"
  exit 0
else
  puts "#{name}: FAIL — only #{got}/#{expected} identical"
  exit 1
end
