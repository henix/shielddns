#!/usr/bin/env ruby

require 'logger'
require 'resolv'
require 'socket'

require 'concurrent/collections'

require_relative 'lcache'
require_relative 'regexptrie'

Message = Resolv::DNS::Message
Resource = Resolv::DNS::Resource

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
  def initialize(type, host, port = 53)
    @type = type
    @host, @port = host, port
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
    data = case @type
    when :udp
      $logger.info { "udp.send: #{Utils.makekey(hostname, typeclass)} #{@host}:#{@port}" }
      s = UDPSocket.new
      s.send(req.encode, 0, @host, @port)
      resp, _ = s.recvfrom(512)
      s.close
      resp
    when :tcp
      $logger.info { "tcp.send: #{Utils.makekey(hostname, typeclass)} #{@host}:#{@port}" }
      s = TCPSocket.new(@host, @port)
      data = req.encode
      s.send([data.bytesize].pack('n') + data, 0)
      resp = s.read
      s.close
      resp.byteslice(2..-1)
    else
      raise ArgumentError.new(@type.inspect)
    end
    Message.decode(data)
  end
end

class MultiResolver
  def initialize(*clients)
    @clients = clients
  end

  def resolv(hostname, typeclass)
    ringbuffer = Concurrent::BlockingRingBuffer.new(@clients.size)
    @clients.each { |client|
      if ringbuffer.empty?
        Thread.new {
          if ringbuffer.empty?
            data = client.resolv(hostname, typeclass)
            ringbuffer.put([data, client])
          end
        }
      end
    }
    data, client = ringbuffer.take
    $logger.info { "first_of_multi.use: " + client.inspect }
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
    @cache.get_or_update(key) {
      @client.resolv(hostname, typeclass)
    }
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
        r.add_answer(hostname, 30, typeclass.new(ans))
      }
    }
  end
end

def tcp(ip, port = 53)
  DNSClient.new(:tcp, ip, port)
end

def udp(ip, port = 53)
  DNSClient.new(:udp, ip, port)
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
        $logger.debug { "evict.start" }
        $cache.evict!
        $logger.debug { "evict.done" }
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

# begin main

require_relative 'duration'
configfile = ENV.fetch('CONFIG', './config.rb')
$logger.info { "config.load: #{configfile}" }
load(configfile)

require 'pattern-match'
using PatternMatch

host, port = match(ARGV) {
  with(_[]) { ['127.0.0.1', 53] }
  with(_[/[0-9]+/.(p)]) { ['127.0.0.1', p] }
  with(_[h]) { [h, 53] }
  with(a) { a }
}

closing = false
socket = UDPSocket.new
socket.bind(host, port)
$logger.info { "dns.start: #{host}:#{port}" }

exit_handler = proc {
  closing = true
  s = UDPSocket.new
  s.send("", 0, host, port)
  s.close
}
trap(:INT, exit_handler)
trap(:TERM, exit_handler)

loop {
  data, (_, remote_port, _, remote_ip) = socket.recvfrom(512)
  if closing
    break
  end
  Thread.fork(data, remote_ip, remote_port) { |data, remote_ip, remote_port|
    req = Message.decode(data)
    name, typeclass = req.question.first # 一般可以认为只有一个 question
    $logger.info { "resolv.req: " + Utils.makekey(name.to_s, typeclass) }
    resp = $resolver.resolv(name.to_s, typeclass)
    resp.id = req.id
    socket.send(resp.encode, 0, remote_ip, remote_port) # TODO: socket 能否安全地在多个线程间共享？
  }
  Thread.pass
}
socket.close
$logger.info { "dns.exit" }
