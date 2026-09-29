# Verifies rasterizer output: parses each SVG and prints a hash of the
# pixel buffer at several sizes. Used to check that optimizations do not
# change the rendered output.
#
# Build: crystal build --release -o bench/build/verify bench/verify.cr
# Usage: ./verify <file.svg> [...]

require "digest/crc32"
require "../src/nanosvg"

ARGV.each do |path|
  image = NanoSVG.parse_from_file(path, "px", 96.0f32)
  iw = image.width.round.to_i32
  ih = image.height.round.to_i32
  rast = NanoSVG::Rasterizer.new
  {128, 512, 1024}.each do |tw|
    scale = tw.to_f32 / iw
    w = (iw * scale).round.to_i32
    h = (ih * scale).round.to_i32
    w = 1 if w < 1
    h = 1 if h < 1
    pix = rast.rasterize(image, 0.0f32, 0.0f32, scale, w, h)
    puts "#{File.basename(path)} w=#{tw}: #{Digest::CRC32.checksum(pix).to_s(16)}"
  end
end
