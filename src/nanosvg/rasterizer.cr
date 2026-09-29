# Crystal port of nanosvgrast.h — the NanoSVG rasterizer.
#
# Ported from C (https://github.com/memononen/nanosvg), Copyright (c) 2013-14
# Mikko Mononen (memon@inside.org), zlib license. The polygon rasterization
# is heavily based on stb_truetype rasterizer by Sean Barrett.
#
# The rasterizer is not particularly fast or accurate, but it's small.
# It renders flat filled shapes (with anti-aliasing), strokes (caps, joins,
# dashes) and linear/radial gradients into a non-premultiplied RGBA buffer.
#
# NOTE(port): the C memory pool (NSVGmemPage) and the active-edge freelist
# are replaced by plain GC allocations; the algorithms are unchanged.

require "./model"

module NanoSVG
  SUBSAMPLES = 5
  FIXSHIFT   = 10
  FIX        = 1 << FIXSHIFT
  FIXMASK    = FIX - 1

  # NSVGpointFlags
  private PT_CORNER = 0x01u8
  private PT_BEVEL  = 0x02u8
  private PT_LEFT   = 0x04u8

  private class Edge
    property x0 : Float32
    property y0 : Float32
    property x1 : Float32
    property y1 : Float32
    property dir : Int32

    def initialize(@x0, @y0, @x1, @y1, @dir)
    end
  end

  private class RPoint
    property x : Float32
    property y : Float32
    property dx : Float32 = 0.0f32
    property dy : Float32 = 0.0f32
    property len : Float32 = 0.0f32
    property dmx : Float32 = 0.0f32
    property dmy : Float32 = 0.0f32
    property flags : UInt8 = 0u8

    def initialize(@x = 0.0f32, @y = 0.0f32, @flags = 0u8)
    end

    def copy : RPoint
      p = RPoint.new(@x, @y, @flags)
      p.dx = @dx
      p.dy = @dy
      p.len = @len
      p.dmx = @dmx
      p.dmy = @dmy
      p
    end
  end

  private class ActiveEdge
    property x : Int32
    property dx : Int32
    property ey : Float32
    property dir : Int32
    property next : ActiveEdge?

    def initialize(@x, @dx, @ey, @dir)
      @next = nil
    end
  end

  private class CachedPaint
    property type : PaintType = PaintType::NONE
    property spread : SpreadType = SpreadType::PAD
    property xform : Array(Float32) = Array(Float32).new(6, 0.0f32)
    property colors : Array(UInt32) = Array(UInt32).new(256, 0u32)
  end

  class Rasterizer
    PI = 3.14159265358979323846264338327f32

    @tess_tol : Float32 = 0.25f32
    @dist_tol : Float32 = 0.01f32

    @edges : Array(Edge) = [] of Edge
    @points : Array(RPoint) = [] of RPoint
    @points2 : Array(RPoint) = [] of RPoint

    @scanline : Array(UInt8) = [] of UInt8

    @bitmap : Bytes = Bytes.new(0)
    @width : Int32 = 0
    @height : Int32 = 0
    @stride : Int32 = 0

    # Rasterizes an SVG image into a caller-provided RGBA buffer.
    #   image  - parsed image (see NanoSVG.parse)
    #   tx, ty - image offset (applied after scaling)
    #   scale  - image scale
    #   dst    - destination buffer, 4 bytes per pixel (RGBA)
    #   stride - number of bytes per scanline in the destination buffer
    def rasterize(image : Image, tx : Float32, ty : Float32, scale : Float32,
                  dst : Bytes, w : Int32, h : Int32, stride : Int32) : Nil
      @bitmap = dst
      @width = w
      @height = h
      @stride = stride

      if w > @scanline.size
        @scanline = Array(UInt8).new(w, 0u8)
      end

      h.times do |i|
        (i*stride ... i*stride + w*4).each { |k| dst[k] = 0u8 }
      end

      image.shapes.each do |shape|
        next unless (shape.flags & FLAGS_VISIBLE) != 0

        3.times do |j|
          paint_order = (shape.paint_order >> (2 * j)) & 0x03u8

          if paint_order == PAINT_FILL && shape.fill.type != PaintType::NONE
            @edges.clear
            flatten_shape(shape, scale)

            # Scale and translate edges
            @edges.each do |e|
              e.x0 = tx + e.x0
              e.y0 = (ty + e.y0) * SUBSAMPLES
              e.x1 = tx + e.x1
              e.y1 = (ty + e.y1) * SUBSAMPLES
            end

            # Rasterize edges
            @edges.sort! { |a, b| a.y0 < b.y0 ? -1 : (a.y0 > b.y0 ? 1 : 0) } unless @edges.empty?

            cache = CachedPaint.new
            init_paint(cache, shape.fill, shape.opacity)
            rasterize_sorted_edges(tx, ty, scale, cache, shape.fill_rule)
          end

          if paint_order == PAINT_STROKE && shape.stroke.type != PaintType::NONE && (shape.stroke_width * scale) > 0.01f32
            @edges.clear
            flatten_shape_stroke(shape, scale)

            # Scale and translate edges
            @edges.each do |e|
              e.x0 = tx + e.x0
              e.y0 = (ty + e.y0) * SUBSAMPLES
              e.x1 = tx + e.x1
              e.y1 = (ty + e.y1) * SUBSAMPLES
            end

            @edges.sort! { |a, b| a.y0 < b.y0 ? -1 : (a.y0 > b.y0 ? 1 : 0) } unless @edges.empty?

            cache = CachedPaint.new
            init_paint(cache, shape.stroke, shape.opacity)
            # strokes always use the non-zero winding rule
            rasterize_sorted_edges(tx, ty, scale, cache, FillRule::NONZERO)
          end
        end
      end

      unpremultiply_alpha(dst, w, h, stride)

      @bitmap = Bytes.new(0)
      @width = 0
      @height = 0
      @stride = 0
    end

    # Convenience overload: allocates an RGBA buffer of w*h*4 (stride = w*4)
    # and returns it (non-premultiplied alpha).
    def rasterize(image : Image, tx : Float32, ty : Float32, scale : Float32,
                  w : Int32, h : Int32) : Bytes
      dst = Bytes.new(w*h*4)
      rasterize(image, tx, ty, scale, dst, w, h, w*4)
      dst
    end

    # One-shot convenience (creates a throwaway rasterizer context).
    def self.rasterize(image : Image, tx : Float32, ty : Float32, scale : Float32,
                       w : Int32, h : Int32) : Bytes
      Rasterizer.new.rasterize(image, tx, ty, scale, w, h)
    end

    # ---------- point/edge accumulation ----------

    private def pt_equals?(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32, tol : Float32) : Bool
      dx = x2 - x1
      dy = y2 - y1
      dx*dx + dy*dy < tol*tol
    end

    private def add_path_point(x : Float32, y : Float32, flags : UInt8)
      if !@points.empty?
        pt = @points.last
        if pt_equals?(pt.x, pt.y, x, y, @dist_tol)
          pt.flags = pt.flags | flags
          return
        end
      end
      @points << RPoint.new(x, y, flags)
    end

    private def append_path_point(pt : RPoint)
      @points << pt
    end

    private def duplicate_points
      # points2 is only read (never mutated) during dashing.
      @points2 = @points.dup
    end

    private def add_edge(x0 : Float32, y0 : Float32, x1 : Float32, y1 : Float32)
      # Skip horizontal edges
      return if y0 == y1

      if y0 < y1
        @edges << Edge.new(x0, y0, x1, y1, 1)
      else
        @edges << Edge.new(x1, y1, x0, y0, -1)
      end
    end

    private def normalize(x : Float32, y : Float32) : {Float32, Float32, Float32}
      # returns {len, nx, ny}
      d = Math.sqrt((x*x + y*y).to_f64).to_f32
      if d > 1e-6f32
        id = 1.0f32 / d
        x = x * id
        y = y * id
      end
      {d, x, y}
    end

    private def absf(x : Float32) : Float32
      x < 0 ? -x : x
    end

    private def roundf(x : Float32) : Float32
      if x >= 0
        (x + 0.5f32).floor
      else
        (x - 0.5f32).ceil
      end
    end

    private def flatten_cubic_bez(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32,
                                  x3 : Float32, y3 : Float32, x4 : Float32, y4 : Float32,
                                  level : Int32, type : UInt8)
      return if level > 10

      x12 = (x1+x2)*0.5f32
      y12 = (y1+y2)*0.5f32
      x23 = (x2+x3)*0.5f32
      y23 = (y2+y3)*0.5f32
      x34 = (x3+x4)*0.5f32
      y34 = (y3+y4)*0.5f32
      x123 = (x12+x23)*0.5f32
      y123 = (y12+y23)*0.5f32

      dx = x4 - x1
      dy = y4 - y1
      d2 = absf((x2 - x4) * dy - (y2 - y4) * dx)
      d3 = absf((x3 - x4) * dy - (y3 - y4) * dx)

      if (d2 + d3)*(d2 + d3) < @tess_tol * (dx*dx + dy*dy)
        add_path_point(x4, y4, type)
        return
      end

      x234 = (x23+x34)*0.5f32
      y234 = (y23+y34)*0.5f32
      x1234 = (x123+x234)*0.5f32
      y1234 = (y123+y234)*0.5f32

      flatten_cubic_bez(x1, y1, x12, y12, x123, y123, x1234, y1234, level+1, 0u8)
      flatten_cubic_bez(x1234, y1234, x234, y234, x34, y34, x4, y4, level+1, type)
    end

    private def flatten_shape(shape : Shape, scale : Float32)
      shape.paths.each do |path|
        @points.clear
        # Flatten path
        add_path_point(path.pts[0]*scale, path.pts[1]*scale, 0u8)
        n = path.npts
        i = 0
        while i < n - 1
          p = i*2
          flatten_cubic_bez(
            path.pts[p]*scale, path.pts[p+1]*scale,
            path.pts[p+2]*scale, path.pts[p+3]*scale,
            path.pts[p+4]*scale, path.pts[p+5]*scale,
            path.pts[p+6]*scale, path.pts[p+7]*scale,
            0, 0u8)
          i += 3
        end
        # Close path
        add_path_point(path.pts[0]*scale, path.pts[1]*scale, 0u8)
        # Build edges
        j = @points.size - 1
        i = 0
        while i < @points.size
          add_edge(@points[j].x, @points[j].y, @points[i].x, @points[i].y)
          j = i
          i += 1
        end
      end
    end

    # ---------- stroke ----------

    private def init_closed(left : RPoint, right : RPoint, p0 : RPoint, p1 : RPoint, line_width : Float32)
      w = line_width * 0.5f32
      dx = p1.x - p0.x
      dy = p1.y - p0.y
      len, dx, dy = normalize(dx, dy)
      px = p0.x + dx*len*0.5f32
      py = p0.y + dy*len*0.5f32
      dlx = dy
      dly = -dx
      left.x = px - dlx*w
      left.y = py - dly*w
      right.x = px + dlx*w
      right.y = py + dly*w
    end

    private def butt_cap(left : RPoint, right : RPoint, p : RPoint, dx : Float32, dy : Float32, line_width : Float32, connect : Bool)
      w = line_width * 0.5f32
      px = p.x
      py = p.y
      dlx = dy
      dly = -dx
      lx = px - dlx*w
      ly = py - dly*w
      rx = px + dlx*w
      ry = py + dly*w

      add_edge(lx, ly, rx, ry)

      if connect
        add_edge(left.x, left.y, lx, ly)
        add_edge(rx, ry, right.x, right.y)
      end
      left.x = lx
      left.y = ly
      right.x = rx
      right.y = ry
    end

    private def square_cap(left : RPoint, right : RPoint, p : RPoint, dx : Float32, dy : Float32, line_width : Float32, connect : Bool)
      w = line_width * 0.5f32
      px = p.x - dx*w
      py = p.y - dy*w
      dlx = dy
      dly = -dx
      lx = px - dlx*w
      ly = py - dly*w
      rx = px + dlx*w
      ry = py + dly*w

      add_edge(lx, ly, rx, ry)

      if connect
        add_edge(left.x, left.y, lx, ly)
        add_edge(rx, ry, right.x, right.y)
      end
      left.x = lx
      left.y = ly
      right.x = rx
      right.y = ry
    end

    private def round_cap(left : RPoint, right : RPoint, p : RPoint, dx : Float32, dy : Float32, line_width : Float32, ncap : Int32, connect : Bool)
      w = line_width * 0.5f32
      px = p.x
      py = p.y
      dlx = dy
      dly = -dx
      lx = 0.0f32
      ly = 0.0f32
      rx = 0.0f32
      ry = 0.0f32
      prevx = 0.0f32
      prevy = 0.0f32

      ncap.times do |i|
        a = i.to_f32/(ncap-1).to_f32*PI
        ax = Math.cos(a.to_f64).to_f32 * w
        ay = Math.sin(a.to_f64).to_f32 * w
        x = px - dlx*ax - dx*ay
        y = py - dly*ax - dy*ay

        add_edge(prevx, prevy, x, y) if i > 0

        prevx = x
        prevy = y

        if i == 0
          lx = x
          ly = y
        elsif i == ncap-1
          rx = x
          ry = y
        end
      end

      if connect
        add_edge(left.x, left.y, lx, ly)
        add_edge(rx, ry, right.x, right.y)
      end

      left.x = lx
      left.y = ly
      right.x = rx
      right.y = ry
    end

    private def bevel_join(left : RPoint, right : RPoint, p0 : RPoint, p1 : RPoint, line_width : Float32)
      w = line_width * 0.5f32
      dlx0 = p0.dy
      dly0 = -p0.dx
      dlx1 = p1.dy
      dly1 = -p1.dx
      lx0 = p1.x - (dlx0 * w)
      ly0 = p1.y - (dly0 * w)
      rx0 = p1.x + (dlx0 * w)
      ry0 = p1.y + (dly0 * w)
      lx1 = p1.x - (dlx1 * w)
      ly1 = p1.y - (dly1 * w)
      rx1 = p1.x + (dlx1 * w)
      ry1 = p1.y + (dly1 * w)

      add_edge(lx0, ly0, left.x, left.y)
      add_edge(lx1, ly1, lx0, ly0)

      add_edge(right.x, right.y, rx0, ry0)
      add_edge(rx0, ry0, rx1, ry1)

      left.x = lx1
      left.y = ly1
      right.x = rx1
      right.y = ry1
    end

    private def miter_join(left : RPoint, right : RPoint, p0 : RPoint, p1 : RPoint, line_width : Float32)
      w = line_width * 0.5f32
      dlx0 = p0.dy
      dly0 = -p0.dx
      dlx1 = p1.dy
      dly1 = -p1.dx

      if (p1.flags & PT_LEFT) != 0
        lx0 = lx1 = p1.x - p1.dmx * w
        ly0 = ly1 = p1.y - p1.dmy * w
        add_edge(lx1, ly1, left.x, left.y)

        rx0 = p1.x + (dlx0 * w)
        ry0 = p1.y + (dly0 * w)
        rx1 = p1.x + (dlx1 * w)
        ry1 = p1.y + (dly1 * w)
        add_edge(right.x, right.y, rx0, ry0)
        add_edge(rx0, ry0, rx1, ry1)
      else
        lx0 = p1.x - (dlx0 * w)
        ly0 = p1.y - (dly0 * w)
        lx1 = p1.x - (dlx1 * w)
        ly1 = p1.y - (dly1 * w)
        add_edge(lx0, ly0, left.x, left.y)
        add_edge(lx1, ly1, lx0, ly0)

        rx0 = rx1 = p1.x + p1.dmx * w
        ry0 = ry1 = p1.y + p1.dmy * w
        add_edge(right.x, right.y, rx1, ry1)
      end

      left.x = lx1
      left.y = ly1
      right.x = rx1
      right.y = ry1
    end

    private def round_join(left : RPoint, right : RPoint, p0 : RPoint, p1 : RPoint, line_width : Float32, ncap : Int32)
      w = line_width * 0.5f32
      dlx0 = p0.dy
      dly0 = -p0.dx
      dlx1 = p1.dy
      dly1 = -p1.dx
      a0 = Math.atan2(dly0.to_f64, dlx0.to_f64).to_f32
      a1 = Math.atan2(dly1.to_f64, dlx1.to_f64).to_f32
      da = a1 - a0

      da += PI*2 if da < PI
      da -= PI*2 if da > PI

      n = ((absf(da) / PI) * ncap.to_f32).ceil.to_i32
      n = 2 if n < 2
      n = ncap if n > ncap

      lx = left.x
      ly = left.y
      rx = right.x
      ry = right.y

      n.times do |i|
        u = i.to_f32/(n-1).to_f32
        a = a0 + u*da
        ax = Math.cos(a.to_f64).to_f32 * w
        ay = Math.sin(a.to_f64).to_f32 * w
        lx1 = p1.x - ax
        ly1 = p1.y - ay
        rx1 = p1.x + ax
        ry1 = p1.y + ay

        add_edge(lx1, ly1, lx, ly)
        add_edge(rx, ry, rx1, ry1)

        lx = lx1
        ly = ly1
        rx = rx1
        ry = ry1
      end

      left.x = lx
      left.y = ly
      right.x = rx
      right.y = ry
    end

    private def straight_join(left : RPoint, right : RPoint, p1 : RPoint, line_width : Float32)
      w = line_width * 0.5f32
      lx = p1.x - (p1.dmx * w)
      ly = p1.y - (p1.dmy * w)
      rx = p1.x + (p1.dmx * w)
      ry = p1.y + (p1.dmy * w)

      add_edge(lx, ly, left.x, left.y)
      add_edge(right.x, right.y, rx, ry)

      left.x = lx
      left.y = ly
      right.x = rx
      right.y = ry
    end

    private def curve_divs(r : Float32, arc : Float32, tol : Float32) : Int32
      da = Math.acos((r / (r + tol)).to_f64).to_f32 * 2.0f32
      divs = (arc / da).ceil.to_i32
      divs = 2 if divs < 2
      divs
    end

    private def expand_stroke(points : Array(RPoint), closed : Bool,
                              line_join : LineJoin, line_cap : LineCap, line_width : Float32)
      ncap = curve_divs(line_width*0.5f32, PI, @tess_tol) # divisions per half circle
      left = RPoint.new
      right = RPoint.new
      first_left = RPoint.new
      first_right = RPoint.new
      npoints = points.size

      # Build stroke edges
      if closed
        # Looping
        i0 = npoints - 1
        i1 = 0
        s_idx = 0
        e_idx = npoints
      else
        # Add cap
        i0 = 0
        i1 = 1
        s_idx = 1
        e_idx = npoints - 1
      end

      if closed
        init_closed(left, right, points[i0], points[i1], line_width)
        first_left.x = left.x
        first_left.y = left.y
        first_right.x = right.x
        first_right.y = right.y
      else
        # Add cap
        p0 = points[i0]
        p1 = points[i1]
        dx = p1.x - p0.x
        dy = p1.y - p0.y
        _, dx, dy = normalize(dx, dy)
        butt_cap(left, right, p0, dx, dy, line_width, false) if line_cap.butt?
        square_cap(left, right, p0, dx, dy, line_width, false) if line_cap.square?
        round_cap(left, right, p0, dx, dy, line_width, ncap, false) if line_cap.round?
      end

      j = s_idx
      while j < e_idx
        p0 = points[i0]
        p1 = points[i1]
        if (p1.flags & PT_CORNER) != 0
          if line_join.round?
            round_join(left, right, p0, p1, line_width, ncap)
          elsif line_join.bevel? || (p1.flags & PT_BEVEL) != 0
            bevel_join(left, right, p0, p1, line_width)
          else
            miter_join(left, right, p0, p1, line_width)
          end
        else
          straight_join(left, right, p1, line_width)
        end
        i0 = i1
        i1 += 1
        j += 1
      end

      if closed
        # Loop it
        add_edge(first_left.x, first_left.y, left.x, left.y)
        add_edge(right.x, right.y, first_right.x, first_right.y)
      else
        # Add cap
        p0 = points[i0]
        p1 = points[i1]
        dx = p1.x - p0.x
        dy = p1.y - p0.y
        _, dx, dy = normalize(dx, dy)
        butt_cap(right, left, p1, -dx, -dy, line_width, true) if line_cap.butt?
        square_cap(right, left, p1, -dx, -dy, line_width, true) if line_cap.square?
        round_cap(right, left, p1, -dx, -dy, line_width, ncap, true) if line_cap.round?
      end
    end

    private def prepare_stroke(miter_limit : Float32, line_join : LineJoin)
      npoints = @points.size
      # Calculate segment directions and lengths
      i0 = npoints - 1
      i1 = 0
      npoints.times do
        p0 = @points[i0]
        p1 = @points[i1]
        # Calculate segment direction and length
        p0.dx = p1.x - p0.x
        p0.dy = p1.y - p0.y
        p0.len, p0.dx, p0.dy = normalize(p0.dx, p0.dy)
        # Advance
        i0 = i1
        i1 += 1
      end

      # Calculate joins
      i0 = npoints - 1
      i1 = 0
      npoints.times do
        p0 = @points[i0]
        p1 = @points[i1]
        dlx0 = p0.dy
        dly0 = -p0.dx
        dlx1 = p1.dy
        dly1 = -p1.dx
        # Calculate extrusions
        p1.dmx = (dlx0 + dlx1) * 0.5f32
        p1.dmy = (dly0 + dly1) * 0.5f32
        dmr2 = p1.dmx*p1.dmx + p1.dmy*p1.dmy
        if dmr2 > 0.000001f32
          s2 = 1.0f32 / dmr2
          s2 = 600.0f32 if s2 > 600.0f32
          p1.dmx *= s2
          p1.dmy *= s2
        end

        # Clear flags, but keep the corner.
        p1.flags = (p1.flags & PT_CORNER) != 0 ? PT_CORNER : 0u8

        # Keep track of left turns.
        cross = p1.dx * p0.dy - p0.dx * p1.dy
        p1.flags |= PT_LEFT if cross > 0.0f32

        # Check to see if the corner needs to be beveled.
        if (p1.flags & PT_CORNER) != 0
          if (dmr2 * miter_limit*miter_limit) < 1.0f32 || line_join.bevel? || line_join.round?
            p1.flags |= PT_BEVEL
          end
        end

        i0 = i1
        i1 += 1
      end
    end

    private def flatten_shape_stroke(shape : Shape, scale : Float32)
      miter_limit = shape.miter_limit
      line_join = shape.stroke_line_join
      line_cap = shape.stroke_line_cap
      line_width = shape.stroke_width * scale

      shape.paths.each do |path|
        # Flatten path
        @points.clear
        add_path_point(path.pts[0]*scale, path.pts[1]*scale, PT_CORNER)
        n = path.npts
        i = 0
        while i < n - 1
          p = i*2
          flatten_cubic_bez(
            path.pts[p]*scale, path.pts[p+1]*scale,
            path.pts[p+2]*scale, path.pts[p+3]*scale,
            path.pts[p+4]*scale, path.pts[p+5]*scale,
            path.pts[p+6]*scale, path.pts[p+7]*scale,
            0, PT_CORNER)
          i += 3
        end
        next if @points.size < 2

        closed = path.closed

        # If the first and last points are the same, remove the last, mark
        # as closed path.
        if pt_equals?(@points.last.x, @points.last.y, @points[0].x, @points[0].y, @dist_tol)
          @points.pop
          closed = true
        end

        if shape.stroke_dash_count > 0
          idash = 0
          dash_state = true
          total_dist = 0.0f32

          append_path_point(@points[0].copy) if closed

          # Duplicate points -> points2.
          duplicate_points

          @points.clear
          cur = @points2[0].copy
          append_path_point(cur.copy)

          # Figure out dash offset.
          all_dash_len = 0.0f32
          shape.stroke_dash_count.times do |k|
            all_dash_len += shape.stroke_dash_array[k]
          end
          all_dash_len *= 2.0f32 if shape.stroke_dash_count.odd?
          # Find location inside pattern
          dash_offset = shape.stroke_dash_offset % all_dash_len
          dash_offset += all_dash_len if dash_offset < 0.0f32

          while dash_offset > shape.stroke_dash_array[idash]
            dash_offset -= shape.stroke_dash_array[idash]
            idash = (idash + 1) % shape.stroke_dash_count
          end
          dash_len = (shape.stroke_dash_array[idash] - dash_offset) * scale

          j = 1
          while j < @points2.size
            dx = @points2[j].x - cur.x
            dy = @points2[j].y - cur.y
            dist = Math.sqrt((dx*dx + dy*dy).to_f64).to_f32

            if (total_dist + dist) > dash_len
              # Calculate intermediate point
              d = (dash_len - total_dist) / dist
              x = cur.x + dx * d
              y = cur.y + dy * d
              add_path_point(x, y, PT_CORNER)

              # Stroke
              if @points.size > 1 && dash_state
                prepare_stroke(miter_limit, line_join)
                expand_stroke(@points, false, line_join, line_cap, line_width)
              end
              # Advance dash pattern
              dash_state = !dash_state
              idash = (idash+1) % shape.stroke_dash_count
              dash_len = shape.stroke_dash_array[idash] * scale
              # Restart
              cur.x = x
              cur.y = y
              cur.flags = PT_CORNER
              total_dist = 0.0f32
              @points.clear
              append_path_point(cur.copy)
            else
              total_dist += dist
              cur = @points2[j].copy
              append_path_point(cur.copy)
              j += 1
            end
          end
          # Stroke any leftover path
          if @points.size > 1 && dash_state
            prepare_stroke(miter_limit, line_join)
            expand_stroke(@points, false, line_join, line_cap, line_width)
          end
        else
          prepare_stroke(miter_limit, line_join)
          expand_stroke(@points, closed, line_join, line_cap, line_width)
        end
      end
    end

    # ---------- scanline rasterization ----------

    private def add_active(e : Edge, start_point : Float32) : ActiveEdge
      dxdy = (e.x1 - e.x0) / (e.y1 - e.y0)
      # round dx down to avoid going too far
      if dxdy < 0
        dx = (-roundf(FIX.to_f32 * -dxdy)).to_i32
      else
        dx = roundf(FIX.to_f32 * dxdy).to_i32
      end
      x = roundf(FIX.to_f32 * (e.x0 + dxdy * (start_point - e.y0))).to_i32
      ActiveEdge.new(x, dx, e.y1, e.dir)
    end

    private def fill_scanline(scanline : Array(UInt8), len : Int32, x0 : Int32, x1 : Int32,
                              max_weight : Int32, mm : Array(Int32))
      # mm = [xmin, xmax]
      i = x0 >> FIXSHIFT
      j = x1 >> FIXSHIFT
      mm[0] = i if i < mm[0]
      mm[1] = j if j > mm[1]
      if i < len && j >= 0
        if i == j
          # x0,x1 are the same pixel, so compute combined coverage
          v = ((x1 - x0) &* max_weight) >> FIXSHIFT
          scanline[i] = scanline[i] &+ v.to_u8!
        else
          if i >= 0 # add antialiasing for x0
            v = ((FIX - (x0 & FIXMASK)) &* max_weight) >> FIXSHIFT
            scanline[i] = scanline[i] &+ v.to_u8!
          else
            i = -1 # clip
          end

          if j < len # add antialiasing for x1
            v = ((x1 & FIXMASK) &* max_weight) >> FIXSHIFT
            scanline[j] = scanline[j] &+ v.to_u8!
          else
            j = len # clip
          end

          k = i + 1
          while k < j # fill pixels between x0 and x1
            scanline[k] = scanline[k] &+ max_weight.to_u8!
            k += 1
          end
        end
      end
    end

    # note: this routine clips fills that extend off the edges... ideally this
    # wouldn't happen, but it could happen if the truetype glyph bounding boxes
    # are wrong, or if the user supplies a too-small bitmap
    private def fill_active_edges(scanline : Array(UInt8), len : Int32, e : ActiveEdge?,
                                  max_weight : Int32, mm : Array(Int32), fill_rule : FillRule)
      # non-zero winding fill
      x0 = 0
      w = 0

      if fill_rule.nonzero?
        # Non-zero
        while e
          if w == 0
            # if we're currently at zero, we need to record the edge start point
            x0 = e.not_nil!.x
            w += e.not_nil!.dir
          else
            x1 = e.not_nil!.x
            w += e.not_nil!.dir
            # if we went to zero, we need to draw
            fill_scanline(scanline, len, x0, x1, max_weight, mm) if w == 0
          end
          e = e.not_nil!.next
        end
      elsif fill_rule.evenodd?
        # Even-odd
        while e
          if w == 0
            # if we're currently at zero, we need to record the edge start point
            x0 = e.not_nil!.x
            w = 1
          else
            x1 = e.not_nil!.x
            w = 0
            fill_scanline(scanline, len, x0, x1, max_weight, mm)
          end
          e = e.not_nil!.next
        end
      end
    end

    private def clampf(a : Float32, mn : Float32, mx : Float32) : Float32
      return mn if a.nan?
      a < mn ? mn : (a > mx ? mx : a)
    end

    private def rgba(r : Int, g : Int, b : Int, a : Int) : UInt32
      (r.to_u32 & 0xff) | ((g.to_u32 & 0xff) << 8) | ((b.to_u32 & 0xff) << 16) | ((a.to_u32 & 0xff) << 24)
    end

    private def lerp_rgba(c0 : UInt32, c1 : UInt32, u : Float32) : UInt32
      iu = (clampf(u, 0.0f32, 1.0f32) * 256.0f32).to_i32
      r = ((c0 & 0xff)*(256-iu) + ((c1 & 0xff)*iu)) >> 8
      g = (((c0 >> 8) & 0xff)*(256-iu) + (((c1 >> 8) & 0xff)*iu)) >> 8
      b = (((c0 >> 16) & 0xff)*(256-iu) + (((c1 >> 16) & 0xff)*iu)) >> 8
      a = (((c0 >> 24) & 0xff)*(256-iu) + (((c1 >> 24) & 0xff)*iu)) >> 8
      rgba(r, g, b, a)
    end

    private def apply_opacity(c : UInt32, u : Float32) : UInt32
      iu = (clampf(u, 0.0f32, 1.0f32) * 256.0f32).to_i32
      r = c & 0xff
      g = (c >> 8) & 0xff
      b = (c >> 16) & 0xff
      a = (((c >> 24) & 0xff)*iu) >> 8
      rgba(r, g, b, a)
    end

    private def div255(x : Int) : Int32
      ((x.to_i32 &+ 1) &* 257) >> 16
    end

    private def scanline_solid(dst : Bytes, d : Int32, count : Int32, cover : Array(UInt8),
                               cover_off : Int32, x : Int32, y : Int32,
                               tx : Float32, ty : Float32, scale : Float32, cache : CachedPaint)
      if cache.type.color?
        cr = (cache.colors[0] & 0xff).to_i32
        cg = ((cache.colors[0] >> 8) & 0xff).to_i32
        cb = ((cache.colors[0] >> 16) & 0xff).to_i32
        ca = ((cache.colors[0] >> 24) & 0xff).to_i32

        count.times do
          a = div255(cover[cover_off].to_i32 &* ca)
          ia = 255 - a
          # Premultiply
          r = div255(cr &* a)
          g = div255(cg &* a)
          b = div255(cb &* a)

          # Blend over
          r += div255(ia &* dst[d].to_i32)
          g += div255(ia &* dst[d+1].to_i32)
          b += div255(ia &* dst[d+2].to_i32)
          a += div255(ia &* dst[d+3].to_i32)

          dst[d] = r.to_u8!
          dst[d+1] = g.to_u8!
          dst[d+2] = b.to_u8!
          dst[d+3] = a.to_u8!

          cover_off += 1
          d += 4
        end
      elsif cache.type.linear?
        # TODO: spread modes.
        # TODO: plenty of opportunities to optimize.
        t = cache.xform

        fx = (x.to_f32 - tx) / scale
        fy = (y.to_f32 - ty) / scale
        dx = 1.0f32 / scale

        count.times do
          gy = fx*t[1] + fy*t[3] + t[5]
          c = cache.colors[clampf(gy*255.0f32, 0.0f32, 255.0f32).to_i32]
          cr = (c & 0xff).to_i32
          cg = ((c >> 8) & 0xff).to_i32
          cb = ((c >> 16) & 0xff).to_i32
          ca = ((c >> 24) & 0xff).to_i32

          a = div255(cover[cover_off].to_i32 &* ca)
          ia = 255 - a

          # Premultiply
          r = div255(cr &* a)
          g = div255(cg &* a)
          b = div255(cb &* a)

          # Blend over
          r += div255(ia &* dst[d].to_i32)
          g += div255(ia &* dst[d+1].to_i32)
          b += div255(ia &* dst[d+2].to_i32)
          a += div255(ia &* dst[d+3].to_i32)

          dst[d] = r.to_u8!
          dst[d+1] = g.to_u8!
          dst[d+2] = b.to_u8!
          dst[d+3] = a.to_u8!

          cover_off += 1
          d += 4
          fx += dx
        end
      elsif cache.type.radial?
        # TODO: spread modes.
        # TODO: plenty of opportunities to optimize.
        # TODO: focus (fx,fy)
        t = cache.xform

        fx = (x.to_f32 - tx) / scale
        fy = (y.to_f32 - ty) / scale
        dx = 1.0f32 / scale

        count.times do
          gx = fx*t[0] + fy*t[2] + t[4]
          gy = fx*t[1] + fy*t[3] + t[5]
          gd = Math.sqrt((gx*gx + gy*gy).to_f64).to_f32
          c = cache.colors[clampf(gd*255.0f32, 0.0f32, 255.0f32).to_i32]
          cr = (c & 0xff).to_i32
          cg = ((c >> 8) & 0xff).to_i32
          cb = ((c >> 16) & 0xff).to_i32
          ca = ((c >> 24) & 0xff).to_i32

          a = div255(cover[cover_off].to_i32 &* ca)
          ia = 255 - a

          # Premultiply
          r = div255(cr &* a)
          g = div255(cg &* a)
          b = div255(cb &* a)

          # Blend over
          r += div255(ia &* dst[d].to_i32)
          g += div255(ia &* dst[d+1].to_i32)
          b += div255(ia &* dst[d+2].to_i32)
          a += div255(ia &* dst[d+3].to_i32)

          dst[d] = r.to_u8!
          dst[d+1] = g.to_u8!
          dst[d+2] = b.to_u8!
          dst[d+3] = a.to_u8!

          cover_off += 1
          d += 4
          fx += dx
        end
      end
    end

    private def rasterize_sorted_edges(tx : Float32, ty : Float32, scale : Float32,
                                       cache : CachedPaint, fill_rule : FillRule)
      active : ActiveEdge? = nil
      e = 0
      max_weight = 255 // SUBSAMPLES # weight per vertical scanline
      mm = [@width, 0] # [xmin, xmax]

      y = 0
      while y < @height
        @width.times { |k| @scanline[k] = 0u8 }
        mm[0] = @width
        mm[1] = 0
        s = 0
        while s < SUBSAMPLES
          # find center of pixel for this scanline
          scany = (y*SUBSAMPLES + s).to_f32 + 0.5f32

          # update all active edges;
          # remove all active edges that terminate before the center of this scanline
          prev : ActiveEdge? = nil
          z = active
          while z
            zn = z.not_nil!
            if zn.ey <= scany
              # delete from list
              if prev
                prev.not_nil!.next = zn.next
              else
                active = zn.next
              end
            else
              zn.x += zn.dx # advance to position for current scanline
              prev = zn
            end
            z = zn.next
          end

          # resort the list if needed
          loop do
            changed = false
            prev = nil
            z = active
            while z && z.not_nil!.next
              zz = z.not_nil!
              zn = zz.next.not_nil!
              if zz.x > zn.x
                zz.next = zn.next
                zn.next = zz
                if prev
                  prev.not_nil!.next = zn
                else
                  active = zn
                end
                changed = true
                prev = zn
              else
                prev = zz
              end
              z = prev.not_nil!.next
            end
            break unless changed
          end

          # insert all edges that start before the center of this scanline -- omit ones that also end on this scanline
          while e < @edges.size && @edges[e].y0 <= scany
            if @edges[e].y1 > scany
              ze = add_active(@edges[e], scany)
              # find insertion point
              if active.nil?
                active = ze
              elsif ze.x < active.not_nil!.x
                # insert at front
                ze.next = active
                active = ze
              else
                # find thing to insert AFTER
                p = active.not_nil!
                while p.next && p.next.not_nil!.x < ze.x
                  p = p.next.not_nil!
                end
                # at this point, p->next->x is NOT < z->x
                ze.next = p.next
                p.next = ze
              end
            end
            e += 1
          end

          # now process all active edges in non-zero fashion
          fill_active_edges(@scanline, @width, active, max_weight, mm, fill_rule) if active
          s += 1
        end
        # Blit
        xmin = mm[0]
        xmax = mm[1]
        xmin = 0 if xmin < 0
        xmax = @width - 1 if xmax > @width-1
        if xmin <= xmax
          scanline_solid(@bitmap, y*@stride + xmin*4, xmax-xmin+1, @scanline, xmin, xmin, y, tx, ty, scale, cache)
        end
        y += 1
      end
    end

    private def unpremultiply_alpha(image : Bytes, w : Int32, h : Int32, stride : Int32)
      # Unpremultiply
      h.times do |y|
        w.times do |x|
          i = y*stride + x*4
          r = image[i].to_i32
          g = image[i+1].to_i32
          b = image[i+2].to_i32
          a = image[i+3].to_i32
          if a != 0
            image[i] = (r*255/a).to_u8!
            image[i+1] = (g*255/a).to_u8!
            image[i+2] = (b*255/a).to_u8!
          end
        end
      end

      # Defringe
      h.times do |y|
        w.times do |x|
          i = y*stride + x*4
          r = 0
          g = 0
          b = 0
          a = image[i+3].to_i32
          n = 0
          if a == 0
            # NOTE(port): the C code uses `x-1 > 0` and `y-1 > 0` (instead of
            # >= 0), so row/column 1 is never defringed — kept for fidelity.
            if x-1 > 0 && image[i-1] != 0
              r += image[i-4]
              g += image[i-3]
              b += image[i-2]
              n += 1
            end
            if x+1 < w && image[i+7] != 0
              r += image[i+4]
              g += image[i+5]
              b += image[i+6]
              n += 1
            end
            if y-1 > 0 && image[i-stride+3] != 0
              r += image[i-stride]
              g += image[i-stride+1]
              b += image[i-stride+2]
              n += 1
            end
            if y+1 < h && image[i+stride+3] != 0
              r += image[i+stride]
              g += image[i+stride+1]
              b += image[i+stride+2]
              n += 1
            end
            if n > 0
              image[i] = (r//n).to_u8!
              image[i+1] = (g//n).to_u8!
              image[i+2] = (b//n).to_u8!
            end
          end
        end
      end
    end

    private def init_paint(cache : CachedPaint, paint : Paint, opacity : Float32)
      cache.type = paint.type

      if paint.type.color?
        cache.colors[0] = apply_opacity(paint.color, opacity)
        return
      end

      grad = paint.gradient
      return if grad.nil?

      cache.spread = grad.spread
      6.times { |k| cache.xform[k] = grad.xform[k] }

      nstops = grad.stops.size

      if nstops == 0
        256.times { |i| cache.colors[i] = 0u32 }
      elsif nstops == 1
        color = apply_opacity(grad.stops[0].color, opacity)
        256.times { |i| cache.colors[i] = color }
      else
        ca = apply_opacity(grad.stops[0].color, opacity)
        ua = clampf(grad.stops[0].offset, 0.0f32, 1.0f32)
        ub = clampf(grad.stops[nstops-1].offset, ua, 1.0f32)
        ia = (ua * 255.0f32).to_i32
        ib = (ub * 255.0f32).to_i32
        i = 0
        while i < ia
          cache.colors[i] = ca
          i += 1
        end

        cb = 0u32
        (nstops-1).times do |k|
          ca = apply_opacity(grad.stops[k].color, opacity)
          cb = apply_opacity(grad.stops[k+1].color, opacity)
          ua = clampf(grad.stops[k].offset, 0.0f32, 1.0f32)
          ub = clampf(grad.stops[k+1].offset, 0.0f32, 1.0f32)
          ia = (ua * 255.0f32).to_i32
          ib = (ub * 255.0f32).to_i32
          count = ib - ia
          next if count <= 0
          u = 0.0f32
          du = 1.0f32 / count
          count.times do |jj|
            cache.colors[ia+jj] = lerp_rgba(ca, cb, u)
            u += du
          end
        end

        i = ib
        while i < 256
          cache.colors[i] = cb
          i += 1
        end
      end
    end
  end
end
