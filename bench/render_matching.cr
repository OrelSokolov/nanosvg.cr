# Render SVGs at exactly the pixel sizes listed in a sizes manifest
# (name <tab> width <tab> height per line), for pixel-diffing against a
# reference dataset rasterized by another renderer.
#
#   crystal run bench/render_matching.cr -- <in-dir> <sizes.tsv> <out-dir>

require "../src/nanosvg"
require "../examples/png"

in_dir = ARGV[0]? || abort("usage: render_matching <in-dir> <sizes.tsv> <out-dir>")
sizes = ARGV[1]? || abort("usage: render_matching <in-dir> <sizes.tsv> <out-dir>")
out_dir = ARGV[2]? || abort("usage: render_matching <in-dir> <sizes.tsv> <out-dir>")

Dir.mkdir_p(out_dir)

t0 = Time.instant
count = 0
File.each_line(sizes) do |line|
  next if line.empty?
  name, w_s, h_s = line.split('\t')
  w = w_s.to_i32
  h = h_s.to_i32

  src = File.read(File.join(in_dir, "#{name}.svg")).gsub("currentColor", "#000000")
  image = NanoSVG.parse(src, "px", 96.0f32)

  scale = image.width > 0 ? w.to_f32 / image.width : 1.0f32
  pixels = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, scale, w, h)
  PNG.write_rgba(File.join(out_dir, "#{name}.png"), pixels, w, h)
  count += 1
end

dt = (Time.instant - t0).total_seconds
puts "rendered #{count} files to #{out_dir} in #{dt.round(2)}s (#{(count / dt).round(1)}/s)"
