# <text> rendering smoke: parse an SVG with text, rasterize, PNG out.
require "../src/nanosvg"
require "../examples/png"

svg = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="120" viewBox="0 0 400 120">
  <rect x="0" y="0" width="400" height="120" fill="#ffffff"/>
  <text x="20" y="60" font-family="Liberation Sans" font-size="48" fill="#000000">WAVE AV</text>
  <text x="200" y="90" font-family="DejaVu Sans" font-size="24" fill="#1668c4"
        text-anchor="middle">AV Wave</text>
</svg>
SVG

image = NanoSVG.parse(svg, "px", 96.0f32)
puts "shapes: #{image.shapes.size} (expect 3: rect + 2 text)"
image.shapes.each_with_index do |sh, i|
  puts "  ##{i} paths=#{sh.paths.size} fill=#{sprintf("0x%08x", sh.fill.color)} bounds=#{sh.bounds.map(&.round).inspect}"
end
w = 400; h = 120
pixels = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, 1.0f32, w, h)
PNG.write_rgba("bench/build/text_smoke.png", pixels, w, h)
covered = pixels.each_slice(4).count { |(_, _, _, a)| a > 8 }
puts "covered px: #{covered}"
