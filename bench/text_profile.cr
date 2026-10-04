# Coverage-column profile of ours vs reference for one case: prints
# the x-spans of covered columns in both rasterizations, to tell a
# constant offset from an accumulating advance difference.
#
#   crystal run bench/text_profile.cr -- [case-name]

require "../src/nanosvg"
require "./pngread"

name = ARGV[0]? || "basic_liberation_sans_96"
base = "#{__DIR__}/../dataset/text"
src = File.read("#{base}/cases/#{name}.svg")
image = NanoSVG.parse(src, "px", 96.0f32)
ours = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, 1.0f32, 480, 200).not_nil!
ref = NanoSVG::PNGRead.read_rgba("#{base}/reference/#{name}.png")[0]

def col_spans(buf : Bytes, w : Int32, h : Int32) : Array(Tuple(Int32, Int32))
  spans = [] of Tuple(Int32, Int32)
  start = nil
  (0...w).each do |x|
    covered = (0...h).any? { |y| buf[(y * w + x) * 4 + 3] > 100 }
    if covered && start.nil?
      start = x
    elsif !covered && start
      spans << {start, x - 1}
      start = nil
    end
  end
  spans << {start.not_nil!, w - 1} if start
  spans
end

o_spans = col_spans(ours, 480, 200)
r_spans = col_spans(ref, 480, 200)
puts "case #{name}"
puts "ours (#{o_spans.size} spans): #{o_spans.inspect}"
puts "ref  (#{r_spans.size} spans): #{r_spans.inspect}"
