# Pixel-diff against the librsvg reference dataset: renders every
# dataset/text case with the pure-Crystal pipeline and compares with
# the reference PNG, using the same metrics as the rasterizer
# contract bench — mean |Δα|, share of pixels with |Δα|>16, plus a
# full-RGBA identity check. Alpha carries the glyph coverage (text is
# drawn on a transparent background), so |Δα| is the shape metric.
#
#   crystal run bench/text_pixel_diff.cr -- [dataset-dir] [--worst N]
#
# Writes the N worst cases side by side (ours | reference | |Δα| map)
# to build/text_diff/ for inspection.

require "../src/nanosvg"
require "../examples/png"
require "./pngread"

dataset = ARGV[0]? || "#{__DIR__}/../dataset/text"
worst_n = (ARGV[1]? == "--worst" ? (ARGV[2]? || "10").to_i32 : 10)

diff_dir = "#{__DIR__}/build/text_diff"
Dir.mkdir_p(diff_dir)

results = [] of {String, Float64, Float64, Bool}
File.each_line(File.join(dataset, "manifest.tsv")) do |line|
  next if line.empty?
  name, w_s, h_s = line.split('\t')
  w = w_s.to_i32
  h = h_s.to_i32

  src = File.read(File.join(dataset, "cases", "#{name}.svg"))
  image = NanoSVG.parse(src, "px", 96.0f32)
  ours = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, 1.0f32, w, h)
  ref, rw, rh = NanoSVG::PNGRead.read_rgba(File.join(dataset, "reference", "#{name}.png"))

  if ours.nil? || rw != w || rh != h
    results << {name, Float64::MAX, 1.0, false}
    next
  end

  total = 0_i64
  big = 0_i64
  npix = w * h
  (0...npix).each do |i|
    d = (ours[i * 4 + 3].to_i - ref[i * 4 + 3].to_i).abs
    total += d
    big += 1 if d > 16
  end
  results << {name, total.to_f64 / npix, big.to_f64 / npix, ours == ref}
end

results.sort_by! { |_, mean, _, _| -mean }
identical = results.count(&.[3])
puts sprintf("cases: %d, byte-identical: %d (%.0f%%)",
  results.size, identical, identical * 100.0 / results.size)
worst = results.first
avg_mean = results.sum(&.[1]) / results.size
avg_big = results.sum(&.[2]) / results.size
puts sprintf("mean |Δα| avg %.2f, worst %.2f (%s); |Δα|>16 share avg %.2f%%, worst %.2f%% (%s)",
  avg_mean, worst[1], worst[0], avg_big * 100, results.max_by(&.[2])[2] * 100, results.max_by(&.[2])[0])
puts "worst 15:"
results.first(15).each do |name, mean, big, _|
  puts sprintf("  %-28s mean|Δα| %7.2f  |Δα|>16 %5.2f%%", name, mean, big * 100)
end

# Side-by-side PNGs for the worst N.
worst_n.times do |k|
  name = results[k]? || break
  next if name[1] == Float64::MAX
  w = h = 0
  File.each_line(File.join(dataset, "manifest.tsv")) do |line|
    parts = line.split('\t')
    if parts[0] == name[0]
      w = parts[1].to_i32
      h = parts[2].to_i32
    end
  end
  next unless w > 0

  src = File.read(File.join(dataset, "cases", "#{name[0]}.svg"))
  image = NanoSVG.parse(src, "px", 96.0f32)
  ours = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, 1.0f32, w, h).not_nil!
  ref, _, _ = NanoSVG::PNGRead.read_rgba(File.join(dataset, "reference", "#{name[0]}.png"))
  side = Bytes.new(w * h * 4 * 2)
  (0...h).each do |y|
    (0...w).each do |x|
      i = (y * w + x) * 4
      side[i] = ours[i]; side[i + 1] = ours[i + 1]
      side[i + 2] = ours[i + 2]; side[i + 3] = ours[i + 3]
      d = (ours[i + 3].to_i - ref[i + 3].to_i).abs.clamp(0, 255).to_u8
      j = w * h * 4 + i
      side[j] = d; side[j + 1] = 0; side[j + 2] = 0; side[j + 3] = 255
    end
  end
  PNG.write_rgba(File.join(diff_dir, "#{k + 1}_#{name[0]}.png"), side, w * 2, h)
end
puts "worst #{worst_n} diff images in #{diff_dir}" if worst_n > 0
