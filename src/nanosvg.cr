# NanoSVG for Crystal — pure Crystal port of NanoSVG by Mikko Mononen.
#
# Parses SVG files into a list of cubic bezier shapes, optionally rasterized
# to an RGBA image. Faithful port of src/nanosvg.h and src/nanosvgrast.h.

require "./nanosvg/*"

module NanoSVG
  VERSION = {{ `shards version #{__DIR__}`.chomp.empty? ? "0.1.0" : `shards version #{__DIR__}`.chomp }}

  # Parse SVG from a string.
  # Units: one of "px", "pt", "pc", "mm", "cm", "in". DPI controls conversion.
  def self.parse(input : String, units : String = "px", dpi : Float32 = 96.0f32) : Image
    Parser.parse(input, units, dpi)
  end

  # Parse SVG from a file.
  def self.parse_from_file(filename : String, units : String = "px", dpi : Float32 = 96.0f32) : Image
    parse(File.read(filename), units, dpi)
  end
end
