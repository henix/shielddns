#!/usr/bin/env ruby

Thread.abort_on_exception = true

require 'logger'
require 'resolv'
require 'socket'
require 'thread'

require_relative 'ioutils'
require_relative 'lcache'
require_relative 'regexptrie'

Message = Resolv::DNS::Message
Resource = Resolv::DNS::Resource
Name = Resolv::DNS::Name

$logger = Logger.new(STDOUT)
$logger.formatter = proc { |severity, datetime, progname, msg|
  "#{datetime.strftime("%F %T.%L")} #{severity} - #{msg}\n"
}

class Utils
  @@cache = {}

  def self.makekey(hostname, typeclass)
    v = @@cache[typeclass]
    if v.nil?
      v = typeclass.name.split("::").last
      @@cache[typeclass] = v
    end
    hostname + "|" + v
  end
end

class DNSClient
  def initialize(type, host, port = 53, timeout = 10)
    @type = type
    @host, @port = host, port
    @timeout = timeout
  end

  # @param hostname: String
  # @param typeclass: class in Resolv::DNS::Resource
  # @return Message
  def resolv(hostname, typeclass)
    req = Message.new.tap { |q|
      q.id = rand(65536)
      q.rd = 1
      q.add_question(hostname, typeclass)
      q
    }
    addrinfo = Socket.getaddrinfo(@host, nil)
    socket = Socket.new(Socket.const_get(addrinfo[0][0]), (@type == :tcp and Socket::SOCK_STREAM or Socket::SOCK_DGRAM))
    if @type == :tcp
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    end
    begin
      IOUtils.connect_with_timeout(socket, Socket.pack_sockaddr_in(@port, addrinfo[0][3]), @timeout)
      data =
        case @type
        when :udp
          $logger.info { "udp.send: #{Utils.makekey(hostname, typeclass)} #{@host}:#{@port}" }
          IOUtils.write_with_timeout(socket, req.encode, @timeout)
          begin
            socket.recv_nonblock(512)
          rescue IO::WaitReadable
            if IO.select([socket], nil, [socket], @timeout)
              retry
            else
              raise Timeout::Error.new
            end
          end
        when :tcp
          $logger.info { "tcp.send: #{Utils.makekey(hostname, typeclass)} #{@host}:#{@port}" }
          data = req.encode
          IOUtils.write_with_timeout(socket, [data.bytesize].pack('n') + data, @timeout)
          t = IOUtils.read_with_timeout(socket, nil, @timeout)
          raise "Bad tcp resp: #{t}" unless t.bytesize > 2
          t.byteslice(2..-1)
        else
        end
      Message.decode(data)
    rescue RuntimeError, SystemCallError => e
      $logger.warn { "#{e.message}: #{Utils.makekey(hostname, typeclass)} #{@type}:#{@host}:#{@port}(timeout=#{@timeout})" }
      Message.new.tap { |r|
        r.qr = 1
        r.rd = 1
        r.rcode = 2
        r.add_question(hostname, typeclass)
      }
    rescue => e
      raise "#{Utils.makekey(hostname, typeclass)} #{@type}:#{@host}:#{@port}(timeout=#{@timeout}): #{e.message}" + e.backtrace.map{|s|"\n    "+s}.join("")
    end
  end
end

class MultiResolver
  def initialize(*clients)
    @clients = clients
  end

  def resolv(hostname, typeclass)
    queue = Queue.new
    @clients.each { |client|
      Thread.new {
        data = client.resolv(hostname, typeclass)
        queue.push([data, client])
      }
    }
    data = nil
    client = nil
    popcount = 0
    begin
      data, client = queue.pop()
      popcount += 1
      break if popcount >= @clients.size
    end until data.rcode == 0 || data.rcode == 3
    $logger.debug { "first_of_multi.use: " + client.inspect }
    data
  end
end

class CachedResolver
  def initialize(cache, client)
    @cache = cache
    @client = client
  end

  def resolv(hostname, typeclass)
    key = Utils.makekey(hostname, typeclass)
    if @cache.has_key?(key)
      @cache[key]
    else
      v = @client.resolv(hostname, typeclass)
      if v.rcode == 0 || v.rcode == 3 # 0 => no error, 3 => non-existent domain
        @cache[key] = v
      else
        @cache.fetch(key, v)
      end
    end
  end
end

