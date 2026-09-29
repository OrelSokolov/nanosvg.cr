# Render example — the Crystal equivalent of example2.c:
# parse an SVG, rasterize it, write a PNG.
#
# Usage: crystal run examples/render.cr -- input.svg output.png [width]

require "../src/nanosvg"
require "./png"

input = ARGV[0]? || abort("usage: render <input.svg> <output.png> [width]")
output = ARGV[1]? || abort("usage: render <input.svg> <output.png> [width]")

image = NanoSVG.parse_from_file(input, "px", 96.0f32)
puts "size: #{image.width} x #{image.height} (#{image.shapes.size} shapes)"

target_w = (ARGV[2]? || "512").to_i32
scale = image.width > 0 ? target_w.to_f32 / image.width : 1.0f32
w = (image.width * scale).round.to_i32
h = (image.height * scale).round.to_i32
w = 1 if w < 1
h = 1 if h < 1

t0 = Time.instant
pixels = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, scale, w, h)
t1 = Time.instant
puts "rasterized #{w}x#{h} in #{(t1 - t0).total_milliseconds.round(1)}ms"

PNG.write_rgba(output, pixels, w, h)
puts "wrote #{output}"
