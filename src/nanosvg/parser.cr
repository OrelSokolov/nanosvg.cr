# Crystal port of nanosvg.h — the NanoSVG SVG parser.
#
# Ported from C (https://github.com/memononen/nanosvg), Copyright (c) 2013-14
# Mikko Mononen (memon@inside.org), zlib license. The SVG parser is based on
# Anti-Grain Geometry 2.4 SVG example by Maxim Shemanarev; arc calculation code
# based on canvg.
#
# The output of the parser is a NanoSVG::Image: a list of shapes made of
# cubic bezier segments, transformed by the viewBox and converted to the
# requested units (px/pt/pc/mm/cm/in at the given DPI).
#
# The port is intentionally faithful to the C implementation, including
# some of its quirks (silent error fallbacks, gray fallback color, ...);
# deviations are marked with `NOTE(port)` comments.

require "./model"

module NanoSVG
  # Builds a color in the C NanoSVG layout: 0xAABBGGRR
  # (R in the low byte, A in the high byte; alpha added separately).
  def self.rgb(r : Int, g : Int, b : Int) : UInt32
    (r.to_u32 & 0xff) | ((g.to_u32 & 0xff) << 8) | ((b.to_u32 & 0xff) << 16)
  end

  # Fallback color used on any parse error (rgb(128, 128, 128)).
  GRAY = rgb(128, 128, 128)

  # NOTE(port): the full NANOSVG_ALL_COLOR_KEYWORDS list is always enabled.
  COLORS = {
    "red" => rgb(255, 0, 0), "green" => rgb(0, 128, 0), "blue" => rgb(0, 0, 255),
    "yellow" => rgb(255, 255, 0), "cyan" => rgb(0, 255, 255), "magenta" => rgb(255, 0, 255),
    "black" => rgb(0, 0, 0), "grey" => rgb(128, 128, 128), "gray" => rgb(128, 128, 128),
    "white" => rgb(255, 255, 255),
    "aliceblue" => rgb(240, 248, 255), "antiquewhite" => rgb(250, 235, 215), "aqua" => rgb(0, 255, 255),
    "aquamarine" => rgb(127, 255, 212), "azure" => rgb(240, 255, 255), "beige" => rgb(245, 245, 220),
    "bisque" => rgb(255, 228, 196), "blanchedalmond" => rgb(255, 235, 205), "blueviolet" => rgb(138, 43, 226),
    "brown" => rgb(165, 42, 42), "burlywood" => rgb(222, 184, 135), "cadetblue" => rgb(95, 158, 160),
    "chartreuse" => rgb(127, 255, 0), "chocolate" => rgb(210, 105, 30), "coral" => rgb(255, 127, 80),
    "cornflowerblue" => rgb(100, 149, 237), "cornsilk" => rgb(255, 248, 220), "crimson" => rgb(220, 20, 60),
    "darkblue" => rgb(0, 0, 139), "darkcyan" => rgb(0, 139, 139), "darkgoldenrod" => rgb(184, 134, 11),
    "darkgray" => rgb(169, 169, 169), "darkgreen" => rgb(0, 100, 0), "darkgrey" => rgb(169, 169, 169),
    "darkkhaki" => rgb(189, 183, 107), "darkmagenta" => rgb(139, 0, 139), "darkolivegreen" => rgb(85, 107, 47),
    "darkorange" => rgb(255, 140, 0), "darkorchid" => rgb(153, 50, 204), "darkred" => rgb(139, 0, 0),
    "darksalmon" => rgb(233, 150, 122), "darkseagreen" => rgb(143, 188, 143), "darkslateblue" => rgb(72, 61, 139),
    "darkslategray" => rgb(47, 79, 79), "darkslategrey" => rgb(47, 79, 79), "darkturquoise" => rgb(0, 206, 209),
    "darkviolet" => rgb(148, 0, 211), "deeppink" => rgb(255, 20, 147), "deepskyblue" => rgb(0, 191, 255),
    "dimgray" => rgb(105, 105, 105), "dimgrey" => rgb(105, 105, 105), "dodgerblue" => rgb(30, 144, 255),
    "firebrick" => rgb(178, 34, 34), "floralwhite" => rgb(255, 250, 240), "forestgreen" => rgb(34, 139, 34),
    "fuchsia" => rgb(255, 0, 255), "gainsboro" => rgb(220, 220, 220), "ghostwhite" => rgb(248, 248, 255),
    "gold" => rgb(255, 215, 0), "goldenrod" => rgb(218, 165, 32), "greenyellow" => rgb(173, 255, 47),
    "honeydew" => rgb(240, 255, 240), "hotpink" => rgb(255, 105, 180), "indianred" => rgb(205, 92, 92),
    "indigo" => rgb(75, 0, 130), "ivory" => rgb(255, 255, 240), "khaki" => rgb(240, 230, 140),
    "lavender" => rgb(230, 230, 250), "lavenderblush" => rgb(255, 240, 245), "lawngreen" => rgb(124, 252, 0),
    "lemonchiffon" => rgb(255, 250, 205), "lightblue" => rgb(173, 216, 230), "lightcoral" => rgb(240, 128, 128),
    "lightcyan" => rgb(224, 255, 255), "lightgoldenrodyellow" => rgb(250, 250, 210), "lightgray" => rgb(211, 211, 211),
    "lightgreen" => rgb(144, 238, 144), "lightgrey" => rgb(211, 211, 211), "lightpink" => rgb(255, 182, 193),
    "lightsalmon" => rgb(255, 160, 122), "lightseagreen" => rgb(32, 178, 170), "lightskyblue" => rgb(135, 206, 250),
    "lightslategray" => rgb(119, 136, 153), "lightslategrey" => rgb(119, 136, 153), "lightsteelblue" => rgb(176, 196, 222),
    "lightyellow" => rgb(255, 255, 224), "lime" => rgb(0, 255, 0), "limegreen" => rgb(50, 205, 50),
    "linen" => rgb(250, 240, 230), "maroon" => rgb(128, 0, 0), "mediumaquamarine" => rgb(102, 205, 170),
    "mediumblue" => rgb(0, 0, 205), "mediumorchid" => rgb(186, 85, 211), "mediumpurple" => rgb(147, 112, 219),
    "mediumseagreen" => rgb(60, 179, 113), "mediumslateblue" => rgb(123, 104, 238), "mediumspringgreen" => rgb(0, 250, 154),
    "mediumturquoise" => rgb(72, 209, 204), "mediumvioletred" => rgb(199, 21, 133), "midnightblue" => rgb(25, 25, 112),
    "mintcream" => rgb(245, 255, 250), "mistyrose" => rgb(255, 228, 225), "moccasin" => rgb(255, 228, 181),
    "navajowhite" => rgb(255, 222, 173), "navy" => rgb(0, 0, 128), "oldlace" => rgb(253, 245, 230),
    "olive" => rgb(128, 128, 0), "olivedrab" => rgb(107, 142, 35), "orange" => rgb(255, 165, 0),
    "orangered" => rgb(255, 69, 0), "orchid" => rgb(218, 112, 214), "palegoldenrod" => rgb(238, 232, 170),
    "palegreen" => rgb(152, 251, 152), "paleturquoise" => rgb(175, 238, 238), "palevioletred" => rgb(219, 112, 147),
    "papayawhip" => rgb(255, 239, 213), "peachpuff" => rgb(255, 218, 185), "peru" => rgb(205, 133, 63),
    "pink" => rgb(255, 192, 203), "plum" => rgb(221, 160, 221), "powderblue" => rgb(176, 224, 230),
    "purple" => rgb(128, 0, 128), "rosybrown" => rgb(188, 143, 143), "royalblue" => rgb(65, 105, 225),
    "saddlebrown" => rgb(139, 69, 19), "salmon" => rgb(250, 128, 114), "sandybrown" => rgb(244, 164, 96),
    "seagreen" => rgb(46, 139, 87), "seashell" => rgb(255, 245, 238), "sienna" => rgb(160, 82, 45),
    "silver" => rgb(192, 192, 192), "skyblue" => rgb(135, 206, 235), "slateblue" => rgb(106, 90, 205),
    "slategray" => rgb(112, 128, 144), "slategrey" => rgb(112, 128, 144), "snow" => rgb(255, 250, 250),
    "springgreen" => rgb(0, 255, 127), "steelblue" => rgb(70, 130, 180), "tan" => rgb(210, 180, 140),
    "teal" => rgb(0, 128, 128), "thistle" => rgb(216, 191, 216), "tomato" => rgb(255, 99, 71),
    "turquoise" => rgb(64, 224, 208), "violet" => rgb(238, 130, 238), "wheat" => rgb(245, 222, 179),
    "whitesmoke" => rgb(245, 245, 245), "yellowgreen" => rgb(154, 205, 50),
  }

  # Internal parser types (file-private).

  private enum Units
    USER
    PX
    PT
    PC
    MM
    CM
    IN
    PERCENT
    EM
    EX
  end

  private struct Coordinate
    property value : Float32
    property units : Units

    def initialize(@value = 0.0f32, @units = Units::USER)
    end
  end

  # Intermediate gradient definition collected during parsing
  # (C: NSVGgradientData).
  private class GradientData
    property id : String = ""
    property ref : String = ""
    property type : PaintType
    property spread : SpreadType = SpreadType::PAD
    property object_space : Bool = true # gradientUnits == objectBoundingBox
    property xform : Array(Float32)
    property stops : Array(GradientStop) = [] of GradientStop
    # linear
    property x1 : Coordinate; property y1 : Coordinate
    property x2 : Coordinate; property y2 : Coordinate
    # radial
    property cx : Coordinate; property cy : Coordinate
    property r : Coordinate; property fx : Coordinate; property fy : Coordinate

    def initialize(@type : PaintType)
      if @type.linear?
        @x1 = Coordinate.new(0.0f32, Units::PERCENT)
        @y1 = Coordinate.new(0.0f32, Units::PERCENT)
        @x2 = Coordinate.new(100.0f32, Units::PERCENT)
        @y2 = Coordinate.new(0.0f32, Units::PERCENT)
      else
        @x1 = Coordinate.new; @y1 = Coordinate.new
        @x2 = Coordinate.new; @y2 = Coordinate.new
      end
      @cx = Coordinate.new(50.0f32, Units::PERCENT)
      @cy = Coordinate.new(50.0f32, Units::PERCENT)
      @r = Coordinate.new(50.0f32, Units::PERCENT)
      @fx = Coordinate.new
      @fy = Coordinate.new
      @xform = [1.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32]
    end
  end

  # Style attribute stack entry (C: NSVGattrib).
  private class Attrib
    property id : String = ""
    property xform : Array(Float32) = [1.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32]
    property fill_color : UInt32 = 0u32
    property stroke_color : UInt32 = 0u32
    property opacity : Float32 = 1.0f32
    property fill_opacity : Float32 = 1.0f32
    property stroke_opacity : Float32 = 1.0f32
    property fill_gradient : String = ""
    property stroke_gradient : String = ""
    property stroke_width : Float32 = 1.0f32
    property stroke_dash_offset : Float32 = 0.0f32
    property stroke_dash_array : Array(Float32) = Array(Float32).new(8, 0.0f32)
    property stroke_dash_count : Int32 = 0
    property stroke_line_join : LineJoin = LineJoin::MITER
    property stroke_line_cap : LineCap = LineCap::BUTT
    property miter_limit : Float32 = 4.0f32
    property fill_rule : FillRule = FillRule::NONZERO
    property font_size : Float32 = 0.0f32
    property stop_color : UInt32 = 0u32
    property stop_opacity : Float32 = 1.0f32
    property stop_offset : Float32 = 0.0f32
    property has_fill : Int32 = 1
    property has_stroke : Int32 = 0
    property visible : Bool = true
    property paint_order : UInt8 = 0u8

    def initialize
      @paint_order = Parser.encode_paint_order(PAINT_FILL, PAINT_STROKE, PAINT_MARKERS)
    end

    # Deep-ish copy for pushAttr (C memcpy).
    def copy : Attrib
      a = Attrib.allocate
      a.id = @id
      a.xform = @xform.dup
      a.fill_color = @fill_color
      a.stroke_color = @stroke_color
      a.opacity = @opacity
      a.fill_opacity = @fill_opacity
      a.stroke_opacity = @stroke_opacity
      a.fill_gradient = @fill_gradient
      a.stroke_gradient = @stroke_gradient
      a.stroke_width = @stroke_width
      a.stroke_dash_offset = @stroke_dash_offset
      a.stroke_dash_array = @stroke_dash_array.dup
      a.stroke_dash_count = @stroke_dash_count
      a.stroke_line_join = @stroke_line_join
      a.stroke_line_cap = @stroke_line_cap
      a.miter_limit = @miter_limit
      a.fill_rule = @fill_rule
      a.font_size = @font_size
      a.stop_color = @stop_color
      a.stop_opacity = @stop_opacity
      a.stop_offset = @stop_offset
      a.has_fill = @has_fill
      a.has_stroke = @has_stroke
      a.visible = @visible
      a.paint_order = @paint_order
      a
    end
  end

  class Parser
    PI       = 3.14159265358979323846264338327f32
    KAPPA90  = 0.5522847493f32 # Length proportional to radius of a cubic bezier handle for 90deg arcs.
    EPSILON  = 1e-12
    MAX_ATTR = 128
    MAX_DASHES = 8
    MAX_CLASSES = 32
    XML_MAX_ATTRIBS = 256

    # preserveAspectRatio alignment
    ALIGN_MIN  = 0
    ALIGN_MID  = 1
    ALIGN_MAX  = 2
    ALIGN_NONE = 0
    ALIGN_MEET = 1
    ALIGN_SLICE = 2

    SQRT2F = Math.sqrt(2.0).to_f32

    # Parses an SVG from a string (does not modify the input).
    def self.parse(input : String, units : String = "px", dpi : Float32 = 96.0f32) : Image
      p = Parser.new
      p.dpi = dpi
      p.parse_xml(input)
      # Create gradients after all definitions have been parsed
      p.create_gradients
      # Scale to viewBox
      p.scale_to_viewbox(units)
      p.image
    end

    property image : Image
    property dpi : Float32 = 96.0f32

    @attr : Array(Attrib)
    @attr_head = 0
    @pts : Array(Float32) = [] of Float32
    @plist : Array(Path) = [] of Path
    @styles : Array(Tuple(String, String)) = [] of Tuple(String, String)
    @gradients : Array(GradientData) = [] of GradientData
    @view_min_x : Float32 = 0.0f32
    @view_min_y : Float32 = 0.0f32
    @view_width : Float32 = 0.0f32
    @view_height : Float32 = 0.0f32
    @align_x : Int32 = 0
    @align_y : Int32 = 0
    @align_type : Int32 = 0
    @path_flag = false
    @defs_flag = false
    @style_flag = false

    def initialize
      @image = Image.new
      @attr = Array(Attrib).new(MAX_ATTR) { Attrib.new }
    end

    # ---------- byte-level helpers (C operated on char*) ----------

    private def ch(s : String, i : Int32) : UInt8
      s.byte_at?(i) || 0_u8
    end

    private def ws?(c : UInt8) : Bool # isspace: " \t\n\v\f\r"
      c == 32 || (c >= 9 && c <= 13)
    end

    private def digit?(c : UInt8) : Bool
      c >= 48 && c <= 57
    end

    private def hex_digit?(c : UInt8) : Bool
      (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
    end

    private def hex_val(c : UInt8) : UInt32
      if c >= 48 && c <= 57
        (c - 48).to_u32
      elsif c >= 97 && c <= 102
        (c - 87).to_u32
      else
        (c - 55).to_u32
      end
    end

    private def minf(a : Float32, b : Float32) : Float32
      a < b ? a : b
    end

    private def maxf(a : Float32, b : Float32) : Float32
      a > b ? a : b
    end

    def self.encode_paint_order(a : UInt8, b : UInt8, c : UInt8) : UInt8
      (a & 0x03) | ((b & 0x03) << 2) | ((c & 0x03) << 4)
    end

    # ---------- transforms ----------

    private def xform_identity : Array(Float32)
      [1.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32]
    end

    private def xform_translation(tx : Float32, ty : Float32) : Array(Float32)
      [1.0f32, 0.0f32, 0.0f32, 1.0f32, tx, ty]
    end

    private def xform_scale(sx : Float32, sy : Float32) : Array(Float32)
      [sx, 0.0f32, 0.0f32, sy, 0.0f32, 0.0f32]
    end

    private def xform_skew_x(a : Float32) : Array(Float32)
      [1.0f32, 0.0f32, Math.tan(a.to_f64).to_f32, 1.0f32, 0.0f32, 0.0f32]
    end

    private def xform_skew_y(a : Float32) : Array(Float32)
      [1.0f32, Math.tan(a.to_f64).to_f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32]
    end

    private def xform_rotation(a : Float32) : Array(Float32)
      cs = Math.cos(a.to_f64).to_f32
      sn = Math.sin(a.to_f64).to_f32
      [cs, sn, -sn, cs, 0.0f32, 0.0f32]
    end

    private def xform_multiply(t : Array(Float32), s : Array(Float32)) : Array(Float32)
      t0 = t[0]*s[0] + t[1]*s[2]
      t2 = t[2]*s[0] + t[3]*s[2]
      t4 = t[4]*s[0] + t[5]*s[2] + s[4]
      t1 = t[0]*s[1] + t[1]*s[3]
      t3 = t[2]*s[1] + t[3]*s[3]
      t5 = t[4]*s[1] + t[5]*s[3] + s[5]
      [t0, t1, t2, t3, t4, t5] of Float32
    end

    private def xform_premultiply(t : Array(Float32), s : Array(Float32)) : Array(Float32)
      xform_multiply(s.dup, t)
    end

    # Returns nil for a (near-)singular matrix.
    # NOTE(port): in C the degenerate case also resets the *source* matrix
    # to identity and leaves the destination untouched (arguably a bug);
    # callers reproduce that behavior explicitly.
    private def xform_inverse(t : Array(Float32)) : Array(Float32)?
      det = t[0].to_f64 * t[3] - t[2].to_f64 * t[1]
      return nil if det > -1e-6 && det < 1e-6
      invdet = 1.0 / det
      inv = Array(Float32).new(6, 0.0f32)
      inv[0] = (t[3].to_f64 * invdet).to_f32
      inv[2] = (-t[2].to_f64 * invdet).to_f32
      inv[4] = ((t[2].to_f64 * t[5] - t[3].to_f64 * t[4]) * invdet).to_f32
      inv[1] = (-t[1].to_f64 * invdet).to_f32
      inv[3] = (t[0].to_f64 * invdet).to_f32
      inv[5] = ((t[1].to_f64 * t[4] - t[0].to_f64 * t[5]) * invdet).to_f32
      inv
    end

    private def xform_point(x : Float32, y : Float32, t : Array(Float32)) : {Float32, Float32}
      {x*t[0] + y*t[2] + t[4], x*t[1] + y*t[3] + t[5]}
    end

    private def xform_vec(x : Float32, y : Float32, t : Array(Float32)) : {Float32, Float32}
      {x*t[0] + y*t[2], x*t[1] + y*t[3]}
    end

    private def get_average_scale(t : Array(Float32)) : Float32
      sx = Math.sqrt((t[0]*t[0] + t[2]*t[2]).to_f64).to_f32
      sy = Math.sqrt((t[1]*t[1] + t[3]*t[3]).to_f64).to_f32
      (sx + sy) * 0.5f32
    end

    # ---------- bezier bounds ----------

    private def eval_bezier(t : Float64, p0 : Float64, p1 : Float64, p2 : Float64, p3 : Float64) : Float64
      it = 1.0 - t
      it*it*it*p0 + 3.0*it*it*t*p1 + 3.0*it*t*t*p2 + t*t*t*p3
    end

    private def pt_in_bounds?(pts : Array(Float32), idx : Int32, bounds : Array(Float32)) : Bool
      pts[idx] >= bounds[0] && pts[idx] <= bounds[2] && pts[idx+1] >= bounds[1] && pts[idx+1] <= bounds[3]
    end

    # curve = 4 points (8 floats) starting at index ci.
    private def curve_bounds(curve : Array(Float32), ci : Int32, bounds : Array(Float32)) : Nil
      v0 = ci
      v1 = ci + 2
      v2 = ci + 4
      v3 = ci + 6

      bounds[0] = minf(curve[v0], curve[v3])
      bounds[1] = minf(curve[v0+1], curve[v3+1])
      bounds[2] = maxf(curve[v0], curve[v3])
      bounds[3] = maxf(curve[v0+1], curve[v3+1])

      # Bezier curve fits inside the convex hull of its control points.
      return if pt_in_bounds?(curve, v1, bounds) && pt_in_bounds?(curve, v2, bounds)

      # Add bezier curve inflection points in X and Y.
      2.times do |i|
        a = -3.0*curve[v0+i] + 9.0*curve[v1+i] - 9.0*curve[v2+i] + 3.0*curve[v3+i]
        b = 6.0*curve[v0+i] - 12.0*curve[v1+i] + 6.0*curve[v2+i]
        c = 3.0*curve[v1+i] - 3.0*curve[v0+i]
        count = 0
        roots = [0.0_f64, 0.0_f64]
        if a.abs < EPSILON
          if b.abs > EPSILON
            t = -c / b
            if t > EPSILON && t < 1.0 - EPSILON
              roots[count] = t
              count += 1
            end
          end
        else
          b2ac = b*b - 4.0*c*a
          if b2ac > EPSILON
            t = (-b + Math.sqrt(b2ac)) / (2.0 * a)
            if t > EPSILON && t < 1.0 - EPSILON
              roots[count] = t
              count += 1
            end
            t = (-b - Math.sqrt(b2ac)) / (2.0 * a)
            if t > EPSILON && t < 1.0 - EPSILON
              roots[count] = t
              count += 1
            end
          end
        end
        count.times do |j|
          v = eval_bezier(roots[j], curve[v0+i].to_f64, curve[v1+i].to_f64, curve[v2+i].to_f64, curve[v3+i].to_f64)
          bounds[i] = minf(bounds[i], v.to_f32)
          bounds[i+2] = maxf(bounds[i+2], v.to_f32)
        end
      end
    end

    # ---------- path point accumulation ----------

    private def npts : Int32
      @pts.size // 2
    end

    private def reset_path
      @pts.clear
    end

    private def add_point(x : Float32, y : Float32)
      @pts << x
      @pts << y
    end

    private def move_to(x : Float32, y : Float32)
      if npts > 0
        @pts[@pts.size - 2] = x
        @pts[@pts.size - 1] = y
      else
        add_point(x, y)
      end
    end

    private def line_to(x : Float32, y : Float32)
      if npts > 0
        px = @pts[@pts.size - 2]
        py = @pts[@pts.size - 1]
        dx = x - px
        dy = y - py
        add_point(px + dx/3.0f32, py + dy/3.0f32)
        add_point(x - dx/3.0f32, y - dy/3.0f32)
        add_point(x, y)
      end
    end

    private def cubic_bez_to(cpx1 : Float32, cpy1 : Float32, cpx2 : Float32, cpy2 : Float32, x : Float32, y : Float32)
      if npts > 0
        add_point(cpx1, cpy1)
        add_point(cpx2, cpy2)
        add_point(x, y)
      end
    end

    # ---------- attribute stack ----------

    private def get_attr : Attrib
      @attr[@attr_head]
    end

    private def push_attr
      if @attr_head < MAX_ATTR - 1
        @attr_head += 1
        @attr[@attr_head] = @attr[@attr_head - 1].copy
      end
    end

    private def pop_attr
      @attr_head -= 1 if @attr_head > 0
    end

    # ---------- units ----------

    private def actual_orig_x : Float32
      @view_min_x
    end

    private def actual_orig_y : Float32
      @view_min_y
    end

    private def actual_width : Float32
      @view_width
    end

    private def actual_height : Float32
      @view_height
    end

    private def actual_length : Float32
      w = actual_width
      h = actual_height
      Math.sqrt((w*w + h*h).to_f64).to_f32 / SQRT2F
    end

    private def convert_to_pixels(c : Coordinate, orig : Float32, length : Float32) : Float32
      case c.units
      when .user?   then c.value
      when .px?     then c.value
      when .pt?     then c.value / 72.0f32 * @dpi
      when .pc?     then c.value / 6.0f32 * @dpi
      when .mm?     then c.value / 25.4f32 * @dpi
      when .cm?     then c.value / 2.54f32 * @dpi
      when .in?     then c.value * @dpi
      when .em?     then c.value * get_attr.font_size
      when .ex?     then c.value * get_attr.font_size * 0.52f32 # x-height of Helvetica.
      when .percent? then orig + c.value / 100.0f32 * length
      else               c.value
      end
    end

    # ---------- gradients ----------

    private def find_gradient_data(id : String) : GradientData?
      return nil if id.empty?
      @gradients.each do |grad|
        return grad if grad.id == id
      end
      nil
    end

    private def create_gradient(id : String, local_bounds : Array(Float32), xform : Array(Float32)) : {Gradient, PaintType}?
      data = find_gradient_data(id)
      return nil unless data

      # TODO: use ref to fill in all unset values too.
      stops_data = data
      ref_iter = 0
      while stops_data
        break unless stops_data.stops.empty?
        next_ref = find_gradient_data(stops_data.ref)
        break if next_ref == stops_data # prevent infinite loops on malformed data
        stops_data = next_ref
        ref_iter += 1
        break if ref_iter > 32 # prevent infinite loops on malformed data
      end
      return nil if stops_data.nil? || stops_data.stops.empty?

      grad = Gradient.new

      # The shape width and height.
      if data.object_space
        ox = local_bounds[0]
        oy = local_bounds[1]
        sw = local_bounds[2] - local_bounds[0]
        sh = local_bounds[3] - local_bounds[1]
      else
        ox = actual_orig_x
        oy = actual_orig_y
        sw = actual_width
        sh = actual_height
      end
      sl = Math.sqrt((sw*sw + sh*sh).to_f64).to_f32 / SQRT2F

      if data.type.linear?
        x1 = convert_to_pixels(data.x1, ox, sw)
        y1 = convert_to_pixels(data.y1, oy, sh)
        x2 = convert_to_pixels(data.x2, ox, sw)
        y2 = convert_to_pixels(data.y2, oy, sh)
        # Calculate transform aligned to the line
        dx = x2 - x1
        dy = y2 - y1
        grad.xform = [dy, -dx, dx, dy, x1, y1] of Float32
      else
        cx = convert_to_pixels(data.cx, ox, sw)
        cy = convert_to_pixels(data.cy, oy, sh)
        fx = convert_to_pixels(data.fx, ox, sw)
        fy = convert_to_pixels(data.fy, oy, sh)
        r = convert_to_pixels(data.r, 0.0f32, sl)
        # Calculate transform aligned to the circle
        grad.xform = [r, 0.0f32, 0.0f32, r, cx, cy] of Float32
        grad.fx = fx / r
        grad.fy = fy / r
      end

      grad.xform = xform_multiply(grad.xform, data.xform)
      grad.xform = xform_multiply(grad.xform, xform)

      grad.spread = data.spread
      grad.stops = stops_data.stops.dup

      {grad, data.type}
    end

    private def get_local_bounds(shape : Shape, inv : Array(Float32)) : Array(Float32)
      bounds = Array(Float32).new(4, 0.0f32)
      curve = Array(Float32).new(8, 0.0f32)
      cb = Array(Float32).new(4, 0.0f32)
      first = true
      shape.paths.each do |path|
        curve[0], curve[1] = xform_point(path.pts[0], path.pts[1], inv)
        n = path.npts
        i = 0
        while i < n - 1
          curve[2], curve[3] = xform_point(path.pts[(i+1)*2], path.pts[(i+1)*2+1], inv)
          curve[4], curve[5] = xform_point(path.pts[(i+2)*2], path.pts[(i+2)*2+1], inv)
          curve[6], curve[7] = xform_point(path.pts[(i+3)*2], path.pts[(i+3)*2+1], inv)
          curve_bounds(curve, 0, cb)
          if first
            4.times { |k| bounds[k] = cb[k] }
            first = false
          else
            bounds[0] = minf(bounds[0], cb[0])
            bounds[1] = minf(bounds[1], cb[1])
            bounds[2] = maxf(bounds[2], cb[2])
            bounds[3] = maxf(bounds[3], cb[3])
          end
          curve[0] = curve[6]
          curve[1] = curve[7]
          i += 3
        end
      end
      bounds
    end

    # ---------- shape / path creation ----------

    private def add_shape
      return if @plist.empty?

      attr = get_attr
      shape = Shape.new

      shape.id = attr.id
      shape.fill_gradient_id = attr.fill_gradient
      shape.stroke_gradient_id = attr.stroke_gradient
      shape.xform = attr.xform.dup
      scale = get_average_scale(attr.xform)
      shape.stroke_width = attr.stroke_width * scale
      shape.stroke_dash_offset = attr.stroke_dash_offset * scale
      shape.stroke_dash_count = attr.stroke_dash_count
      attr.stroke_dash_count.times do |i|
        shape.stroke_dash_array[i] = attr.stroke_dash_array[i] * scale
      end
      shape.stroke_line_join = attr.stroke_line_join
      shape.stroke_line_cap = attr.stroke_line_cap
      shape.miter_limit = attr.miter_limit
      shape.fill_rule = attr.fill_rule
      shape.opacity = attr.opacity
      shape.paint_order = attr.paint_order

      shape.paths = @plist
      @plist = [] of Path

      # Calculate shape bounds
      shape.bounds[0] = shape.paths[0].bounds[0]
      shape.bounds[1] = shape.paths[0].bounds[1]
      shape.bounds[2] = shape.paths[0].bounds[2]
      shape.bounds[3] = shape.paths[0].bounds[3]
      shape.paths.skip(1).each do |path|
        shape.bounds[0] = minf(shape.bounds[0], path.bounds[0])
        shape.bounds[1] = minf(shape.bounds[1], path.bounds[1])
        shape.bounds[2] = maxf(shape.bounds[2], path.bounds[2])
        shape.bounds[3] = maxf(shape.bounds[3], path.bounds[3])
      end

      # Set fill
      fill = Paint.new
      case attr.has_fill
      when 0 then fill.type = PaintType::NONE
      when 1
        fill.type = PaintType::COLOR
        fill.color = attr.fill_color | (((attr.fill_opacity * 255.0f32).to_u32) << 24)
      when 2 then fill.type = PaintType::UNDEF
      end
      shape.fill = fill

      # Set stroke
      stroke = Paint.new
      case attr.has_stroke
      when 0 then stroke.type = PaintType::NONE
      when 1
        stroke.type = PaintType::COLOR
        stroke.color = attr.stroke_color | (((attr.stroke_opacity * 255.0f32).to_u32) << 24)
      when 2 then stroke.type = PaintType::UNDEF
      end
      shape.stroke = stroke

      # Set flags
      shape.flags = attr.visible ? FLAGS_VISIBLE : 0x00u8

      @image.shapes << shape
    end

    private def add_path(closed : Bool)
      return if npts < 4

      line_to(@pts[0], @pts[1]) if closed

      # Expect 1 + N*3 points (N = number of cubic bezier segments).
      return if (npts % 3) != 1

      path = Path.new
      path.closed = closed

      xform = get_attr.xform
      i = 0
      while i < @pts.size
        x, y = xform_point(@pts[i], @pts[i+1], xform)
        path.pts << x
        path.pts << y
        i += 2
      end

      # Find bounds
      b = Array(Float32).new(4, 0.0f32)
      n = path.npts
      i = 0
      while i < n - 1
        curve_bounds(path.pts, i*2, b)
        if i == 0
          4.times { |k| path.bounds[k] = b[k] }
        else
          path.bounds[0] = minf(path.bounds[0], b[0])
          path.bounds[1] = minf(path.bounds[1], b[1])
          path.bounds[2] = maxf(path.bounds[2], b[2])
          path.bounds[3] = maxf(path.bounds[3], b[3])
        end
        i += 3
      end

      @plist.unshift(path)
    end

    # ---------- number parsing ----------

    # We roll our own string-to-float because stdlib to_f uses locale
    # dependent behavior in C (nsvg__atof).
    private def atof(s : String) : Float64
      i = 0
      res = 0.0_f64
      sign = 1.0_f64
      int_part = 0_i64
      has_int_part = false
      has_frac_part = false

      # Parse optional sign
      c = ch(s, 0)
      if c == 43 # '+'
        i += 1
      elsif c == 45 # '-'
        sign = -1.0_f64
        i += 1
      end

      # Parse integer part
      if digit?(ch(s, i))
        while digit?(ch(s, i))
          d = (ch(s, i) - 48).to_i64
          int_part = int_part < 922337203685477580 ? int_part &* 10 &+ d : int_part
          i += 1
        end
        res = int_part.to_f64
        has_int_part = true
      end

      # Parse fractional part.
      if ch(s, i) == 46 # '.'
        i += 1
        if digit?(ch(s, i))
          frac_part = 0_i64
          ndigits = 0
          while digit?(ch(s, i))
            d = (ch(s, i) - 48).to_i64
            frac_part = frac_part < 92233720368547758 ? frac_part &* 10 &+ d : frac_part
            ndigits += 1
            i += 1
          end
          res += frac_part.to_f64 / (10.0 ** ndigits)
          has_frac_part = true
        end
      end

      # A valid number should have integer or fractional part.
      return 0.0 unless has_int_part || has_frac_part

      # Parse optional exponent
      c = ch(s, i)
      if c == 101 || c == 69 # 'e' / 'E'
        i += 1
        esign = 1
        c2 = ch(s, i)
        if c2 == 43
          i += 1
        elsif c2 == 45
          esign = -1
          i += 1
        end
        if digit?(ch(s, i))
          exp_part = 0_i32
          while digit?(ch(s, i))
            exp_part = exp_part < 2000000000 ? exp_part &* 10 &+ (ch(s, i) - 48).to_i32 : exp_part
            i += 1
          end
          res *= 10.0 ** (exp_part * esign)
        end
      end

      res * sign
    end

    # Extracts a number token into a string of at most 63 bytes,
    # returns the byte index just past it.
    private def parse_number(s : String, i : Int32) : {Int32, String}
      last = 63 # size 64 - 1
      buf = String::Builder.new
      n = 0

      # sign
      c = ch(s, i)
      if c == 45 || c == 43 # '-' / '+'
        buf << '-' if c == 45 && n < last
        buf << '+' if c == 43 && n < last
        n += 1
        i += 1
      end
      # integer part
      while digit?(ch(s, i))
        buf << ch(s, i).chr if n < last
        n += 1
        i += 1
      end
      if ch(s, i) == 46 # '.'
        buf << '.' if n < last
        n += 1
        i += 1
        # fraction part
        while digit?(ch(s, i))
          buf << ch(s, i).chr if n < last
          n += 1
          i += 1
        end
      end
      # exponent
      c = ch(s, i)
      c1 = ch(s, i + 1)
      if (c == 101 || c == 69) && c1 != 109 && c1 != 120 # not 'em'/'ex'
        buf << 'e'
        n += 1
        i += 1
        c2 = ch(s, i)
        if c2 == 45 || c2 == 43
          buf << '-' if c2 == 45 && n < last
          buf << '+' if c2 == 43 && n < last
          n += 1
          i += 1
        end
        while digit?(ch(s, i))
          buf << ch(s, i).chr if n < last
          n += 1
          i += 1
        end
      end

      {i, buf.to_s}
    end

    private def get_next_path_item_when_arc_flag(s : String, i : Int32) : {Int32, String}
      size = s.bytesize
      while i < size && (ws?(s.byte_at(i)) || s.byte_at(i) == 44) # ','
        i += 1
      end
      return {i, ""} if i >= size
      c = s.byte_at(i)
      if c == 48 || c == 49 # '0' / '1'
        return {i + 1, s.byte_slice(i, 1)}
      end
      {i, ""}
    end

    private def get_next_path_item(s : String, i : Int32) : {Int32, String}
      size = s.bytesize
      # Skip white spaces and commas
      while i < size && (ws?(s.byte_at(i)) || s.byte_at(i) == 44) # ','
        i += 1
      end
      return {i, ""} if i >= size
      c = s.byte_at(i)
      if c == 45 || c == 43 || c == 46 || digit?(c) # '-' '+' '.'
        return parse_number(s, i)
      end
      # Parse command
      {i + 1, s.byte_slice(i, 1)}
    end

    private def get_next_dash_item(s : String, i : Int32) : {Int32, String}
      size = s.bytesize
      # Skip white spaces and commas
      while i < size && (ws?(s.byte_at(i)) || s.byte_at(i) == 44)
        i += 1
      end
      # Advance until whitespace, comma or end.
      start = i
      while i < size && !ws?(s.byte_at(i)) && s.byte_at(i) != 44
        i += 1
      end
      len = i - start
      len = 63 if len > 63
      {i, s.byte_slice(start, len)}
    end

    # ---------- color parsing ----------

    private def parse_color_hex(str : String) : UInt32
      # sscanf(str, "#%2x%2x%2x"): greedy up-to-2-digit hex groups
      i = 1 # skip '#'
      vals = [0u32, 0u32, 0u32]
      ok = true
      3.times do |k|
        v = 0u32
        n = 0
        while n < 2 && hex_digit?(ch(str, i))
          v = (v << 4) | hex_val(ch(str, i))
          n += 1
          i += 1
        end
        if n == 0
          ok = false
          break
        end
        vals[k] = v
      end
      return NanoSVG.rgb(vals[0], vals[1], vals[2]) if ok

      # sscanf(str, "#%1x%1x%1x"): 1 digit hex, e.g. #abc -> 0xccbbaa
      i = 1
      vals = [0u32, 0u32, 0u32]
      3.times do |k|
        if hex_digit?(ch(str, i))
          vals[k] = hex_val(ch(str, i))
          i += 1
        else
          return GRAY
        end
      end
      NanoSVG.rgb((vals[0] &* 17).to_i32, (vals[1] &* 17).to_i32, (vals[2] &* 17).to_i32)
    end

    # Mimics sscanf(str, "rgb(%u, %u, %u)") strictly (no whitespace before
    # ',' or ')' is accepted, mirroring the C quirks).
    private def sscanf_rgb_dec(s : String) : Array(UInt32)?
      i = 4 # skip "rgb("
      vals = Array(UInt32).new(3, 0u32)
      3.times do |k|
        # %u: skip leading whitespace, optional sign
        while ws?(ch(s, i))
          i += 1
        end
        sign = 1_i64
        c = ch(s, i)
        if c == 43 || c == 45
          sign = -1 if c == 45
          i += 1
        end
        start = i
        v = 0_i64
        while digit?(ch(s, i))
          v = v &* 10 &+ (ch(s, i) - 48).to_i64
          i += 1
        end
        return nil if i == start
        vals[k] = (v*sign).to_u32!
        if k < 2
          return nil unless ch(s, i) == 44 # ','
          i += 1
          while ws?(ch(s, i)) # ' ' in format
            i += 1
          end
        end
      end
      return nil unless ch(s, i) == 41 # ')'
      vals
    end

    # Parse rgb color. The pointer 'str' must point at "rgb(" (4+ characters).
    # This function returns gray (rgb(128, 128, 128) == '#808080') on parse
    # errors for backwards compatibility. Note: other image viewers return
    # black instead.
    private def parse_color_rgb(str : String) : UInt32
      rgbi = [0u32, 0u32, 0u32]
      if dec = sscanf_rgb_dec(str)
        rgbi = dec
      else
        # integers failed, try percent values (float, locale independent)
        rgbf = [0.0f32, 0.0f32, 0.0f32]
        delim = {44u8, 44u8, 41u8} # ',', ',', ')'
        i = 4 # skip "rgb("
        k = 0
        while k < 3
          while ws?(ch(str, i))
            i += 1
          end
          i += 1 if ch(str, i) == 43 # skip '+' (don't allow '-')
          break if ch(str, i) == 0
          rgbf[k] = atof(str.byte_slice(i, str.bytesize - i)).to_f32

          # Skip the number, the '%' character, spaces, and the delimiter
          # ',' or ')'. Values like "33.%" (decimal point w/o fractional
          # part) are rejected, consistent with other image viewers.
          while digit?(ch(str, i))
            i += 1
          end
          if ch(str, i) == 46 # '.'
            i += 1
            break unless digit?(ch(str, i)) # error: no digit after '.'
            while digit?(ch(str, i))
              i += 1
            end
          end
          if ch(str, i) == 37 # '%'
            i += 1
          else
            break
          end
          while ws?(ch(str, i))
            i += 1
          end
          if ch(str, i) == delim[k]
            i += 1
          else
            break
          end
          k += 1
        end
        if k == 3
          3.times do |j|
            v = rgbf[j] * 2.55f32
            # roundf() semantics: half away from zero (values are >= 0 here)
            v = v < 0.5f32 ? 0.0f32 : (v + 0.5f32).floor
            rgbi[j] = v.to_u32
          end
        else
          rgbi = [128u32, 128u32, 128u32]
        end
      end
      # clip values as the CSS spec requires
      3.times do |j|
        rgbi[j] = 255u32 if rgbi[j] > 255
      end
      NanoSVG.rgb(rgbi[0], rgbi[1], rgbi[2])
    end

    private def parse_color(str : String) : UInt32
      i = 0
      while ch(str, i) == 32 # ' '
        i += 1
      end
      s = str.byte_slice(i, str.bytesize - i)
      return parse_color_hex(s) if s.bytesize >= 1 && s.byte_at(0) == 35 # '#'
      if s.bytesize >= 4 && s.byte_at(0) == 114 && s.byte_at(1) == 103 && s.byte_at(2) == 98 && s.byte_at(3) == 40 # "rgb("
        return parse_color_rgb(s)
      end
      COLORS[s]? || GRAY
    end

    private def parse_opacity(str : String) : Float32
      val = atof(str).to_f32
      val = 0.0f32 if val < 0.0f32
      val = 1.0f32 if val > 1.0f32
      val
    end

    private def parse_miter_limit(str : String) : Float32
      val = atof(str).to_f32
      val = 0.0f32 if val < 0.0f32
      val
    end

    # ---------- coordinates ----------

    private def parse_units(s : String) : Units
      b0 = ch(s, 0)
      b1 = ch(s, 1)
      if b0 == 112 # 'p'
        return Units::PX if b1 == 120 # 'x'
        return Units::PT if b1 == 116 # 't'
        return Units::PC if b1 == 99  # 'c'
      elsif b0 == 109 # 'm'
        return Units::MM if b1 == 109
      elsif b0 == 99 # 'c'
        return Units::CM if b1 == 109
      elsif b0 == 105 # 'i'
        return Units::IN if b1 == 110 # 'n'
      elsif b0 == 37 # '%'
        return Units::PERCENT
      elsif b0 == 101 # 'e'
        return Units::EM if b1 == 109
        return Units::EX if b1 == 120
      end
      Units::USER
    end

    private def is_coordinate(s : String) : Bool
      # optional sign
      i = 0
      c = ch(s, 0)
      if c == 45 || c == 43
        i = 1
      end
      # must have at least one digit, or start by a dot
      c = ch(s, i)
      digit?(c) || c == 46
    end

    private def parse_coordinate_raw(str : String) : Coordinate
      i, buf = parse_number(str, 0)
      Coordinate.new(atof(buf).to_f32, parse_units(str.byte_slice(i, str.bytesize - i)))
    end

    private def parse_coordinate(str : String, orig : Float32, length : Float32) : Float32
      convert_to_pixels(parse_coordinate_raw(str), orig, length)
    end

    # ---------- transform attribute parsing ----------

    # NOTE(port): on malformed transform arguments C reads uninitialized stack
    # memory; this port uses zero-initialized arguments instead, so malformed
    # transforms degrade to identity/zero deterministically.

    private def parse_transform_args(s : String, max_na : Int32) : {Int32, Array(Float32), Int32}
      args = Array(Float32).new(6, 0.0f32)
      ptr = 0
      while ch(s, ptr) != 0 && ch(s, ptr) != 40 # '('
        ptr += 1
      end
      return {1, args, 0} if ch(s, ptr) == 0
      endp = ptr
      while ch(s, endp) != 0 && ch(s, endp) != 41 # ')'
        endp += 1
      end
      return {1, args, 0} if ch(s, endp) == 0

      na = 0
      while ptr < endp
        c = ch(s, ptr)
        if c == 45 || c == 43 || c == 46 || digit?(c)
          return {0, args, na} if na >= max_na
          ptr, it = parse_number(s, ptr)
          args[na] = atof(it).to_f32
          na += 1
        else
          ptr += 1
        end
      end
      {endp, args, na}
    end

    private def parse_matrix(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 6)
      if na == 6
        {len, args[0, 6].dup}
      else
        {len, xform_identity}
      end
    end

    private def parse_translate(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 2)
      args[1] = 0.0f32 if na == 1
      {len, xform_translation(args[0], args[1])}
    end

    private def parse_scale(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 2)
      args[1] = args[0] if na == 1
      {len, xform_scale(args[0], args[1])}
    end

    private def parse_skew_x(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 1)
      {len, xform_skew_x(args[0] / 180.0f32 * PI)}
    end

    private def parse_skew_y(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 1)
      {len, xform_skew_y(args[0] / 180.0f32 * PI)}
    end

    private def parse_rotate(s : String) : {Int32, Array(Float32)}
      len, args, na = parse_transform_args(s, 3)
      if na == 1
        args[1] = 0.0f32
        args[2] = 0.0f32
      end
      m = xform_identity
      if na > 1
        m = xform_multiply(m, xform_translation(-args[1], -args[2]))
      end
      m = xform_multiply(m, xform_rotation(args[0] / 180.0f32 * PI))
      if na > 1
        m = xform_multiply(m, xform_translation(args[1], args[2]))
      end
      {len, m}
    end

    private def parse_transform(str : String) : Array(Float32)
      xform = xform_identity
      i = 0
      while i < str.bytesize
        sub = str.byte_slice(i, str.bytesize - i)
        len = 0
        t : Array(Float32)? = nil
        if sub.starts_with?("matrix")
          len, t = parse_matrix(sub)
        elsif sub.starts_with?("translate")
          len, t = parse_translate(sub)
        elsif sub.starts_with?("scale")
          len, t = parse_scale(sub)
        elsif sub.starts_with?("rotate")
          len, t = parse_rotate(sub)
        elsif sub.starts_with?("skewX")
          len, t = parse_skew_x(sub)
        elsif sub.starts_with?("skewY")
          len, t = parse_skew_y(sub)
        else
          i += 1
          next
        end
        if len != 0
          i += len
        else
          i += 1
          next
        end
        xform = xform_premultiply(xform, t.not_nil!)
      end
      xform
    end

    # ---------- misc attribute parsers ----------

    private def parse_url(str : String) : String
      i = 4 # "url("
      i += 1 if ch(str, i) == 35 # '#'
      start = i
      while i < str.bytesize && i - start < 63 && str.byte_at(i) != 41 # ')'
        i += 1
      end
      str.byte_slice(start, i - start)
    end

    private def parse_line_cap(str : String) : LineCap
      case str
      when "butt"   then LineCap::BUTT
      when "round"  then LineCap::ROUND
      when "square" then LineCap::SQUARE
      else               LineCap::BUTT # TODO: handle inherit.
      end
    end

    private def parse_line_join(str : String) : LineJoin
      case str
      when "miter" then LineJoin::MITER
      when "round" then LineJoin::ROUND
      when "bevel" then LineJoin::BEVEL
      else               LineJoin::MITER # TODO: handle inherit.
      end
    end

    private def parse_fill_rule(str : String) : FillRule
      case str
      when "nonzero" then FillRule::NONZERO
      when "evenodd" then FillRule::EVENODD
      else                FillRule::NONZERO # TODO: handle inherit.
      end
    end

    private def parse_paint_order(str : String) : UInt8
      case str
      when "normal", "fill stroke markers"
        Parser.encode_paint_order(PAINT_FILL, PAINT_STROKE, PAINT_MARKERS)
      when "fill markers stroke"
        Parser.encode_paint_order(PAINT_FILL, PAINT_MARKERS, PAINT_STROKE)
      when "markers fill stroke"
        Parser.encode_paint_order(PAINT_MARKERS, PAINT_FILL, PAINT_STROKE)
      when "markers stroke fill"
        Parser.encode_paint_order(PAINT_MARKERS, PAINT_STROKE, PAINT_FILL)
      when "stroke fill markers"
        Parser.encode_paint_order(PAINT_STROKE, PAINT_FILL, PAINT_MARKERS)
      when "stroke markers fill"
        Parser.encode_paint_order(PAINT_STROKE, PAINT_MARKERS, PAINT_FILL)
      else # TODO: handle inherit.
        Parser.encode_paint_order(PAINT_FILL, PAINT_STROKE, PAINT_MARKERS)
      end
    end

    private def parse_stroke_dash_array(str : String, attr : Attrib) : Int32
      # Handle "none"
      return 0 if !str.empty? && str.byte_at(0) == 110 # 'n'

      i = 0
      count = 0
      while i < str.bytesize
        i, item = get_next_dash_item(str, i)
        break if item.empty?
        if count < MAX_DASHES
          attr.stroke_dash_array[count] = parse_coordinate(item, 0.0f32, actual_length).abs
          count += 1
        end
      end

      sum = 0.0f32
      count.times { |k| sum += attr.stroke_dash_array[k] }
      return 0 if sum <= 1e-6f32

      count
    end

    # Apply any matching class styles for a "class" attribute value. We support
    # only simple class selectors. The class attribute may contain multiple
    # space-separated class names.
    private def apply_class_styles(value : String)
      i = 0
      size = value.bytesize
      while i < size
        while i < size && ws?(value.byte_at(i))
          i += 1
        end
        break if i >= size
        start = i
        while i < size && !ws?(value.byte_at(i))
          i += 1
        end
        class_name = value.byte_slice(start, i - start)
        @styles.each do |cname, props|
          parse_style(props) if cname == class_name
        end
      end
    end

    private def parse_attr(name : String, value : String) : Bool
      attr = get_attr
      case name
      when "style"
        parse_style(value)
      when "display"
        # Don't reset ->visible on display:inline, one display:none hides
        # the whole subtree
        attr.visible = false if value == "none"
      when "fill"
        if value == "none"
          attr.has_fill = 0
        elsif value.starts_with?("url(")
          attr.has_fill = 2
          attr.fill_gradient = parse_url(value)
        else
          attr.has_fill = 1
          attr.fill_color = parse_color(value)
        end
      when "opacity"
        attr.opacity = parse_opacity(value)
      when "fill-opacity"
        attr.fill_opacity = parse_opacity(value)
      when "stroke"
        if value == "none"
          attr.has_stroke = 0
        elsif value.starts_with?("url(")
          attr.has_stroke = 2
          attr.stroke_gradient = parse_url(value)
        else
          attr.has_stroke = 1
          attr.stroke_color = parse_color(value)
        end
      when "stroke-width"
        attr.stroke_width = parse_coordinate(value, 0.0f32, actual_length)
      when "stroke-dasharray"
        attr.stroke_dash_count = parse_stroke_dash_array(value, attr)
      when "stroke-dashoffset"
        attr.stroke_dash_offset = parse_coordinate(value, 0.0f32, actual_length)
      when "stroke-opacity"
        attr.stroke_opacity = parse_opacity(value)
      when "stroke-linecap"
        attr.stroke_line_cap = parse_line_cap(value)
      when "stroke-linejoin"
        attr.stroke_line_join = parse_line_join(value)
      when "stroke-miterlimit"
        attr.miter_limit = parse_miter_limit(value)
      when "fill-rule"
        attr.fill_rule = parse_fill_rule(value)
      when "font-size"
        attr.font_size = parse_coordinate(value, 0.0f32, actual_length)
      when "transform"
        t = parse_transform(value)
        attr.xform = xform_premultiply(attr.xform, t)
      when "stop-color"
        attr.stop_color = parse_color(value)
      when "stop-opacity"
        attr.stop_opacity = parse_opacity(value)
      when "offset"
        attr.stop_offset = parse_coordinate(value, 0.0f32, 1.0f32)
      when "paint-order"
        attr.paint_order = parse_paint_order(value)
      when "id"
        attr.id = value.byte_slice(0, Math.min(63, value.bytesize))
      when "class"
        apply_class_styles(value)
      else
        return false
      end
      true
    end

    # decl: one "name: value" declaration (already trimmed).
    private def parse_name_value(decl : String) : Bool
      size = decl.bytesize
      colon = 0
      while colon < size && decl.byte_at(colon) != 58 # ':'
        colon += 1
      end

      # name = [0, j) right-trimmed of ':' and whitespace
      j = colon
      while j > 0 && (decl.byte_at(j - 1) == 58 || ws?(decl.byte_at(j - 1)))
        j -= 1
      end
      name = decl.byte_slice(0, j)

      k = colon
      while k < size && (decl.byte_at(k) == 58 || ws?(decl.byte_at(k)))
        k += 1
      end
      value = decl.byte_slice(k, size - k)

      parse_attr(name, value)
    end

    private def parse_style(str : String)
      i = 0
      size = str.bytesize
      while i < size
        # Left Trim
        while i < size && ws?(str.byte_at(i))
          i += 1
        end
        start = i
        while i < size && str.byte_at(i) != 59 # ';'
          i += 1
        end
        endp = i
        # Right Trim
        while endp > start && (ch(str, endp) == 59 || ws?(ch(str, endp)))
          endp -= 1
        end
        endp += 1
        parse_name_value(str.byte_slice(start, endp - start))
        i += 1 if i < size
      end
    end

    private def parse_attribs(attrs : Array(Tuple(String, String)))
      attrs.each do |name, value|
        if name == "style"
          parse_style(value)
        else
          parse_attr(name, value)
        end
      end
    end

    # ---------- path command handlers ----------

    private def get_args_per_element(cmd : Char) : Int32
      case cmd
      when 'v', 'V', 'h', 'H' then 1
      when 'm', 'M', 'l', 'L', 't', 'T' then 2
      when 'q', 'Q', 's', 'S' then 4
      when 'c', 'C' then 6
      when 'a', 'A' then 7
      when 'z', 'Z' then 0
      else -1
      end
    end

    # Mutable cursor state for path commands (replaces C out-params).
    private class PathCursor
      property cpx : Float32 = 0.0f32
      property cpy : Float32 = 0.0f32
      property cpx2 : Float32 = 0.0f32
      property cpy2 : Float32 = 0.0f32
      property init_point : Bool = false
    end

    private def path_move_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      if rel
        cur.cpx += args[0]
        cur.cpy += args[1]
      else
        cur.cpx = args[0]
        cur.cpy = args[1]
      end
      move_to(cur.cpx, cur.cpy)
    end

    private def path_line_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      if rel
        cur.cpx += args[0]
        cur.cpy += args[1]
      else
        cur.cpx = args[0]
        cur.cpy = args[1]
      end
      line_to(cur.cpx, cur.cpy)
    end

    private def path_h_line_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      if rel
        cur.cpx += args[0]
      else
        cur.cpx = args[0]
      end
      line_to(cur.cpx, cur.cpy)
    end

    private def path_v_line_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      if rel
        cur.cpy += args[0]
      else
        cur.cpy = args[0]
      end
      line_to(cur.cpx, cur.cpy)
    end

    private def path_cubic_bez_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      if rel
        cx1 = cur.cpx + args[0]
        cy1 = cur.cpy + args[1]
        cx2 = cur.cpx + args[2]
        cy2 = cur.cpy + args[3]
        x2 = cur.cpx + args[4]
        y2 = cur.cpy + args[5]
      else
        cx1 = args[0]
        cy1 = args[1]
        cx2 = args[2]
        cy2 = args[3]
        x2 = args[4]
        y2 = args[5]
      end

      cubic_bez_to(cx1, cy1, cx2, cy2, x2, y2)

      cur.cpx2 = cx2
      cur.cpy2 = cy2
      cur.cpx = x2
      cur.cpy = y2
    end

    private def path_cubic_bez_short_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      x1 = cur.cpx
      y1 = cur.cpy
      if rel
        cx2 = cur.cpx + args[0]
        cy2 = cur.cpy + args[1]
        x2 = cur.cpx + args[2]
        y2 = cur.cpy + args[3]
      else
        cx2 = args[0]
        cy2 = args[1]
        x2 = args[2]
        y2 = args[3]
      end

      cx1 = 2.0f32*x1 - cur.cpx2
      cy1 = 2.0f32*y1 - cur.cpy2

      cubic_bez_to(cx1, cy1, cx2, cy2, x2, y2)

      cur.cpx2 = cx2
      cur.cpy2 = cy2
      cur.cpx = x2
      cur.cpy = y2
    end

    private def path_quad_bez_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      x1 = cur.cpx
      y1 = cur.cpy
      if rel
        cx = cur.cpx + args[0]
        cy = cur.cpy + args[1]
        x2 = cur.cpx + args[2]
        y2 = cur.cpy + args[3]
      else
        cx = args[0]
        cy = args[1]
        x2 = args[2]
        y2 = args[3]
      end

      # Convert to cubic bezier
      cx1 = x1 + (2.0f32/3.0f32)*(cx - x1)
      cy1 = y1 + (2.0f32/3.0f32)*(cy - y1)
      cx2 = x2 + (2.0f32/3.0f32)*(cx - x2)
      cy2 = y2 + (2.0f32/3.0f32)*(cy - y2)

      cubic_bez_to(cx1, cy1, cx2, cy2, x2, y2)

      cur.cpx2 = cx
      cur.cpy2 = cy
      cur.cpx = x2
      cur.cpy = y2
    end

    private def path_quad_bez_short_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      x1 = cur.cpx
      y1 = cur.cpy
      if rel
        x2 = cur.cpx + args[0]
        y2 = cur.cpy + args[1]
      else
        x2 = args[0]
        y2 = args[1]
      end

      cx = 2.0f32*x1 - cur.cpx2
      cy = 2.0f32*y1 - cur.cpy2

      # Convert to cubic bezier
      cx1 = x1 + (2.0f32/3.0f32)*(cx - x1)
      cy1 = y1 + (2.0f32/3.0f32)*(cy - y1)
      cx2 = x2 + (2.0f32/3.0f32)*(cx - x2)
      cy2 = y2 + (2.0f32/3.0f32)*(cy - y2)

      cubic_bez_to(cx1, cy1, cx2, cy2, x2, y2)

      cur.cpx2 = cx
      cur.cpy2 = cy
      cur.cpx = x2
      cur.cpy = y2
    end

    private def sqr(x : Float32) : Float32
      x*x
    end

    private def vmag(x : Float32, y : Float32) : Float32
      Math.sqrt((x*x + y*y).to_f64).to_f32
    end

    private def vecrat(ux : Float32, uy : Float32, vx : Float32, vy : Float32) : Float32
      (ux*vx + uy*vy) / (vmag(ux, uy) * vmag(vx, vy))
    end

    private def vecang(ux : Float32, uy : Float32, vx : Float32, vy : Float32) : Float32
      r = vecrat(ux, uy, vx, vy)
      r = -1.0f32 if r < -1.0f32
      r = 1.0f32 if r > 1.0f32
      ((ux*vy < uy*vx) ? -1.0f32 : 1.0f32) * Math.acos(r.to_f64).to_f32
    end

    # Ported from canvg (https://code.google.com/p/canvg/)
    private def path_arc_to(cur : PathCursor, args : Array(Float32), rel : Bool)
      rx = args[0].abs # y radius
      ry = args[1].abs # x radius
      rotx = args[2] / 180.0f32 * PI # x rotation angle
      fa = args[3].abs > 1e-6 ? 1 : 0 # Large arc
      fs = args[4].abs > 1e-6 ? 1 : 0 # Sweep direction
      x1 = cur.cpx # start point
      y1 = cur.cpy
      if rel # end point
        x2 = cur.cpx + args[5]
        y2 = cur.cpy + args[6]
      else
        x2 = args[5]
        y2 = args[6]
      end

      dx = x1 - x2
      dy = y1 - y2
      d = Math.sqrt((dx*dx + dy*dy).to_f64).to_f32
      if d < 1e-6f32 || rx < 1e-6f32 || ry < 1e-6f32
        # The arc degenerates to a line
        line_to(x2, y2)
        cur.cpx = x2
        cur.cpy = y2
        return
      end

      sinrx = Math.sin(rotx.to_f64).to_f32
      cosrx = Math.cos(rotx.to_f64).to_f32

      # Convert to center point parameterization.
      # http://www.w3.org/TR/SVG11/implnote.html#ArcImplementationNotes
      # 1) Compute x1', y1'
      x1p = cosrx * dx / 2.0f32 + sinrx * dy / 2.0f32
      y1p = -sinrx * dx / 2.0f32 + cosrx * dy / 2.0f32
      d = sqr(x1p)/sqr(rx) + sqr(y1p)/sqr(ry)
      if d > 1
        d = Math.sqrt(d.to_f64).to_f32
        rx *= d
        ry *= d
      end
      # 2) Compute cx', cy'
      s = 0.0f32
      sa = sqr(rx)*sqr(ry) - sqr(rx)*sqr(y1p) - sqr(ry)*sqr(x1p)
      sb = sqr(rx)*sqr(y1p) + sqr(ry)*sqr(x1p)
      sa = 0.0f32 if sa < 0.0f32
      s = Math.sqrt((sa / sb).to_f64).to_f32 if sb > 0.0f32
      s = -s if fa == fs
      cxp = s * rx * y1p / ry
      cyp = s * -ry * x1p / rx

      # 3) Compute cx,cy from cx',cy'
      cx = (x1 + x2)/2.0f32 + cosrx*cxp - sinrx*cyp
      cy = (y1 + y2)/2.0f32 + sinrx*cxp + cosrx*cyp

      # 4) Calculate theta1, and delta theta.
      ux = (x1p - cxp) / rx
      uy = (y1p - cyp) / ry
      vx = (-x1p - cxp) / rx
      vy = (-y1p - cyp) / ry
      a1 = vecang(1.0f32, 0.0f32, ux, uy) # Initial angle
      da = vecang(ux, uy, vx, vy)         # Delta angle

      if fs == 0 && da > 0
        da -= 2 * PI
      elsif fs == 1 && da < 0
        da += 2 * PI
      end

      # Approximate the arc using cubic spline segments.
      t = [cosrx, sinrx, -sinrx, cosrx, cx, cy] of Float32

      # Split arc into max 90 degree segments.
      # The loop assumes an iteration per end point (including start and
      # end), this +1.
      ndivs = (da.abs / (PI*0.5f32) + 1.0f32).to_i32
      hda = (da / ndivs.to_f32) / 2.0f32
      # Fix for ticket #179: division by 0: avoid cotangens around 0 (infinite)
      if hda < 1e-3f32 && hda > -1e-3f32
        hda *= 0.5f32
      else
        hda = (1.0f32 - Math.cos(hda.to_f64).to_f32) / Math.sin(hda.to_f64).to_f32
      end
      kappa = (4.0f32/3.0f32 * hda).abs
      kappa = -kappa if da < 0.0f32

      px = 0.0f32
      py = 0.0f32
      ptanx = 0.0f32
      ptany = 0.0f32
      i = 0
      while i <= ndivs
        a = a1 + da * (i.to_f32 / ndivs.to_f32)
        dx = Math.cos(a.to_f64).to_f32
        dy = Math.sin(a.to_f64).to_f32
        x, y = xform_point(dx*rx, dy*ry, t) # position
        tanx, tany = xform_vec(-dy*rx * kappa, dx*ry * kappa, t) # tangent
        cubic_bez_to(px+ptanx, py+ptany, x-tanx, y-tany, x, y) if i > 0
        px = x
        py = y
        ptanx = tanx
        ptany = tany
        i += 1
      end

      cur.cpx = x2
      cur.cpy = y2
    end

    private def parse_path(attrs : Array(Tuple(String, String)))
      d = ""
      attrs.each do |name, value|
        if name == "d"
          d = value
        else
          parse_attribs([{name, value}])
        end
      end

      unless d.empty?
        reset_path
        cur = PathCursor.new
        args = Array(Float32).new(10, 0.0f32)
        cmd : Char? = nil
        nargs = 0
        rargs = 0
        closed_flag = false

        s = d
        i = 0
        while i < s.bytesize
          item = ""
          if (cmd == 'A' || cmd == 'a') && (nargs == 3 || nargs == 4)
            i, item = get_next_path_item_when_arc_flag(s, i)
          end
          if item.empty?
            i, item = get_next_path_item(s, i)
          end
          break if item.empty?

          if !cmd.nil? && is_coordinate(item)
            if nargs < 10
              args[nargs] = atof(item).to_f32
              nargs += 1
            end
            if nargs >= rargs
              case cmd
              when 'm', 'M'
                path_move_to(cur, args, cmd == 'm')
                # Moveto can be followed by multiple coordinate pairs,
                # which should be treated as linetos.
                cmd = cmd == 'm' ? 'l' : 'L'
                rargs = get_args_per_element('l')
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
                cur.init_point = true
              when 'l', 'L'
                path_line_to(cur, args, cmd == 'l')
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
              when 'H', 'h'
                path_h_line_to(cur, args, cmd == 'h')
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
              when 'V', 'v'
                path_v_line_to(cur, args, cmd == 'v')
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
              when 'C', 'c'
                path_cubic_bez_to(cur, args, cmd == 'c')
              when 'S', 's'
                path_cubic_bez_short_to(cur, args, cmd == 's')
              when 'Q', 'q'
                path_quad_bez_to(cur, args, cmd == 'q')
              when 'T', 't'
                path_quad_bez_short_to(cur, args, cmd == 't')
              when 'A', 'a'
                path_arc_to(cur, args, cmd == 'a')
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
              else
                if nargs >= 2
                  cur.cpx = args[nargs-2]
                  cur.cpy = args[nargs-1]
                  cur.cpx2 = cur.cpx
                  cur.cpy2 = cur.cpy
                end
              end
              nargs = 0
            end
          else
            cmd = item[0]
            if cmd == 'M' || cmd == 'm'
              # Commit path.
              add_path(closed_flag) if npts > 0
              # Start new subpath.
              reset_path
              closed_flag = false
              nargs = 0
            elsif !cur.init_point
              # Do not allow other commands until initial point has been set
              # (moveTo called once).
              cmd = nil
            end
            if cmd == 'Z' || cmd == 'z'
              closed_flag = true
              # Commit path.
              if npts > 0
                # Move current point to first point
                cur.cpx = @pts[0]
                cur.cpy = @pts[1]
                cur.cpx2 = cur.cpx
                cur.cpy2 = cur.cpy
                add_path(closed_flag)
              end
              # Start new subpath.
              reset_path
              move_to(cur.cpx, cur.cpy)
              closed_flag = false
              nargs = 0
            end
            rargs = cmd ? get_args_per_element(cmd.not_nil!) : -1
            if rargs == -1
              # Command not recognized
              cmd = nil
              rargs = 0
            end
          end
        end
        # Commit path.
        add_path(closed_flag) if npts > 0
      end

      add_shape
    end

    private def parse_rect(attrs : Array(Tuple(String, String)))
      x = 0.0f32
      y = 0.0f32
      w = 0.0f32
      h = 0.0f32
      rx = -1.0f32 # marks not set
      ry = -1.0f32

      attrs.each do |name, value|
        unless parse_attr(name, value)
          case name
          when "x"      then x = parse_coordinate(value, actual_orig_x, actual_width)
          when "y"      then y = parse_coordinate(value, actual_orig_y, actual_height)
          when "width"  then w = parse_coordinate(value, 0.0f32, actual_width)
          when "height" then h = parse_coordinate(value, 0.0f32, actual_height)
          when "rx"     then rx = parse_coordinate(value, 0.0f32, actual_width).abs
          when "ry"     then ry = parse_coordinate(value, 0.0f32, actual_height).abs
          end
        end
      end

      rx = ry if rx < 0.0f32 && ry > 0.0f32
      ry = rx if ry < 0.0f32 && rx > 0.0f32
      rx = 0.0f32 if rx < 0.0f32
      ry = 0.0f32 if ry < 0.0f32
      rx = w/2.0f32 if rx > w/2.0f32
      ry = h/2.0f32 if ry > h/2.0f32

      if w != 0.0f32 && h != 0.0f32
        reset_path

        if rx < 0.00001f32 || ry < 0.0001f32
          move_to(x, y)
          line_to(x+w, y)
          line_to(x+w, y+h)
          line_to(x, y+h)
        else
          # Rounded rectangle
          move_to(x+rx, y)
          line_to(x+w-rx, y)
          cubic_bez_to(x+w-rx*(1.0f32-KAPPA90), y, x+w, y+ry*(1.0f32-KAPPA90), x+w, y+ry)
          line_to(x+w, y+h-ry)
          cubic_bez_to(x+w, y+h-ry*(1.0f32-KAPPA90), x+w-rx*(1.0f32-KAPPA90), y+h, x+w-rx, y+h)
          line_to(x+rx, y+h)
          cubic_bez_to(x+rx*(1.0f32-KAPPA90), y+h, x, y+h-ry*(1.0f32-KAPPA90), x, y+h-ry)
          line_to(x, y+ry)
          cubic_bez_to(x, y+ry*(1.0f32-KAPPA90), x+rx*(1.0f32-KAPPA90), y, x+rx, y)
        end

        add_path(true)
        add_shape
      end
    end

    private def parse_circle(attrs : Array(Tuple(String, String)))
      cx = 0.0f32
      cy = 0.0f32
      r = 0.0f32

      attrs.each do |name, value|
        unless parse_attr(name, value)
          case name
          when "cx" then cx = parse_coordinate(value, actual_orig_x, actual_width)
          when "cy" then cy = parse_coordinate(value, actual_orig_y, actual_height)
          when "r"  then r = parse_coordinate(value, 0.0f32, actual_length).abs
          end
        end
      end

      if r > 0.0f32
        reset_path

        move_to(cx+r, cy)
        cubic_bez_to(cx+r, cy+r*KAPPA90, cx+r*KAPPA90, cy+r, cx, cy+r)
        cubic_bez_to(cx-r*KAPPA90, cy+r, cx-r, cy+r*KAPPA90, cx-r, cy)
        cubic_bez_to(cx-r, cy-r*KAPPA90, cx-r*KAPPA90, cy-r, cx, cy-r)
        cubic_bez_to(cx+r*KAPPA90, cy-r, cx+r, cy-r*KAPPA90, cx+r, cy)

        add_path(true)
        add_shape
      end
    end

    private def parse_ellipse(attrs : Array(Tuple(String, String)))
      cx = 0.0f32
      cy = 0.0f32
      rx = 0.0f32
      ry = 0.0f32

      attrs.each do |name, value|
        unless parse_attr(name, value)
          case name
          when "cx" then cx = parse_coordinate(value, actual_orig_x, actual_width)
          when "cy" then cy = parse_coordinate(value, actual_orig_y, actual_height)
          when "rx" then rx = parse_coordinate(value, 0.0f32, actual_width).abs
          when "ry" then ry = parse_coordinate(value, 0.0f32, actual_height).abs
          end
        end
      end

      if rx > 0.0f32 && ry > 0.0f32
        reset_path

        move_to(cx+rx, cy)
        cubic_bez_to(cx+rx, cy+ry*KAPPA90, cx+rx*KAPPA90, cy+ry, cx, cy+ry)
        cubic_bez_to(cx-rx*KAPPA90, cy+ry, cx-rx, cy+ry*KAPPA90, cx-rx, cy)
        cubic_bez_to(cx-rx, cy-ry*KAPPA90, cx-rx*KAPPA90, cy-ry, cx, cy-ry)
        cubic_bez_to(cx+rx*KAPPA90, cy-ry, cx+rx, cy-ry*KAPPA90, cx+rx, cy)

        add_path(true)
        add_shape
      end
    end

    private def parse_line(attrs : Array(Tuple(String, String)))
      x1 = 0.0f32
      y1 = 0.0f32
      x2 = 0.0f32
      y2 = 0.0f32

      attrs.each do |name, value|
        unless parse_attr(name, value)
          case name
          when "x1" then x1 = parse_coordinate(value, actual_orig_x, actual_width)
          when "y1" then y1 = parse_coordinate(value, actual_orig_y, actual_height)
          when "x2" then x2 = parse_coordinate(value, actual_orig_x, actual_width)
          when "y2" then y2 = parse_coordinate(value, actual_orig_y, actual_height)
          end
        end
      end

      reset_path

      move_to(x1, y1)
      line_to(x2, y2)

      add_path(false)
      add_shape
    end

    private def parse_poly(attrs : Array(Tuple(String, String)), close_flag : Bool)
      reset_path

      attrs.each do |name, value|
        unless parse_attr(name, value)
          if name == "points"
            s = value
            i = 0
            args = Array(Float32).new(2, 0.0f32)
            nargs = 0
            poly_npts = 0
            while i < s.bytesize
              i, item = get_next_path_item(s, i)
              args[nargs] = atof(item).to_f32
              nargs += 1
              if nargs >= 2
                if poly_npts == 0
                  move_to(args[0], args[1])
                else
                  line_to(args[0], args[1])
                end
                nargs = 0
                poly_npts += 1
              end
            end
          end
        end
      end

      add_path(close_flag)
      add_shape
    end

    private def parse_svg(attrs : Array(Tuple(String, String)))
      attrs.each do |name, value|
        unless parse_attr(name, value)
          case name
          when "width"
            @image.width = parse_coordinate(value, 0.0f32, 0.0f32)
          when "height"
            @image.height = parse_coordinate(value, 0.0f32, 0.0f32)
          when "viewBox"
            s = value
            i = 0
            i, buf = parse_number(s, i)
            @view_min_x = atof(buf).to_f32
            while ch(s, i) != 0 && (ws?(ch(s, i)) || ch(s, i) == 37 || ch(s, i) == 44)
              i += 1
            end
            return if ch(s, i) == 0
            i, buf = parse_number(s, i)
            @view_min_y = atof(buf).to_f32
            while ch(s, i) != 0 && (ws?(ch(s, i)) || ch(s, i) == 37 || ch(s, i) == 44)
              i += 1
            end
            return if ch(s, i) == 0
            i, buf = parse_number(s, i)
            @view_width = atof(buf).to_f32
            while ch(s, i) != 0 && (ws?(ch(s, i)) || ch(s, i) == 37 || ch(s, i) == 44)
              i += 1
            end
            return if ch(s, i) == 0
            i, buf = parse_number(s, i)
            @view_height = atof(buf).to_f32
          when "preserveAspectRatio"
            if value.includes?("none")
              # No uniform scaling
              @align_type = ALIGN_NONE
            else
              # Parse X align
              if value.includes?("xMin")
                @align_x = ALIGN_MIN
              elsif value.includes?("xMid")
                @align_x = ALIGN_MID
              elsif value.includes?("xMax")
                @align_x = ALIGN_MAX
              end
              # Parse Y align
              if value.includes?("yMin")
                @align_y = ALIGN_MIN
              elsif value.includes?("yMid")
                @align_y = ALIGN_MID
              elsif value.includes?("yMax")
                @align_y = ALIGN_MAX
              end
              # Parse meet/slice
              @align_type = ALIGN_MEET
              @align_type = ALIGN_SLICE if value.includes?("slice")
            end
          end
        end
      end
    end

    private def parse_gradient(attrs : Array(Tuple(String, String)), type : PaintType)
      grad = GradientData.new(type)

      attrs.each do |name, value|
        if name == "id"
          grad.id = value.byte_slice(0, Math.min(63, value.bytesize))
        elsif !parse_attr(name, value)
          case name
          when "gradientUnits"
            grad.object_space = value == "objectBoundingBox"
          when "gradientTransform"
            grad.xform = parse_transform(value)
          when "cx" then grad.cx = parse_coordinate_raw(value)
          when "cy" then grad.cy = parse_coordinate_raw(value)
          when "r"  then grad.r = parse_coordinate_raw(value)
          when "fx" then grad.fx = parse_coordinate_raw(value)
          when "fy" then grad.fy = parse_coordinate_raw(value)
          when "x1" then grad.x1 = parse_coordinate_raw(value)
          when "y1" then grad.y1 = parse_coordinate_raw(value)
          when "x2" then grad.x2 = parse_coordinate_raw(value)
          when "y2" then grad.y2 = parse_coordinate_raw(value)
          when "spreadMethod"
            case value
            when "pad"     then grad.spread = SpreadType::PAD
            when "reflect" then grad.spread = SpreadType::REFLECT
            when "repeat"  then grad.spread = SpreadType::REPEAT
            end
          when "xlink:href"
            href = value
            grad.ref = href.bytesize > 1 ? href.byte_slice(1, Math.min(62, href.bytesize - 1)) : ""
          end
        end
      end

      @gradients.unshift(grad)
    end

    private def parse_gradient_stop(attrs : Array(Tuple(String, String)))
      cur_attr = get_attr

      cur_attr.stop_offset = 0.0f32
      cur_attr.stop_color = 0u32
      cur_attr.stop_opacity = 1.0f32

      attrs.each do |name, value|
        parse_attr(name, value)
      end

      # Add stop to the last gradient.
      grad = @gradients.first?
      return if grad.nil?

      # Insert (sorted by offset)
      idx = grad.stops.size
      grad.stops.each_with_index do |stop, i|
        if cur_attr.stop_offset < stop.offset
          idx = i
          break
        end
      end
      color = cur_attr.stop_color | (((cur_attr.stop_opacity * 255.0f32).to_u32) << 24)
      grad.stops.insert(idx, GradientStop.new(color, cur_attr.stop_offset))
    end

    # ---------- XML element callbacks ----------

    private def start_element(el : String, attrs : Array(Tuple(String, String)))
      if @defs_flag
        # Skip everything but gradients and styles in defs
        case el
        when "linearGradient" then parse_gradient(attrs, PaintType::LINEAR)
        when "radialGradient" then parse_gradient(attrs, PaintType::RADIAL)
        when "stop"           then parse_gradient_stop(attrs)
        when "style"          then @style_flag = true
        end
        return
      end

      case el
      when "g"
        push_attr
        parse_attribs(attrs)
      when "path"
        return if @path_flag # Do not allow nested paths.
        push_attr
        parse_path(attrs)
        pop_attr
      when "rect"
        push_attr
        parse_rect(attrs)
        pop_attr
      when "circle"
        push_attr
        parse_circle(attrs)
        pop_attr
      when "ellipse"
        push_attr
        parse_ellipse(attrs)
        pop_attr
      when "line"
        push_attr
        parse_line(attrs)
        pop_attr
      when "polyline"
        push_attr
        parse_poly(attrs, false)
        pop_attr
      when "polygon"
        push_attr
        parse_poly(attrs, true)
        pop_attr
      when "linearGradient"
        parse_gradient(attrs, PaintType::LINEAR)
      when "radialGradient"
        parse_gradient(attrs, PaintType::RADIAL)
      when "stop"
        parse_gradient_stop(attrs)
      when "defs"
        @defs_flag = true
      when "svg"
        parse_svg(attrs)
      when "style"
        @style_flag = true
      end
    end

    private def end_element(el : String)
      case el
      when "g"     then pop_attr
      when "path"  then @path_flag = false
      when "defs"  then @defs_flag = false
      when "style" then @style_flag = false
      end
    end

    # Content callback: parses <style> blocks.
    # Note: we only support selector lists of simple class selectors
    # (e.g. ".foo, .bar { ... }").
    private def on_content(s : String)
      i = 0
      size = s.bytesize
      # Trim start white spaces (C nsvg__parseContent)
      while i < size && ws?(s.byte_at(i))
        i += 1
      end
      return if i >= size
      return unless @style_flag

      while i < size
        staged = [] of String

        # 1) Parse the selector list up to '{'.
        while i < size && s.byte_at(i) != 123 # '{'
          while i < size && (ws?(s.byte_at(i)) || s.byte_at(i) == 44) # ','
            i += 1
          end
          break if i >= size || s.byte_at(i) == 123
          sel_start = i
          while i < size && !ws?(s.byte_at(i)) && s.byte_at(i) != 44 && s.byte_at(i) != 123
            i += 1
          end
          sel = s.byte_slice(sel_start, i - sel_start)
          if sel.bytesize > 0 && sel.byte_at(0) == 46 && staged.size < MAX_CLASSES # '.'
            staged << s.byte_slice(sel_start + 1, i - sel_start - 1)
          end
        end
        break if i >= size
        i += 1 # advance past '{'

        # 2) Find the end of the properties block (up to '}').
        props_start = i
        while i < size && s.byte_at(i) != 125 # '}'
          i += 1
        end
        props = s.byte_slice(props_start, i - props_start)

        # 3) Commit (head-insertion, mirroring the C list order).
        staged.each { |name| @styles.unshift({name, props}) }

        i += 1 if i < size # advance past '}'
      end
    end

    # ---------- XML scanner ----------

    private def parse_element(el : String)
      attrs = [] of Tuple(String, String)
      i = 0
      size = el.bytesize
      start_tag = false
      end_tag = false

      # Skip white space after the '<'
      while i < size && ws?(el.byte_at(i))
        i += 1
      end

      # Check if the tag is end tag
      if i < size && el.byte_at(i) == 47 # '/'
        i += 1
        end_tag = true
      else
        start_tag = true
      end

      # Skip comments, data and preprocessor stuff.
      c = ch(el, i)
      return if c == 0 || c == 63 || c == 33 # '?' '!'

      # Get tag name
      name_start = i
      while i < size && !ws?(el.byte_at(i))
        i += 1
      end
      name = el.byte_slice(name_start, i - name_start)

      # Get attribs
      while !end_tag && i < size && attrs.size < (XML_MAX_ATTRIBS - 3) // 2
        # Skip white space before the attrib name
        while i < size && ws?(el.byte_at(i))
          i += 1
        end
        break if i >= size
        if el.byte_at(i) == 47 # '/'
          end_tag = true
          break
        end
        aname_start = i
        # Find end of the attrib name.
        while i < size && !ws?(el.byte_at(i)) && el.byte_at(i) != 61 # '='
          i += 1
        end
        aname = el.byte_slice(aname_start, i - aname_start)
        # Skip until the beginning of the value.
        while i < size && el.byte_at(i) != 34 && el.byte_at(i) != 39 # '"' '\''
          i += 1
        end
        break if i >= size
        quote = el.byte_at(i)
        i += 1
        # Store value and find the end of it.
        vstart = i
        while i < size && el.byte_at(i) != quote
          i += 1
        end
        value = el.byte_slice(vstart, i - vstart)
        i += 1 if i < size

        attrs << {aname, value}
      end

      # Call callbacks.
      start_element(name, attrs) if start_tag
      end_element(name) if end_tag
    end

    def parse_xml(input : String)
      i = 0
      mark = 0
      size = input.bytesize
      in_tag = false
      while i < size
        c = input.byte_at(i)
        if c == 60 && !in_tag # '<'
          # Start of a tag
          on_content(input.byte_slice(mark, i - mark))
          i += 1
          mark = i
          in_tag = true
        elsif c == 62 && in_tag # '>'
          # Start of content or new tag.
          parse_element(input.byte_slice(mark, i - mark))
          i += 1
          mark = i
          in_tag = false
        else
          i += 1
        end
      end
    end

    # ---------- viewBox scaling / gradient resolution ----------

    private def image_bounds : Array(Float32)
      bounds = Array(Float32).new(4, 0.0f32)
      first = @image.shapes.first?
      return bounds unless first
      bounds[0] = first.bounds[0]
      bounds[1] = first.bounds[1]
      bounds[2] = first.bounds[2]
      bounds[3] = first.bounds[3]
      @image.shapes.skip(1).each do |shape|
        bounds[0] = minf(bounds[0], shape.bounds[0])
        bounds[1] = minf(bounds[1], shape.bounds[1])
        bounds[2] = maxf(bounds[2], shape.bounds[2])
        bounds[3] = maxf(bounds[3], shape.bounds[3])
      end
      bounds
    end

    private def view_align(content : Float32, container : Float32, type : Int32) : Float32
      if type == ALIGN_MIN
        0.0f32
      elsif type == ALIGN_MAX
        container - content
      else
        (container - content) * 0.5f32
      end
    end

    private def scale_gradient(grad : Gradient, tx : Float32, ty : Float32, sx : Float32, sy : Float32)
      grad.xform = xform_multiply(grad.xform, xform_translation(tx, ty))
      grad.xform = xform_multiply(grad.xform, xform_scale(sx, sy))
    end

    def scale_to_viewbox(units : String)
      # Guess image size if not set completely.
      bounds = image_bounds

      if @view_width == 0
        if @image.width > 0
          @view_width = @image.width
        else
          @view_min_x = bounds[0]
          @view_width = bounds[2] - bounds[0]
        end
      end
      if @view_height == 0
        if @image.height > 0
          @view_height = @image.height
        else
          @view_min_y = bounds[1]
          @view_height = bounds[3] - bounds[1]
        end
      end
      @image.width = @view_width if @image.width == 0
      @image.height = @view_height if @image.height == 0

      tx = -@view_min_x
      ty = -@view_min_y
      sx = @view_width > 0 ? @image.width / @view_width : 0.0f32
      sy = @view_height > 0 ? @image.height / @view_height : 0.0f32
      # Unit scaling
      us = 1.0f32 / convert_to_pixels(Coordinate.new(1.0f32, parse_units(units)), 0.0f32, 1.0f32)

      # Fix aspect ratio
      if @align_type == ALIGN_MEET
        # fit whole image into viewbox
        sx = sy = minf(sx, sy)
        tx += view_align(@view_width*sx, @image.width, @align_x) / sx
        ty += view_align(@view_height*sy, @image.height, @align_y) / sy
      elsif @align_type == ALIGN_SLICE
        # fill whole viewbox with image
        sx = sy = maxf(sx, sy)
        tx += view_align(@view_width*sx, @image.width, @align_x) / sx
        ty += view_align(@view_height*sy, @image.height, @align_y) / sy
      end

      # Transform
      sx *= us
      sy *= us
      avgs = (sx+sy) / 2.0f32
      @image.shapes.each do |shape|
        shape.bounds[0] = (shape.bounds[0] + tx) * sx
        shape.bounds[1] = (shape.bounds[1] + ty) * sy
        shape.bounds[2] = (shape.bounds[2] + tx) * sx
        shape.bounds[3] = (shape.bounds[3] + ty) * sy
        shape.paths.each do |path|
          path.bounds[0] = (path.bounds[0] + tx) * sx
          path.bounds[1] = (path.bounds[1] + ty) * sy
          path.bounds[2] = (path.bounds[2] + tx) * sx
          path.bounds[3] = (path.bounds[3] + ty) * sy
          k = 0
          while k < path.pts.size
            path.pts[k] = (path.pts[k] + tx) * sx
            path.pts[k+1] = (path.pts[k+1] + ty) * sy
            k += 2
          end
        end

        if shape.fill.type.linear? || shape.fill.type.radial?
          if grad = shape.fill.gradient
            scale_gradient(grad, tx, ty, sx, sy)
            t = grad.xform.dup
            # NOTE(port): on a degenerate matrix C leaves grad.xform unchanged.
            grad.xform = xform_inverse(t) || grad.xform
          end
        end
        if shape.stroke.type.linear? || shape.stroke.type.radial?
          if grad = shape.stroke.gradient
            scale_gradient(grad, tx, ty, sx, sy)
            t = grad.xform.dup
            grad.xform = xform_inverse(t) || grad.xform
          end
        end

        shape.stroke_width *= avgs
        shape.stroke_dash_offset *= avgs
        shape.stroke_dash_count.times do |k|
          shape.stroke_dash_array[k] *= avgs
        end
      end
    end

    def create_gradients
      @image.shapes.each do |shape|
        if shape.fill.type.undef?
          unless shape.fill_gradient_id.empty?
            inv = xform_inverse(shape.xform)
            if inv.nil?
              # NOTE(port): C resets the *source* xform to identity here and
              # reads uninitialized memory for inv; we use identity instead.
              shape.xform = xform_identity
              inv = xform_identity
            end
            local_bounds = get_local_bounds(shape, inv)
            if (result = create_gradient(shape.fill_gradient_id, local_bounds, shape.xform))
              paint = shape.fill
              paint.gradient = result[0]
              paint.type = result[1]
              shape.fill = paint
            end
          end
          if shape.fill.type.undef?
            paint = shape.fill
            paint.type = PaintType::NONE
            shape.fill = paint
          end
        end
        if shape.stroke.type.undef?
          unless shape.stroke_gradient_id.empty?
            inv = xform_inverse(shape.xform)
            if inv.nil?
              shape.xform = xform_identity
              inv = xform_identity
            end
            local_bounds = get_local_bounds(shape, inv)
            if (result = create_gradient(shape.stroke_gradient_id, local_bounds, shape.xform))
              paint = shape.stroke
              paint.gradient = result[0]
              paint.type = result[1]
              shape.stroke = paint
            end
          end
          if shape.stroke.type.undef?
            paint = shape.stroke
            paint.type = PaintType::NONE
            shape.stroke = paint
          end
        end
      end
    end
  end
end
