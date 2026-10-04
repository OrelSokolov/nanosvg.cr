# Kerning tables for the `<text>` layout (used by font.cr).
#
# - GPOS: walks ScriptList/FeatureList/LookupList, collects the
#   `kern` feature's LookupType 2 (PairPos) subtables, formats 1
#   (pair sets) and 2 (class matrices). Only the XAdvance of the
#   first glyph is read — the only thing a horizontal layout needs.
# - Legacy `kern` (format 0, horizontal): binary-searched pairs,
#   used when the font has no GPOS kerning.
#
# Both work on raw big-endian table bytes through BinRead.

module NanoSVG
  private class GposKern
    include BinRead

    def initialize(@buf : Bytes)
      # PairPos format 1: pair set offset (absolute in @buf), the
      # coverage table offset, and the value formats.
      @fmt1 = [] of NamedTuple(sub: Int32, count: Int32, cov: Int32, vf1: Int32, vf2: Int32)
      # PairPos format 2: subtable offset, coverage, value formats,
      # class-def offsets and counts.
      @fmt2 = [] of NamedTuple(off: Int32, cov: Int32, vf1: Int32, vf2: Int32,
                               cd1: Int32, cd2: Int32, c1c: Int32, c2c: Int32)
    end

    def self.parse(buf : Bytes?) : GposKern?
      return nil unless buf
      k = GposKern.new(buf.not_nil!)
      k.read_subtables ? k : nil
    end

    protected def read_subtables : Bool
      buf = @buf
      # GPOS header: version(u32), scriptList(u16), featureList(u16),
      # lookupList(u16).
      feature_list = read_u16(buf, 6)
      lookup_list = read_u16(buf, 8)
      return false unless feature_list && lookup_list

      lookups = [] of Int32
      n_features = read_u16(buf, feature_list).not_nil!
      n_features.times do |i|
        rec = feature_list + 2 + i * 6
        tag = buf[rec, 4]? || next
        next unless tag == "kern".to_slice
        # Feature offsets are relative to the FeatureList start
        # (the count field included).
        f_off = feature_list + read_u16(buf, rec + 4).not_nil!
        # Feature table: featureParams u16, lookupCount u16, indices.
        cnt = read_u16(buf, f_off + 2).not_nil!
        cnt.times do |j|
          lookups << read_u16(buf, f_off + 4 + j * 2).not_nil!
        end
      end
      # The same lookup may back several script-specific kern
      # features; HarfBuzz applies each once — dedupe by index.
      lookups.uniq!
      return false if lookups.empty?

      n_lookups = read_u16(buf, lookup_list).not_nil!
      lookups.each do |li|
        next if li >= n_lookups
        # Lookup offsets are relative to the LookupList start.
        lk_off = lookup_list + read_u16(buf, lookup_list + 2 + li * 2).not_nil!
        ltype = read_u16(buf, lk_off).not_nil!
        next unless ltype == 2 || ltype == 9 # PairPos (possibly wrapped)
        n_subs = read_u16(buf, lk_off + 4).not_nil!
        n_subs.times do |j|
          rel = read_u16(buf, lk_off + 6 + j * 2).not_nil!
          st_off = lk_off + rel
          if ltype == 9
            # ExtensionPos: format u16, extensionLookupType u16,
            # extensionOffset u32 (from the start of this subtable).
            next unless read_u16(buf, st_off) == 1
            ext_type = read_u16(buf, st_off + 2).not_nil!
            ext_off = read_u32(buf, st_off + 4).not_nil!
            next unless ext_type == 2
            st_off += ext_off
          end
          read_pair_pos(st_off)
        end
      end
      !@fmt1.empty? || !@fmt2.empty?
    end

    private def read_pair_pos(off : Int32) : Nil
      buf = @buf
      return if off + 16 > buf.size
      fmt = read_u16(buf, off).not_nil!
      vf1 = read_u16(buf, off + 4).not_nil!
      vf2 = read_u16(buf, off + 6).not_nil!
      return if (vf1 & 0x0004) == 0 # needs XAdvance of glyph 1

      case fmt
      when 1
        # PairPosFormat1: posFormat, coverageOffset(+2), valueFormat1(+4),
        # valueFormat2(+6), pairSetCount(+8), pairSetOffsets(+10..).
        cov = off + read_u16(buf, off + 2).not_nil!
        ps_count = read_u16(buf, off + 8).not_nil!
        @fmt1 << {sub: off, count: ps_count, cov: cov, vf1: vf1, vf2: vf2}
      when 2
        # PairPosFormat2: posFormat, coverageOffset(+2), valueFormat1(+4),
        # valueFormat2(+6), classDef1(+8), classDef2(+10), class1Count(+12),
        # class2Count(+14), then the Class1Records matrix.
        cov = off + read_u16(buf, off + 2).not_nil!
        cd1 = off + read_u16(buf, off + 8).not_nil!
        cd2 = off + read_u16(buf, off + 10).not_nil!
        c1c = read_u16(buf, off + 12).not_nil!
        c2c = read_u16(buf, off + 14).not_nil!
        @fmt2 << {off: off, cov: cov, vf1: vf1, vf2: vf2,
                  cd1: cd1, cd2: cd2, c1c: c1c, c2c: c2c}
      end
    end

    # XAdvance adjustment (font units) for a glyph pair.
    def pair(g1 : Int32, g2 : Int32) : Float32
      total = 0.0_f32
      @fmt1.each do |st|
        v = fmt1_pair(st, g1, g2)
        total += v if v
      end
      @fmt2.each do |st|
        v = fmt2_pair(st, g1, g2)
        total += v if v
      end
      total
    end

    private def fmt1_pair(st, g1 : Int32, g2 : Int32) : Float32?
      buf = @buf
      idx = coverage_index(st[:cov], g1)
      return nil unless idx
      ps_off = st[:sub] + read_u16(buf, st[:sub] + 10 + idx * 2).not_nil!
      xadv_idx = popcount16(st[:vf1] & 0x0003) # fields before XAdvance
      rec_len = 2 + (popcount16(st[:vf1]) + popcount16(st[:vf2])) * 2
      n = read_u16(buf, ps_off).not_nil!
      # PairSet records are sorted by secondGlyph: binary search.
      lo = 0
      hi = n - 1
      while lo <= hi
        mid = (lo + hi) // 2
        rec = ps_off + 2 + mid * rec_len
        second = read_u16(buf, rec).not_nil!
        if g2 < second
          hi = mid - 1
        elsif g2 > second
          lo = mid + 1
        else
          return read_i16(buf, rec + 2 + xadv_idx * 2).not_nil!.to_f32
        end
      end
      nil
    end

    private def fmt2_pair(st, g1 : Int32, g2 : Int32) : Float32?
      return nil unless coverage_index(st[:cov], g1)
      c1 = class_def(st[:cd1], g1)
      c2 = class_def(st[:cd2], g2)
      return nil if c1 >= st[:c1c] || c2 >= st[:c2c]
      xadv_idx = popcount16(st[:vf1] & 0x0003)
      len1 = popcount16(st[:vf1]) * 2
      len2 = popcount16(st[:vf2]) * 2
      rec = st[:off] + 16 + c1 * st[:c2c] * (len1 + len2) + c2 * (len1 + len2)
      read_i16(@buf, rec + xadv_idx * 2).not_nil!.to_f32
    end

    # Coverage table: format 1 (glyph array), format 2 (ranges).
    # Returns the coverage index of the glyph, or nil.
    private def coverage_index(cov_off : Int32, gid : Int32) : Int32?
      buf = @buf
      fmt = read_u16(buf, cov_off).not_nil!
      case fmt
      when 1
        n = read_u16(buf, cov_off + 2).not_nil!
        # Sorted: binary search.
        lo = 0
        hi = n - 1
        while lo <= hi
          mid = (lo + hi) // 2
          g = read_u16(buf, cov_off + 4 + mid * 2).not_nil!
          return mid if g == gid
          g < gid ? (lo = mid + 1) : (hi = mid - 1)
        end
        nil
      when 2
        n = read_u16(buf, cov_off + 2).not_nil!
        n.times do |i|
          rec = cov_off + 4 + i * 6
          start = read_u16(buf, rec).not_nil!
          fin = read_u16(buf, rec + 2).not_nil!
          base = read_u16(buf, rec + 4).not_nil!
          return base + (gid - start) if gid >= start && gid <= fin
        end
        nil
      else
        nil
      end
    end

    # ClassDef table: format 1 (array from startGlyph), format 2
    # (ranges). Glyphs outside every range are class 0.
    private def class_def(off : Int32, gid : Int32) : Int32
      buf = @buf
      fmt = read_u16(buf, off).not_nil!
      case fmt
      when 1
        start = read_u16(buf, off + 2).not_nil!
        count = read_u16(buf, off + 4).not_nil!
        idx = gid - start
        idx >= 0 && idx < count ? read_u16(buf, off + 6 + idx * 2).not_nil! : 0
      when 2
        n = read_u16(buf, off + 2).not_nil!
        n.times do |i|
          rec = off + 4 + i * 6
          start = read_u16(buf, rec).not_nil!
          fin = read_u16(buf, rec + 2).not_nil!
          return read_u16(buf, rec + 4).not_nil! if gid >= start && gid <= fin
        end
        0
      else
        0
      end
    end

    private def popcount16(v : Int32) : Int32
      v = v & 0xffff
      v = v - ((v >> 1) & 0x5555)
      v = (v & 0x3333) + ((v >> 2) & 0x3333)
      v = (v + (v >> 4)) & 0x0f0f
      (v + (v >> 8)) & 0x1f
    end
  end

  private class LegacyKern
    include BinRead

    def initialize(@buf : Bytes, @pairs_off : Int32, @n_pairs : Int32)
    end

    # Legacy `kern` (Apple/AAT layout 0 or Microsoft format 0):
    # horizontal subtables only, version 0 header.
    def self.parse(buf : Bytes?) : LegacyKern?
      return nil unless buf
      b = buf.not_nil!
      return nil unless b.size >= 4
      k = LegacyKern.new(b, 0, 0)
      off, count = k.find_horizontal(b)
      off ? LegacyKern.new(b, off, count) : nil
    end

    protected def find_horizontal(b : Bytes) : {Int32?, Int32}
      n_tables = read_u16(b, 2).not_nil!
      off = 4
      n_tables.times do
        break if off + 14 > b.size
        length = read_u16(b, off + 2).not_nil!
        coverage = read_u16(b, off + 4).not_nil!
        fmt = coverage & 0xff
        horizontal = (coverage & 0x01) != 0 # horizontal bit (MS)
        n_pairs = read_u16(b, off + 6).not_nil!
        if fmt == 0 && horizontal && n_pairs > 0
          return {off + 14, n_pairs}
        end
        off += length > 0 ? length : (14 + n_pairs * 6)
      end
      {nil, 0}
    end

    # Pairs sorted by (left << 16 | right): binary search.
    def pair(g1 : Int32, g2 : Int32) : Float32
      b = @buf
      key = (g1 << 16) | (g2 & 0xffff)
      lo = 0
      hi = @n_pairs - 1
      while lo <= hi
        mid = (lo + hi) // 2
        rec = @pairs_off + mid * 6
        l = read_u16(b, rec).not_nil!
        r = read_u16(b, rec + 2).not_nil!
        cur = (l << 16) | r
        if cur == key
          return read_i16(b, rec + 4).not_nil!.to_f32
        elsif cur < key
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      0.0_f32
    end
  end
end
