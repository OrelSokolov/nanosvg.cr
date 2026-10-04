# Minimal PNG reader (8-bit RGB/RGBA, non-interlaced) for the
# pixel-diff tooling — reference rasterizations cairo writes.

require "compress/zlib"

module NanoSVG
  # Minimal PNG reader: 8-bit RGB/RGBA, non-interlaced — enough for
  # the reference rasterizations cairo writes.
  module PNGRead
    def self.read_rgba(path : String) : {Bytes, Int32, Int32}
      data = File.read(path).to_slice
      raise "not a png" unless data[0, 8] == Bytes[137, 80, 78, 71, 13, 10, 26, 10]

      w = h = 0
      color_type = 0
      idat = IO::Memory.new
      i = 8
      while i + 8 <= data.size
        len = be32(data, i)
        ctype = data[i + 4, 4]
        body = data[i + 8, len]
        case String.new(ctype)
        when "IHDR"
          w = be32(body, 0)
          h = be32(body, 4)
          raise "bit depth != 8" unless body[8] == 8
          raise "interlaced" unless body[12] == 0
          color_type = body[9]
        when "PLTE", "tRNS"
          raise "palette PNGs unsupported"
        when "IDAT" then idat.write(body)
        when "IEND" then break
        end
        i += 12 + len
      end

      channels = case color_type
                 when 2 then 3
                 when 6 then 4
                 else raise "unsupported color type #{color_type}"
                 end

      raw = Compress::Zlib::Reader.new(IO::Memory.new(idat.to_slice)).gets_to_end.to_slice.dup
      stride = w * channels
      raise "truncated idat" if raw.size < h * (stride + 1)

      out = Bytes.new(w * h * 4)
      prev = Bytes.new(stride)
      (0...h).each do |y|
        ft = raw[y * (stride + 1)]
        line = raw[y * (stride + 1) + 1, stride]
        unfilter(line, prev, ft, channels)
        (0...w).each do |x|
          r = line[x * channels]
          g = line[x * channels + 1]
          b = line[x * channels + 2]
          a : UInt8 = channels == 4 ? line[x * channels + 3] : 255_u8
          o = (y * w + x) * 4
          out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
        end
        prev = line.dup
      end
      {out, w, h}
    end

    private def self.be32(b : Bytes, off : Int32) : Int32
      (b[off].to_i32 << 24) | (b[off + 1].to_i32 << 16) |
        (b[off + 2].to_i32 << 8) | b[off + 3]
    end

    private def self.paeth(a : Int32, b : Int32, c : Int32) : Int32
      p = a + b - c
      pa = (p - a).abs
      pb = (p - b).abs
      pc = (p - c).abs
      pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
    end

    private def self.unfilter(line : Bytes, prev : Bytes, ft : UInt8, bpp : Int32) : Nil
      case ft
      when 0 then nil
      when 1
        (bpp...line.size).each { |i| line[i] = (line[i].to_i32 + line[i - bpp].to_i32).to_u8! }
      when 2
        line.size.times { |i| line[i] = (line[i].to_i32 + prev[i].to_i32).to_u8! }
      when 3
        line.size.times do |i|
          left = i >= bpp ? line[i - bpp].to_i32 : 0
          line[i] = (line[i].to_i32 + ((left + prev[i].to_i32) >> 1)).to_u8!
        end
      when 4
        line.size.times do |i|
          a = i >= bpp ? line[i - bpp].to_i32 : 0
          b = prev[i].to_i32
          c = i >= bpp ? prev[i - bpp].to_i32 : 0
          line[i] = (line[i].to_i32 + paeth(a, b, c)).to_u8!
        end
      else raise "bad filter #{ft}"
      end
    end
  end
end
