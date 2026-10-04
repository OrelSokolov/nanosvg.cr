# Smoke test for the TTF reader: glyph outlines, advances, kerning.
require "../src/nanosvg"

path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
f = NanoSVG::Font.load(path)
abort "load failed" unless f
puts "upm=#{f.units_per_em} asc=#{f.ascender} desc=#{f.descender} xh=#{f.x_height}"

{'E'.ord, 'A'.ord, 'g'.ord, 0x4E2D}.each do |cp|
  gid = f.glyph_index(cp)
  g = f.glyph(gid)
  puts "cp=#{cp} gid=#{gid} advance=#{f.advance(gid)} contours=#{g ? g.contours.size : '-'} " \
       "pts=#{g ? g.contours.sum(&.size) : 0}"
end

# Kerning: DejaVu GPOS class kerning for A/V should be negative.
ka = f.glyph_index('A'.ord)
kv = f.glyph_index('V'.ord)
puts "kern(A,V)=#{f.kern(ka, kv)}"
puts "kern(V,A)=#{f.kern(kv, ka)}"
puts "kern(a,b)=#{f.kern(f.glyph_index('a'.ord), f.glyph_index('b'.ord))}"

# FontStore / fc-match
fo = NanoSVG::FontStore.font("DejaVu Sans", false, false)
fb = NanoSVG::FontStore.font("DejaVu Sans", true, false)
fi = NanoSVG::FontStore.font("Liberation Serif", false, true)
puts "regular: #{fo ? "ok" : "nil"} bold-upm=#{fb ? fb.units_per_em : '?'} italic=#{fi ? fi.ascender : "nil"}"

# Composite glyph sanity: a glyph built from components (e.g. é).
gid = f.glyph_index(0x00E9)
g = f.glyph(gid)
puts "e-acute: gid=#{gid} contours=#{g ? g.contours.size : '-'}"

# Bounds of 'M' should look sane (em width, positive height, y-down).
gid = f.glyph_index('M'.ord)
g = f.glyph(gid).not_nil!
minx = miny = Float32::MAX
maxx = maxy = -Float32::MAX
g.contours.each do |c|
  i = 0
  while i < c.size
    minx = {minx, c[i]}.min; maxx = {maxx, c[i]}.max
    miny = {miny, c[i + 1]}.min; maxy = {maxy, c[i + 1]}.max
    i += 2
  end
end
puts "M bounds: x #{minx.round}..#{maxx.round} y #{miny.round}..#{maxy.round} (upm #{f.units_per_em})"
