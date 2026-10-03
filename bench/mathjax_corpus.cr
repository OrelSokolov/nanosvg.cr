# Corpus check against the mathjax.cr golden dataset (MathJax v3 SVG output).
#
#   crystal run bench/mathjax_corpus.cr -- [dataset-dir] [-v]
#
# Every painted element in that corpus is either a <use href="#MJX-...">
# (one glyph shape) or a <rect> (fraction/radical bars), so the expected
# shape count per file is count(use) + count(rect). A file passes when
# the parser emits exactly that many visible shapes.

require "../src/nanosvg"

dir = ARGV[0]? || File.expand_path("~/mathjax.cr/dataset/expected")
verbose = ARGV.includes?("-v")

files = Dir.glob(File.join(dir, "*.svg")).sort!
abort "no svg files in #{dir}" if files.empty?

total_expected = 0
total_got = 0
pass = 0
fail = 0

files.each do |f|
  src = File.read(f)
  # The corpus colors glyphs with currentColor; resolve to black like an
  # egui bake would (MathJax default context color).
  src = src.gsub("currentColor", "#000000")

  # Invisible glyphs (U+2061 function application etc.) have an empty d
  # and legitimately produce no shape.
  invisible = Set(String).new
  src.scan(/<path[^>]* id="([^"]+)"[^>]* d=""/) do |m|
    invisible << m[1]
  end
  src.scan(/<path[^>]* d=""[^>]* id="([^"]+)"/) do |m|
    invisible << m[1]
  end

  expected = src.scan(/<(?:\w+:)?use[\s>]/).size + src.scan(/<(?:\w+:)?rect[\s>]/).size
  src.scan(/href="#([^"]+)"/) { |m| expected -= 1 if invisible.includes?(m[1]) }

  got = 0
  begin
    image = NanoSVG.parse(src, "px", 96.0f32)
    got = image.shapes.count(&.visible?)
  rescue ex
    puts "PARSE RAISE #{File.basename(f)}: #{ex.message}" if verbose
    got = -1
  end

  total_expected += expected
  total_got += got > 0 ? got : 0
  if got == expected
    pass += 1
  else
    fail += 1
    puts "FAIL #{File.basename(f)}: expected #{expected} shapes, got #{got}" if verbose
  end
end

puts "dataset: #{dir}"
puts "files:   #{files.size}  pass: #{pass}  fail: #{fail}"
puts "shapes:  expected #{total_expected}, got #{total_got} (#{(total_got * 100.0 / total_expected).round(1)}%)"
exit(fail == 0 ? 0 : 1)
