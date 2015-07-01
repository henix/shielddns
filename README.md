# ShieldDNS

基于域名规则抗 DNS 污染。

## 安装

依赖 Ruby ，Windows 用户推荐使用 Cygwin 。

```bash
git clone https://github.com/henix/shielddns.git
gem install bundler

cd shielddns
bundle install --path vendor/bundle
```

## 配置

配置文件 config.rb 样例：

```ruby
$cache_option = {
  :ttl => 1.hour,
  :max_size => 1024
}
ext_resolver = cached(match_domain(
  [[".youtube.com"], udp("127.0.0.1", 5343)],
  [[
    "twitter.com", ".twitter.com", ".twimg.com", ".twitpic.com",
    ".facebook.com", ".facebook.net",
    ".flickr.com",
    ".dropbox.com",
    "plus.google.com", ".googlevideo.com", ".appspot.com", ".blogger.com",
    ".wordpress.com", ".gravatar.com", ".wp.com",
    ".typekit.com", ".typekit.net",
    ".greatfire.org",
    ".ytvpn.com", ".yuntivpn.com",
    ".zendesk.com",
    ".wikipedia.org",
    ".torproject.org",
    ".archive.org",
    ".openvpn.net",
    "docs.oracle.com"
  ], first_of_multi(tcp("8.8.8.8"), tcp("8.8.4.4"))],
  ['*', udp("114.114.114.114")]
))
$resolver = match_domain(
  # 屏蔽广告
  [["u291014.778669.com", "d3d.3dwwwgame.com", "p.ko499.com", "shadu.baidu.com.shadu110.com", "p.3u5.net", "game.weibo.com", "static.atm.youku.com", "ads.clicksor.com", "focus.inhe.net", "fpcimedia.allyes.com", "pos.baidu.com", "isearch.babylon.com", "c.qiyou.com", "s.ad123m.com", "ads.adk2.com", "syndication.twitter.com", "www.firefox.com.cn", "ad.adtina.com", "cdn.shdsp.net", "cms.gtags.net", "api.miwifi.com"], static_ip("0.0.0.0")],
  # 如果你有可用的 Google IP ，可修改下面这条规则的 GoogleIp
  [[".google.com", ".google.com.hk", ".google.co.jp", ".googleusercontent.com", ".ggpht.com", ".gstatic.com", ".googleapis.com", "www.gmail.com", "goo.gl", ".googlecode.com", ".youtube.com", ".ytimg.com", ".chrome.com", ".feedburner.com", ".recaptcha.net", ".blogger.com", ".blogblog.com"], static_ip(GoogleIp)],
  ['*', ext_resolver]
)
```

基本原理：

* 某些被污染域名可以通过 tcp 查询国外服务器解决。
* 另外一些用上面的方法也不行，如 *.youtube.com 。可通过 [DNSCrypt](http://dnscrypt.org/) 解决。上面的配置要想正常使用需要在 5343 端口运行 DNSCrypt。

配置文件注意点：

* 配置文件必须创建 `$cache_option` 和 `$resolver` 这两个全局变量。
* cached 的位置可以是任意的。上面的样例中，静态 ip 的两条规则没有使用 cache。

## 运行

可用如下方法指定绑定地址、端口，以及配置文件路径：

```bash
bundle exec ruby shielddns.rb
bundle exec ruby shielddns.rb 0.0.0.0
bundle exec ruby shielddns.rb 5353
bundle exec ruby shielddns.rb 0.0.0.0 5353
env CONFIG=/path/to/config.rb bundle exec ruby shielddns.rb
```

按 Ctrl-C 退出，Cygwin 中需要按两次。

## 支持的 Resolver 组合子

* tcp / udp: 一个上游 tcp / udp DNS 服务器
* first_of_multi: 同时向多个 resolver 发送请求，使用最先返回的结果
* match_domain: 用域名从上往下依次匹配，使用匹配到的第一条所指定的 resolver
	- 规则可以是一个字符串数组，数组中的每一项，如果以“.”开头，表示匹配域名的后缀
	- 或者 '*' 表示匹配任意域名
* cached: 在另一个 resolver 前面套一个全局缓存
* static_ip: 直接指定一组 ip 地址

## 缓存过期策略

1. ttl: 可选，每条记录最多缓存多长时间
2. max_size: 可选，最多缓存多少条记录，当超过这个数字时，使用 LRU 算法清除缓存。
