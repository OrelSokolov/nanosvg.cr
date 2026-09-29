# Minimal PNG writer (RGBA, 8-bit, non-interlaced) on top of the Crystal
# stdlib zlib — used by the render example (mirrors example2.c which used
# stb_image_write).

require "digest/crc32"
require "compress/zlib"

module PNG
  def self.chunk(type : String, data : Bytes) : Bytes
    body = IO::Memory.new
    body.write(type.to_slice)
    body.write(data)
    io = IO::Memory.new
    io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
    io.write(type.to_slice)
    io.write(data)
    io.write_bytes(Digest::CRC32.checksum(body.to_slice), IO::ByteFormat::BigEndian)
    io.to_slice
  end

  def self.encode_rgba(pixels : Bytes, width : Int32, height : Int32) : Bytes
    io = IO::Memory.new
    # Signature
    io.write Bytes[137, 80, 78, 71, 13, 10, 26, 10]
    # IHDR
    ihdr = IO::Memory.new
    ihdr.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write Bytes[8u8, 6u8, 0u8, 0u8, 0u8] # depth 8, RGBA, deflate, adaptive, no interlace
    io.write chunk("IHDR", ihdr.to_slice)
    # IDAT
    raw = IO::Memory.new
    height.times do |y|
      raw.write_byte(0u8) # filter: none
      raw.write(pixels[y*width*4, width*4])
    end
    deflated = IO::Memory.new
    writer = Compress::Zlib::Writer.new(deflated, level: 6)
    writer.write(raw.to_slice)
    writer.close
    io.write chunk("IDAT", deflated.to_slice)
    # IEND
    io.write chunk("IEND", Bytes.empty)
    io.to_slice
  end

  def self.write_rgba(path : String, pixels : Bytes, width : Int32, height : Int32) : Nil
    File.write(path, encode_rgba(pixels, width, height))
  end
end
