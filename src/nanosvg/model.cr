# Data model shared by the parser and the rasterizer.
# Mirrors the C structs from nanosvg.h (NSVGimage/NSVGshape/NSVGpath/NSVGpaint...)
# but uses Crystal classes/arrays instead of linked lists and raw pointers.
#
# NOTE(port): xforms/bounds/dash arrays use Array(Float32) instead of the C
# float[6] so they can be mutated in place through properties.

module NanoSVG
  enum PaintType : Int8
    UNDEF    = -1 # used by the parser while a gradient is not yet resolved
    NONE     =  0
    COLOR    =  1
    LINEAR   =  2 # linear gradient
    RADIAL   =  3 # radial gradient
  end

  enum SpreadType : Int8
    PAD     = 0
    REFLECT = 1
    REPEAT  = 2
  end

  enum LineJoin : Int8
    MITER  = 0
    ROUND  = 1
    BEVEL  = 2
  end

  enum LineCap : Int8
    BUTT   = 0
    ROUND  = 1
    SQUARE = 2
  end

  enum FillRule : Int8
    NONZERO  = 0
    EVENODD  = 1
  end

  FLAGS_VISIBLE = 0x01u8

  # Paint order fields (3x2-bit encoded in Shape#paint_order).
  PAINT_FILL     = 0x00u8
  PAINT_MARKERS  = 0x01u8
  PAINT_STROKE   = 0x02u8

  struct GradientStop
    # Color in the same bit layout as C NanoSVG: 0xAABBGGRR
    # (R in the low byte, A in the high byte).
    property color : UInt32
    property offset : Float32

    def initialize(@color = 0u32, @offset = 0.0f32)
    end
  end

  # NOTE(port): class (not struct) so gradients stored in Paint can be
  # mutated in place by the parser/rasterizer.
  class Gradient
    # Inverse transform from screen pixels to gradient space (0..1).
    property xform : Array(Float32)
    property spread : SpreadType
    property fx : Float32
    property fy : Float32
    property stops : Array(GradientStop)

    def initialize
      @xform = Array(Float32).new(6, 0.0f32)
      @spread = SpreadType::PAD
      @fx = 0.0f32
      @fy = 0.0f32
      @stops = [] of GradientStop
    end
  end

  struct Paint
    property type : PaintType
    property color : UInt32
    property gradient : Gradient?

    def initialize
      @type = PaintType::NONE
      @color = 0u32
      @gradient = nil
    end

    # Convenience constructors
    def self.none : Paint
      p = new
      p.type = PaintType::NONE
      p
    end

    def self.solid(color : UInt32) : Paint
      p = new
      p.type = PaintType::COLOR
      p.color = color
      p
    end

    def self.gradient(type : PaintType, g : Gradient) : Paint
      p = new
      p.type = type
      p.gradient = g
      p
    end
  end

  class Path
    # Cubic bezier points: x0,y0, [cpx1,cpy1,cpx2,cpy2,x1,y1], ...
    # (npts-1) must be divisible by 3.
    property pts : Array(Float32)

    # Flag indicating if shapes should be treated as closed.
    property closed : Bool

    # Tight bounding box of the path [minx,miny,maxx,maxy].
    property bounds : Array(Float32)

    def initialize
      @pts = [] of Float32
      @closed = false
      @bounds = Array(Float32).new(4, 0.0f32)
    end

    def npts : Int32
      pts.size // 2
    end

    # Equivalent of nsvgDuplicatePath.
    def dup : Path
      p = Path.new
      p.pts = @pts.dup
      p.closed = @closed
      p.bounds = @bounds.dup
      p
    end
  end

  class Shape
    # Optional 'id' attr of the shape or its group
    property id : String

    property fill : Paint
    property stroke : Paint

    # Opacity of the shape.
    property opacity : Float32

    # Stroke width (scaled).
    property stroke_width : Float32

    # Stroke dash offset (scaled).
    property stroke_dash_offset : Float32

    # Stroke dash array (scaled).
    property stroke_dash_array : Array(Float32)
    property stroke_dash_count : Int32

    property stroke_line_join : LineJoin
    property stroke_line_cap : LineCap

    # Miter limit
    property miter_limit : Float32

    property fill_rule : FillRule

    # Encoded paint order (3x2-bit fields)
    property paint_order : UInt8

    # Logical or of FLAGS_* flags
    property flags : UInt8

    # Tight bounding box of the shape [minx,miny,maxx,maxy].
    property bounds : Array(Float32)

    # Optional 'id' of fill/stroke gradient
    property fill_gradient_id : String
    property stroke_gradient_id : String

    # Root transformation for fill/stroke gradient
    property xform : Array(Float32)

    property paths : Array(Path)

    def initialize
      @id = ""
      @fill = Paint.new
      @stroke = Paint.new
      @opacity = 1.0f32
      @stroke_width = 1.0f32
      @stroke_dash_offset = 0.0f32
      @stroke_dash_array = Array(Float32).new(8, 0.0f32)
      @stroke_dash_count = 0
      @stroke_line_join = LineJoin::MITER
      @stroke_line_cap = LineCap::BUTT
      @miter_limit = 4.0f32
      @fill_rule = FillRule::NONZERO
      @paint_order = 0u8
      @flags = FLAGS_VISIBLE
      @bounds = Array(Float32).new(4, 0.0f32)
      @fill_gradient_id = ""
      @stroke_gradient_id = ""
      @xform = Array(Float32).new(6, 0.0f32)
      @paths = [] of Path
    end

    def visible? : Bool
      (flags & FLAGS_VISIBLE) != 0
    end
  end

  class Image
    property width : Float32
    property height : Float32
    property shapes : Array(Shape)

    def initialize(@width = 0.0f32, @height = 0.0f32)
      @shapes = [] of Shape
    end
  end
end
