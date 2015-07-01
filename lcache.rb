require "observer"

# According to ruby doc:
# > Hashes enumerate their values in the order that the corresponding keys were inserted.
# So hashes can be used as a linked-list to implement LRU Cache
class LCache
  include Observable

  def initialize(options = {})
    @ttl = options[:ttl]
    @max_size = options[:max_size]

    @dict = {}
    @wtime = (@ttl and {} or nil)
    @atime = (@max_size and {} or nil)
  end

  def get_or_update(k)
    v = @dict[k]
    if v.nil?
      v = yield(k)
      v2 = @dict[k]
      if v2.nil?
        @dict[k] = v
        wrote(k, v)
        check_size!
      else
        v = v2
        cache_hit(k)
      end
    else
      cache_hit(k)
    end
    v
  end

  def evict!
    early_time = Time.now.to_i - @ttl
    k, wtime = @wtime.first
    while not @dict.empty? and wtime < early_time
      delete(k)
      k, wtime = @wtime.first
    end
  end

  private

  def delete(k)
    v = @dict.delete(k)
    deleted(k)
    v
  end

  def cache_hit(k)
    if @atime
      @atime.delete(k)
      @atime[k] = 1
    end
    changed
    notify_observers(:cache_hit, k)
  end

  def wrote(k, v)
    if @wtime
      @wtime.delete(k)
      @wtime[k] = Time.now.to_i
    end
    if @atime
      @atime.delete(k)
      @atime[k] = 1
    end
    changed
    notify_observers(:wrote, k, v)
  end

  def deleted(k)
    if @atime
      @atime.delete(k)
    end
    if @wtime
      @wtime.delete(k)
    end
    changed
    notify_observers(:deleted, k)
  end

  def check_size!
    if @max_size and @dict.size > @max_size
      k, _ = @atime.first
      delete(k)
    end
  end
end
