require "../src/nanosvg"
require "./pngread"

name = ARGV[0]? || "baseline_central_0"
base = "#{__DIR__}/../dataset/text"
src = File.read("#{base}/cases/#{name}.svg")
image = NanoSVG.parse(src, "px", 96.0f32)
ours = NanoSVG::Rasterizer.rasterize(image, 0.0f32, 0.0f32, 1.0f32, 480, 200).not_nil!
ref = NanoSVG::PNGRead.read_rgba("#{base}/reference/#{name}.png")[0]

def row_range(buf : Bytes, w : Int32, h : Int32) : Tuple(Int32, Int32)?
  top = bottom = nil
  (0...h).each do |y|
    covered = (0...w).any? { |x| buf[(y * w + x) * 4 + 3] > 100 }
    if covered
      top ||= y
      bottom = y
    end
  end
  top && bottom ? {top.not_nil!, bottom.not_nil!} : nil
end

puts "case #{name}"
puts "ours rows: #{row_range(ours, 480, 200).inspect}"
puts "ref  rows: #{row_range(ref, 480, 200).inspect}"
