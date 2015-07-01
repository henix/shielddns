require 'stringio'

class RegexpTrie

  # @param strs: Array[String]
  # @param out: IO
  def self.build(strs, out = nil)
    if out
      build_depth(strs, 0, out)
    else
      out = StringIO.new
      build_depth(strs, 0, out)
      out.string
    end
  end

  private

  def self.build_depth(strs, depth, out)
    size = strs.size
    if size == 0
      return
    elsif size == 1
      t = strs.first
      if depth < t.length
        out.write(Regexp.quote(t[depth..-1]))
      end
      return
    end

    strs.sort_by! { |s| s[depth] or "" }

    i = strs.find_index { |s| s.length > depth }
    if i == nil
      return # not found, exit
    end

    has_empty = i > 0
    all_same = strs[i][depth] == strs.last[depth]

    if not all_same or has_empty
      out.write("(?:")
    end
    if all_same
      out.write(Regexp.quote(strs[i][depth]))
      build_depth((i > 0 and strs[i...size] or strs), depth + 1, out)
    else
      # use [depth] to split strs into sections
      first = true
      while i < size
        start = i
        ch = strs[i][depth]
        while i < size and strs[i][depth] == ch
          i = i + 1
        end
        e = i
        if first
          first = false
        else
          out.write("|")
        end
        out.write(Regexp.quote(ch))
        build_depth(strs[start...e], depth + 1, out)
      end
    end
    if not all_same or has_empty
      out.write(")")
    end
    if has_empty
      out.write("?")
    end
  end
end
