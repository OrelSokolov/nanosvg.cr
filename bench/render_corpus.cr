# Batch-render a directory of SVGs to PNGs with the pure-Crystal pipeline.
#
#   crystal run bench/render_corpus.cr -- <in-dir> <out-dir> [width]
#
# Mirrors what the pixel-diff oracle does with rsvg-convert: currentColor
# resolved to black, PNG of exactly `width` x round(width * h/w) pixels.

require "../src/nanosvg"
require "../examples/png"

in_dir = ARGV[0]? || abort("usage: render_corpus <in-dir> <out-dir> [width]")
out_dir = ARGV[1]? || abort("usage: render_corpus <in-dir> <out-dir> [width]")
target_w = (ARGV[2]? || "640").to_i32

Dir.mkdir_p(out_dir)

files = Dir.glob(File.join(in_dir, "*.svg")).sort!
abort "no svg files in #{in_dir}" if files.empty?

t0 = Time.instant
count = 0
files.each do |f|
  src = File.read(f).gsub("currentColor", "#000000")
  image = NanoSVG.parse(src, "px", 96.0f32)

  scale = image.width > 0 ? target_w.to_f32 / image.width : 1.0f32
  w = target_w
  h = (image.height * scale).round.to_i32
  h = 1 if h < 1

  pixels = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, scale, w, h)
  PNG.write_rgba(File.join(out_dir, File.basename(f, ".svg") + ".png"), pixels, w, h)
  count += 1
end

dt = (Time.instant - t0).total_seconds
puts "rendered #{count} files to #{out_dir} in #{dt.round(2)}s (#{(count / dt).round(1)}/s)"
