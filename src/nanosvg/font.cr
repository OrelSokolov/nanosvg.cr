# TrueType glyph outlines for `<text>` rendering — a minimal sfnt
# reader (no external dependencies, no C extensions). Reads the tables
# a text layout needs:
#
#   head (unitsPerEm, indexToLocFormat)   cmap (formats 4/12)
#   hhea/hmtx (advances, ascent/descent)  maxp (glyph count)
#   loca/glyf (outlines: simple + composite glyphs)
#   GPOS (kern feature: PairPos formats 1/2) and the legacy `kern`
#   table (format 0) as a fallback — see font_kern.cr
#
# Glyph outlines come out as closed contours in the parser's cubic
# bezier point format (1 point + N*3), already flipped to SVG's
# y-down coordinates, in font units. The parser scales them by
# size/unitsPerEm and places them at the pen position.
#
# CFF-flavoured OpenType (.otf) outlines are not read: `glyf` only.
# The font store resolves families through fontconfig (`fc-match`),
# the same library Pango/librsvg use, so both renderers pick the
# same file.

# Big-endian readers shared by the font and its kerning tables.
module NanoSVG
  module BinRead
    def read_i16(buf : Bytes, off : Int32) : Int32?
      return nil if off < 0 || off + 2 > buf.size
      v = (buf[off].to_i32 << 8) | buf[off + 1]
      v >= 0x8000 ? v - 0x10000 : v
    end

    def read_u16(buf : Bytes, off : Int32) : Int32?
      v = read_i16(buf, off)
      v && v & 0xffff
    end

    def read_i32(buf : Bytes, off : Int32) : Int32?
      return nil if off < 0 || off + 4 > buf.size
      ((buf[off].to_u32 << 24) | (buf[off + 1].to_u32 << 16) |
        (buf[off + 2].to_u32 << 8) | buf[off + 3].to_u32).to_i32!
    end

    def read_u32(buf : Bytes, off : Int32) : Int32?
      read_i32(buf, off)
    end
  end

  class Font
    include BinRead

    # A glyph's geometry: advance width (font units) and closed
    # contours of cubic bezier points (font units, y-down).
    class Glyph
      getter gid : Int32
      getter advance : Float32
      getter contours : Array(Array(Float32))

      def initialize(@gid, @advance, @contours)
      end

      def empty? : Bool
        @contours.empty?
      end
    end

    getter units_per_em : Int32 = 1000
    getter ascender : Float32 = 800.0_f32   # font units, positive
    getter descender : Float32 = -200.0_f32 # font units, negative

    # True when OS/2 sxHeight was available; otherwise #x_height falls
    # back to the measured 'x' glyph (computed lazily on first use).
    @x_height : Float32 = 500.0_f32
    @x_height_measured = false

    @index_to_loc_long = false
    @number_of_hmetrics = 0
    @num_glyphs = 0
    @cmap_offset = 0
    @maxp : Bytes = Bytes.empty
    @cmap : Bytes = Bytes.empty
    @hmtx : Bytes = Bytes.empty
    @loca : Bytes = Bytes.empty
    @glyf : Bytes = Bytes.empty

    @glyph_cache = {} of Int32 => Glyph?
    @glyph_ids = {} of Int32 => Int32
    @gpos_kern : GposKern?
    @legacy_kern : LegacyKern?

    def initialize(@data : Bytes)
      io = IO::Memory.new(@data)
      tag = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      offset = case tag
               when 0x00010000_u32, 0x74727565_u32 # 1.0, 'true'
                 0_u32
               when 0x74746366_u32 # 'ttcf' — use the first face
                 io.skip(4)
                 io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
               else
                 raise "not a TrueType font"
               end

      tables = {} of String => Bytes
      io.pos = offset.to_i32
      io.skip(4) # sfnt version
      count = io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # numTables @4
      io.skip(6)                                               # searchRange/entrySelector/rangeShift
      # Table records start at offset 12 within the face.
      count.times do
        tag_bytes = Bytes.new(4) { io.read_byte.not_nil! }
        io.skip(4) # checksum
        toff = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        tlen = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        name = String.new(tag_bytes)
        # Trailing table bytes may be zero-padded into the next
        # table's space; clamp to what is actually in the buffer.
        if toff < @data.size && toff.to_u64 + tlen > @data.size
          tlen = @data.size.to_u32 - toff
        end
        tables[name] = @data[toff, tlen] if toff < @data.size
      end

      head = tables["head"]? || raise "missing head"
      @units_per_em = read_i16(head, 18).not_nil!
      raise "bad unitsPerEm" if @units_per_em <= 0
      @index_to_loc_long = read_i16(head, 50) == 1

      hhea = tables["hhea"]? || raise "missing hhea"
      @ascender = read_i16(hhea, 4).not_nil!.to_f32
      @descender = read_i16(hhea, 6).not_nil!.to_f32
      @number_of_hmetrics = read_i16(hhea, 34).not_nil!

      if os2 = tables["OS/2"]?
        version = read_i16(os2, 0).not_nil!
        if version >= 2 && os2.size >= 88
          xh = read_i16(os2, 86).not_nil!
          if xh > 0
            @x_height = xh.to_f32
            @x_height_measured = true
          end
        end
      end

      @maxp = tables["maxp"]? || raise "missing maxp"
      @num_glyphs = read_i16(@maxp, 4).not_nil!

      @cmap = tables["cmap"]? || raise "missing cmap"
      @hmtx = tables["hmtx"]? || raise "missing hmtx"
      @loca = tables["loca"]? || raise "missing loca"
      @glyf = tables["glyf"]? || raise "missing glyf"

      @cmap_offset = pick_cmap_subtable

      @gpos_kern = GposKern.parse(tables["GPOS"]?) if tables["GPOS"]?
      # Only fall back to the legacy table when GPOS has no kerning.
      @legacy_kern = LegacyKern.parse(tables["kern"]?) if @gpos_kern.nil? && tables["kern"]?
    end

    # X-height in font units: OS/2 sxHeight when present (v2+), else
    # the top of the lowercase 'x' outline.
    def x_height : Float32
      unless @x_height_measured
        @x_height_measured = true
        if g = glyph(glyph_index('x'.ord))
          top = 0.0_f32
          g.contours.each do |c|
            i = 1
            while i < c.size
              top = Math.min(top, c[i]) # y-down: above baseline is negative
              i += 2
            end
          end
          @x_height = -top if top < 0.0f32
        end
      end
      @x_height
    end

    def self.load(path : String) : Font?
      Font.new(File.read(path).to_slice)
    rescue ex
      STDERR.puts "nanosvg: cannot load font #{path}: #{ex.message}" if STDERR
      nil
    end

    # ---------- cmap ----------

    # Picks the best Unicode cmap subtable; returns its byte offset.
    private def pick_cmap_subtable : Int32
      io = IO::Memory.new(@cmap)
      io.skip(2) # version
      n = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
      best_score = -1
      best_off = 0
      n.times do
        platform = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        encoding = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        off = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        score = case {platform, encoding}
                when {3, 10}        then 5 # UCS-4, full Unicode
                when {0, 4}, {0, 6} then 4
                when {0, 5}         then 3
                when {3, 1}         then 2 # BMP
                when {0, 3}         then 1
                else                    -1
                end
        if score > best_score
          best_score = score
          best_off = off.to_i32
        end
      end
      best_off
    end

    # cmap codepoint → glyph id (0 = .notdef when missing).
    def glyph_index(codepoint : Int32) : Int32
      @glyph_ids[codepoint]? || begin
        gid = cmap_lookup(codepoint)
        @glyph_ids[codepoint] = gid
        gid
      end
    end

    private def cmap_lookup(codepoint : Int32) : Int32
      cmap = @cmap[@cmap_offset...]
      return 0 if cmap.empty?
      case read_u16(cmap, 0)
      when 4  then cmap4_lookup(cmap, codepoint)
      when 12 then cmap12_lookup(cmap, codepoint)
      else 0
      end
    end

    private def cmap4_lookup(cmap : Bytes, codepoint : Int32) : Int32
      seg_count_x2 = read_u16(cmap, 6).not_nil!
      seg_count = seg_count_x2 // 2
      # Arrays follow the 14-byte header: endCode, pad, startCode,
      # idDelta (i16), idRangeOffset — all seg_count entries.
      lo = 14
      seg = seg_count.times.find do |i|
        codepoint <= read_u16(cmap, lo + i * 2).not_nil!
      end
      return 0 unless seg
      start_code = read_u16(cmap, lo + seg_count_x2 + 2 + seg * 2).not_nil!
      return 0 if codepoint < start_code
      delta = read_i16(cmap, lo + seg_count_x2 * 2 + 2 + seg * 2).not_nil!
      range_off = read_u16(cmap, lo + seg_count_x2 * 3 + 2 + seg * 2).not_nil!
      return (codepoint + delta) & 0xffff if range_off == 0
      # Glyph id array entry: idRangeOffset slot + offset + 2*(cp-start).
      slot = lo + seg_count_x2 * 3 + 2 + seg * 2
      addr = slot + range_off + 2 * (codepoint - start_code)
      g = read_u16(cmap, addr).not_nil!
      g == 0 ? 0 : (g + delta) & 0xffff
    end

    private def cmap12_lookup(cmap : Bytes, codepoint : Int32) : Int32
      n_groups = read_u32(cmap, 12).not_nil!
      lo = 0
      hi = n_groups - 1
      while lo <= hi # groups sorted by startCharCode
        mid = (lo + hi) // 2
        start = read_u32(cmap, 16 + mid * 12).not_nil!
        fin = read_u32(cmap, 16 + mid * 12 + 4).not_nil!
        if codepoint < start
          hi = mid - 1
        elsif codepoint > fin
          lo = mid + 1
        else
          base = read_u32(cmap, 16 + mid * 12 + 8).not_nil!
          return (base + codepoint - start) & 0xffff
        end
      end
      0
    end

    # ---------- metrics ----------

    def advance(gid : Int32) : Float32
      n = @number_of_hmetrics
      off = gid < n ? gid * 4 : (n > 0 ? (n - 1) * 4 : 0)
      read_u16(@hmtx, off).try(&.to_f32) || 0.0_f32
    end

    # Kerning between two glyph ids in font units (positive moves the
    # second glyph right). GPOS first, legacy `kern` as a fallback.
    def kern(l_gid : Int32, r_gid : Int32) : Float32
      if g = @gpos_kern
        g.pair(l_gid, r_gid)
      elsif k = @legacy_kern
        k.pair(l_gid, r_gid)
      else
        0.0_f32
      end
    end

    # ---------- outlines ----------

    def glyph(gid : Int32) : Glyph?
      return nil if gid < 0 || gid >= @num_glyphs
      @glyph_cache[gid]? || begin
        g = build_glyph(gid, 0)
        @glyph_cache[gid] = g
        g
      end
    end

    private def build_glyph(gid : Int32, depth : Int32) : Glyph?
      adv = advance(gid)
      return Glyph.new(gid, adv, [] of Array(Float32)) if depth > 8

      start, fin = loca_range(gid)
      return Glyph.new(gid, adv, [] of Array(Float32)) if start >= fin

      glyf = @glyf
      contours = [] of Array(Float32)
      n_contours = read_i16(glyf, start).not_nil!
      if n_contours >= 0
        parse_simple_glyph(glyf, start, n_contours, contours)
      elsif n_contours == -1
        parse_composite_glyph(glyf, start, contours, depth)
      end
      Glyph.new(gid, adv, contours)
    end

    private def loca_range(gid : Int32) : {Int32, Int32}
      loca = @loca
      s, f =
        if @index_to_loc_long
          {read_u32(loca, gid * 4), read_u32(loca, gid * 4 + 4)}
        else
          {read_u16(loca, gid * 2).try { |v| v * 2 },
           read_u16(loca, gid * 2 + 2).try { |v| v * 2 }}
        end
      {(s || 0), (f || 0)}
    end

    # Simple glyph: one flag pass then x/y delta passes, contours
    # emitted per endPtsOfContours ranges.
    private def parse_simple_glyph(glyf : Bytes, start : Int32,
                                   n_contours : Int32, contours : Array(Array(Float32)))
      io = IO::Memory.new(glyf[start...])
      io.skip(10) # numberOfContours + bbox

      end_pts = Array.new(n_contours) { io.read_bytes(UInt16, IO::ByteFormat::BigEndian) }
      n_points = n_contours > 0 ? end_pts.last + 1 : 0
      return if n_points <= 0

      io.skip(io.read_bytes(UInt16, IO::ByteFormat::BigEndian)) # instructions

      flags = Array.new(n_points, 0)
      i = 0
      while i < n_points
        flag = io.read_byte.not_nil!
        repeat = (flag & 0x08) != 0 ? io.read_byte.not_nil! : 0
        (repeat + 1).times do
          break if i >= n_points
          flags[i] = flag
          i += 1
        end
      end

      xs = Array.new(n_points, 0)
      i = 0
      while i < n_points
        flag = flags[i]
        if flag & 0x02 != 0 # short
          d = io.read_byte.not_nil!.to_i32
          xs[i] = flag & 0x10 != 0 ? d : -d
        elsif flag & 0x10 == 0 # 16-bit signed delta
          xs[i] = io.read_bytes(Int16, IO::ByteFormat::BigEndian)
        end
        i += 1
      end

      ys = Array.new(n_points, 0)
      i = 0
      while i < n_points
        flag = flags[i]
        if flag & 0x04 != 0 # short
          d = io.read_byte.not_nil!.to_i32
          ys[i] = flag & 0x20 != 0 ? d : -d
        elsif flag & 0x20 == 0 # 16-bit signed delta
          ys[i] = io.read_bytes(Int16, IO::ByteFormat::BigEndian)
        end
        i += 1
      end

      # Absolute coordinates (deltas accumulate across the glyph).
      (1...n_points).each do |k|
        xs[k] += xs[k - 1]
        ys[k] += ys[k - 1]
      end

      prev = 0
      end_pts.each do |ept|
        n = ept - prev + 1
        pts = Array(Float32).new(n * 2) { |k| k.even? ? xs[prev + k // 2].to_f32 : ys[prev + k // 2].to_f32 }
        on = Array.new(n) { |k| (flags[prev + k] & 0x01) != 0 }
        contours << conics_to_cubic(pts, on)
        prev = ept + 1
      end
    end

    # Composite glyph: components placed with 2x2 transforms over
    # referenced glyphs (recursively).
    private def parse_composite_glyph(glyf : Bytes, start : Int32,
                                      contours : Array(Array(Float32)), depth : Int32)
      io = IO::Memory.new(glyf[start...])
      io.skip(10)
      loop do
        flags = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        sub_gid = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        break unless flags & 0x0002 != 0 # ARGS_ARE_XY_VALUES only

        dx, dy =
          if flags & 0x0001 != 0 # ARG_1_AND_2_ARE_WORDS
            {io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_f32,
             io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_f32}
          else
            {io.read_byte.not_nil!.to_i8.to_f32,
             io.read_byte.not_nil!.to_i8.to_f32}
          end

        a = 1.0_f32; b = 0.0_f32; c = 0.0_f32; d = 1.0_f32
        case
        when flags & 0x0008 != 0 # WE_HAVE_A_SCALE
          a = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
          d = a
        when flags & 0x0040 != 0 # X_AND_Y_SCALE
          a = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
          d = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
        when flags & 0x0080 != 0 # TWO_BY_TWO
          a = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
          b = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
          c = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
          d = io.read_bytes(Int16, IO::ByteFormat::BigEndian) / 16384.0_f32
        end

        if sub = build_glyph(sub_gid, depth + 1)
          sub.contours.each do |contour|
            acc = Array(Float32).new(contour.size)
            i = 0
            while i < contour.size
              x = contour[i]
              y = contour[i + 1]
              acc << (a * x + c * y + dx)
              acc << (b * x + d * y + dy)
              i += 2
            end
            contours << acc
          end
        end
        break if flags & 0x0020 == 0 # MORE_COMPONENTS
      end
    end

    # Converts one TrueType contour (quadratic on/off points, y-up)
    # to the parser's closed cubic format (y-down). Between two
    # consecutive off-curve points the on-curve midpoint is implied;
    # quadratics are elevated to cubics with the 2/3 handle rule.
    private def conics_to_cubic(pts : Array(Float32), on : Array(Bool)) : Array(Float32)
      n = on.size
      acc = [] of Float32
      return acc if n < 2

      # Resolve implied on-curve midpoints between adjacent off points.
      rx = [] of Float32
      ry = [] of Float32
      ron = [] of Bool
      n.times do |k|
        rx << pts[k * 2]
        ry << pts[k * 2 + 1]
        ron << on[k]
        kn = (k + 1) % n
        if !on[k] && !on[kn]
          rx << (pts[k * 2] + pts[kn * 2]) * 0.5_f32
          ry << (pts[k * 2 + 1] + pts[kn * 2 + 1]) * 0.5_f32
          ron << true
        end
      end

      m = ron.size
      first = ron.index(true)
      return acc unless first

      acc << rx[first]
      acc << -ry[first] # y flip
      i = first
      cur_x = rx[first]
      cur_y = ry[first]
      loop do
        nxt = (i + 1) % m
        if ron[nxt]
          # Straight segment as a degenerate cubic (1/3 rule, same
          # as the parser's line_to).
          x1 = rx[nxt]
          y1 = ry[nxt]
          dx = x1 - cur_x
          dy = y1 - cur_y
          acc << cur_x + dx / 3.0_f32; acc << -(cur_y + dy / 3.0_f32)
          acc << x1 - dx / 3.0_f32;    acc << -(y1 - dy / 3.0_f32)
          acc << x1;                   acc << -y1
          cur_x = x1
          cur_y = y1
          i = nxt
        else
          # Off-curve run: each conic becomes a cubic with handles
          # at 2/3 towards the quadratic control point.
          q1x = rx[nxt]; q1y = ry[nxt]
          loop do
            after = (nxt + 1) % m
            if ron[after]
              # Last conic of the run: (cur, q1) → on-point.
              c1x = cur_x + 2.0_f32 / 3.0_f32 * (q1x - cur_x)
              c1y = cur_y + 2.0_f32 / 3.0_f32 * (q1y - cur_y)
              c2x = rx[after] + 2.0_f32 / 3.0_f32 * (q1x - rx[after])
              c2y = ry[after] + 2.0_f32 / 3.0_f32 * (q1y - ry[after])
              acc << c1x; acc << -c1y
              acc << c2x; acc << -c2y
              acc << rx[after]; acc << -ry[after]
              cur_x = rx[after]
              cur_y = ry[after]
              i = after
              break
            else
              # Interior off pair: implied on-point at the midpoint.
              mx = (q1x + rx[after]) * 0.5_f32
              my = (q1y + ry[after]) * 0.5_f32
              c1x = cur_x + 2.0_f32 / 3.0_f32 * (q1x - cur_x)
              c1y = cur_y + 2.0_f32 / 3.0_f32 * (q1y - cur_y)
              c2x = mx + 2.0_f32 / 3.0_f32 * (q1x - mx)
              c2y = my + 2.0_f32 / 3.0_f32 * (q1y - my)
              acc << c1x; acc << -c1y
              acc << c2x; acc << -c2y
              acc << mx; acc << -my
              cur_x = mx
              cur_y = my
              q1x = rx[after]
              q1y = ry[after]
              nxt = after
            end
          end
        end
        break if i == first
      end
      acc
    end
  end

  # Family name → Font resolution. Explicit registrations win; system
  # families go through fontconfig, so the same file Pango/librsvg
  # pick is picked (family + weight + slant pattern).
  module FontStore
    record Key, family : String, bold : Bool, italic : Bool

    @@explicit = {} of Key => String
    @@fonts = {} of String => Font?
    @@resolved = {} of Key => Font?

    # Registers a font file for a family (and variants): overrides
    # fontconfig for that key.
    def self.register(path : String, families : String | Enumerable(String),
                      bold : Bool = false, italic : Bool = false) : Nil
      fams = families.is_a?(String) ? {families} : families
      fams.each do |f|
        @@explicit[Key.new(f.downcase, bold, italic)] = File.expand_path(path)
      end
    end

    def self.font(family : String, bold : Bool, italic : Bool) : Font?
      key = Key.new(family.downcase, bold, italic)
      @@resolved[key]? || begin
        path = @@explicit[key]? || fc_match(family, bold, italic)
        font = path ? load_file(path) : nil
        @@resolved[key] = font
        font
      end
    end

    private def self.load_file(path : String) : Font?
      @@fonts[path]? || begin
        f = Font.load(path)
        @@fonts[path] = f
        f
      end
    end

    # fc-match with fontconfig weight/slant values (REGULAR=80,
    # BOLD=200, ROMAN=0, ITALIC=100) — the knobs Pango also sets.
    private def self.fc_match(family : String, bold : Bool, italic : Bool) : String?
      pattern = "#{family}:weight=#{bold ? 200 : 80}:slant=#{italic ? 100 : 0}"
      acc = IO::Memory.new
      status = Process.run("fc-match", ["-f", "%{file}", "--", pattern],
        output: acc, error: Process::Redirect::Inherit)
      return nil unless status.success?
      path = acc.to_s.strip
      path.empty? || File.exists?(path) ? (path.empty? ? nil : path) : nil
    rescue
      nil
    end
  end
end