class DomainMatchingResolver
  def initialize(*rules)
    @rules = rules.map { |rule|
      cond, client = rule
      if cond.instance_of?(Array)
        regex = RegexpTrie.build(cond.map { |s| s.reverse } .map { |s| s[-1] != "." and s + "$" or s }).gsub(/\\\$/, '$')
        [Regexp.new("^" + regex), client]
      elsif cond == "*"
        rule
      else
        raise ArgumentError.new("unknown rule: " + cond.inspect)
      end
    }
  end

  def resolv(hostname, typeclass)
    rhost = hostname.reverse
    _, client = @rules.find { |cond, _|
      cond.instance_of?(Regexp) and cond.match(rhost) or cond == "*"
    }
    raise ArgumentError.new("Can't match any rule: " + hostname) if client.nil?
    client.resolv(hostname, typeclass)
  end
end

class StaticIpResolver
  def initialize(*ips)
    @ips = { Resource::IN::A => ips } # TODO: 支持 AAAA
  end

  def resolv(hostname, typeclass)
    Message.new.tap { |r|
      r.qr = 1
      r.rd = 1
      r.add_question(hostname, typeclass)
      @ips.fetch(typeclass, []).shuffle.each { |ans|
        r.add_answer(hostname, 60, typeclass.new(ans))
      }
    }
  end
end

def A(a) Resource::IN::A.new(a) end
def CNAME(a) Resource::IN::CNAME.new(Name.create(a)) end
def TXT(t) Resource::IN::TXT.new(t) end

class StaticTableResolver
  # @param table: [string, Resource]
  def initialize(table, next_hop)
    @table = table
    @next_hop = next_hop
  end

  def resolv(hostname, typeclass)
    ans = @table.find { |t| t[0] == hostname and t[1].class == typeclass }
    if ans
      Message.new.tap { |r|
        r.qr = 1
        r.rd = 1
        r.add_question(hostname, typeclass)
        r.add_answer(hostname, 60, ans[1])
      }
    else
      @next_hop.resolv(hostname, typeclass)
    end
  end
end

def tcp(ip, port = 53, timeout = 10)
  DNSClient.new(:tcp, ip, port, timeout)
end

def udp(ip, port = 53, timeout = 10)
  DNSClient.new(:udp, ip, port, timeout)
end

def first_of_multi(*clients)
  MultiResolver.new(*clients)
end

$cache = nil

class CacheListener
  def update(*args)
    $logger.debug { "cache.event: #{args}" }
  end
end

def cached(client)
  if not $cache
    $cache = LCache.new($cache_option)
    Thread.new {
      loop {
        sleep 60
        $logger.debug { "evict.start: size=#{$cache.size}" }
        $cache.evict!
        $logger.debug { "evict.done: size=#{$cache.size}" }
      }
    }
    $cache.add_observer(CacheListener.new)
  end
  CachedResolver.new($cache, client)
end

def match_domain(*rules)
  DomainMatchingResolver.new(*rules)
end

def static_ip(*ips)
  StaticIpResolver.new(*ips)
end

def static_table(table, next_hop)
  StaticTableResolver.new(table, next_hop)
end

# begin main

require_relative 'duration'
configfile = ENV.fetch('CONFIG', './config.rb')
$logger.info { "config.load: #{configfile}" }
load(configfile)

# https://stackoverflow.com/questions/9687703/redirect-stdout-and-stderr-in-real-time
STDOUT.sync = true

host, port =
  if ARGV.empty?
    ['127.0.0.1', 53]
  elsif ARGV.size == 1 && /^[0-9]+$/ =~ ARGV[0]
    ['127.0.0.1', ARGV[0].to_i]
  elsif ARGV.size == 1
    [ARGV[0], 53]
  else
    ARGV
  end

closing = false
socket = UDPSocket.new
socket.bind(host, port)
$logger.info { "dns.start: #{host}:#{port}" }

trap(:INT) { closing = true }
trap(:TERM) { closing = true }

while not closing
  if IO.select([socket], nil, [socket], 1)
    data, (_, remote_port, _, remote_ip) = socket.recvfrom(512)
    Thread.fork(data, remote_ip, remote_port) { |data, remote_ip, remote_port|
      begin
        req = Message.decode(data)
        name, typeclass = req.question.first # 一般可以认为只有一个 question
        $logger.info { "resolv.req: " + Utils.makekey(name.to_s, typeclass) }
        resp = $resolver.resolv(name.to_s, typeclass)
        resp.id = req.id
        socket.send(resp.encode, 0, remote_ip, remote_port) # TODO: socket 能否安全地在多个线程间共享？
      rescue Resolv::DNS::DecodeError => e
        $logger.warn { "decode.failed: #{data}" }
      end
    }
  end
end

$logger.info { "dns.exit" }
