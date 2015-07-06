require 'timeout'

class IOUtils

  def self.connect_with_timeout(socket, sockaddr, timeout)
    begin
      socket.connect_nonblock(sockaddr)
    rescue IO::WaitWritable
      if IO.select(nil, [socket], [socket], timeout)
        begin
          socket.connect_nonblock(sockaddr)
        rescue Errno::EISCONN
        end
      else
        raise Timeout::Error.new
      end
    end
  end

  def self.read_with_timeout(io, maxlen, timeout)
    result = ''.force_encoding(Encoding::ASCII_8BIT)
    buffer = ''.force_encoding(Encoding::ASCII_8BIT)
    while not maxlen or result.bytesize < maxlen
      if timeout <= 0
        raise Timeout::Error.new
      end
      begin
        io.read_nonblock((maxlen or 8192), buffer)
        result << buffer
      rescue IO::WaitReadable
        start = Time.now
        IO.select([io], nil, [io], timeout)
        waited = Time.now - start
        timeout -= waited
      rescue EOFError
        break
      end
    end
    result
  end

  def self.write_with_timeout(io, data, timeout)
    cur = 0
    len = data.bytesize
    while cur < len
      if timeout <= 0
        raise Timeout::Error.new
      end
      begin
        count = io.write_nonblock(data.byteslice(cur..-1))
        cur += count
      rescue IO::WaitWritable
        start = Time.now
        IO.select(nil, [io], [io], timeout)
        waited = Time.now - start
        timeout -= waited
      end
    end
  end
end
