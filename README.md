# ShieldDNS

基于域名规则抗 DNS 污染。

## 安装

依赖 Ruby ，Windows 用户推荐使用 Cygwin 。

```bash
git clone https://github.com/henix/shielddns.git
```

## 配置

配置文件 config.rb 样例：

```ruby
$cache_option = {
  :ttl => 1.day,
  :max_size => 1024
}

google_dns_tcp = first_of_multi(tcp("8.8.8.8"), tcp("8.8.4.4"))
opendns = first_of_multi(udp("208.67.220.220", 5353), udp("208.67.222.222", 5353))

ext_resolver = cached(match_domain(
  [[
    ".youtube.com",
    ".minghui.org", ".epochtimes.com", ".ntdtv.com",
    "twitter.com", ".twitter.com",
    ".facebook.com", ".facebook.net"
  ], opendns],
  ['*', google_dns_tcp]
))

$resolver = match_domain(
  # 屏蔽广告
  [["pos.baidu.com", ".miwifi.com",
    ".crash-analytics.com", ".icloud-analysis.com", ".icloud-diagnostics.com" # XcodeGhost
  ], static_ip("0.0.0.0")],
  ['*', ext_resolver]
)
```

基本原理（感谢 fqrouter 的 [翻墙路由器的原理与实现](http://drops.wooyun.org/papers/10177) 一文）：

* DNS 污染可以通过 tcp 查询国外服务器解决。这里首选 Google DNS。
* 另外一些用上面的方法会被 tcp reset，可通过查询非标准端口（53）的服务器解决。OpenDNS 支持 5353 端口。

配置文件注意点：

* 配置文件必须创建 `$cache_option` 和 `$resolver` 这两个全局变量。
* cached 的位置可以是任意的。上面的样例中，静态 ip 的规则没有使用 cache 。

## 运行

可用如下方法指定绑定地址、端口，以及配置文件路径：

```bash
ruby shielddns.rb
ruby shielddns.rb 0.0.0.0
ruby shielddns.rb 5353
ruby shielddns.rb 0.0.0.0 5353
env CONFIG=/path/to/config.rb ruby shielddns.rb
```

## 支持的 Resolver 组合子

* tcp / udp: 一个上游 tcp / udp DNS 服务器
* first_of_multi: 同时向多个 resolver 发送请求，使用最先返回的结果
* try: 依次尝试多个 resolver（如果超时或返回服务器错误）
* match_domain: 用域名从上往下依次匹配，使用匹配到的第一条所指定的 resolver
	- 规则可以是一个字符串数组，数组中的每一项，如果以“.”开头，表示匹配域名的后缀
	- 或者 '*' 表示匹配任意域名
* cached: 在另一个 resolver 前面套一个全局缓存
* static_ip: 直接指定一组 ip 地址

## 缓存过期策略

1. ttl: 可选，每条记录最多缓存多长时间。
2. max_size: 可选，最多缓存多少条记录，当超过这个数字时，使用 LRU 算法清除缓存。
