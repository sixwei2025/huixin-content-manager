# 公众号官方接口联调记录

袁六伟 · 台州汇芯（公众号/视频号：袁六伟）

## GitHub 参考项目

本次重点参考了 [Yellowsoy/gzh-data-dashboard](https://github.com/Yellowsoy/gzh-data-dashboard)。这是一个专门做微信公众号运营数据看板的开源项目，使用微信公众平台官方接口，并明确记录了 `48001 api unauthorized` 的处理方式：通常表示账号未认证，或没有开通数据统计类接口权限。

## 本次真实联调结果

测试路径：腾讯云固定出口服务器 → 微信公众平台官方 API。凭证内容没有写入本仓库，也没有在日志中输出。

| 官方接口 | 结果 |
|---|---|
| `/cgi-bin/token` | 成功，说明 AppID、AppSecret 和 IP 白名单有效 |
| `/datacube/getusersummary` | `48001 api unauthorized` |
| `/datacube/getusercumulate` | `48001 api unauthorized` |
| `/datacube/getbizsummary` | `48001 api unauthorized` |
| `/datacube/getuserread` | `48001 api unauthorized` |
| `/datacube/getarticleread` | `48001 api unauthorized` |
| `/datacube/getarticleshare` | `48001 api unauthorized` |
| `/datacube/getarticletotaldetail` | `48001 api unauthorized` |
| `/cgi-bin/freepublish/batchget` | `48001 api unauthorized` |

## 结论

这不是本地网络、服务器白名单、AppID 或 AppSecret 错误。因为 token 已经获取成功，并且请求已经从白名单服务器发出。当前账号对官方数据接口没有权限，代码层面没有一个“换 endpoint”可以绕过这个限制。

产品因此继续遵守以下边界：

1. 不抓取公众号后台页面来伪造官方数据；
2. 不把 token 成功误报为数据接口已开通；
3. 应用内明确提示“凭证有效，但账号未开通数据统计接口权限”；
4. 在权限开通前，使用 CSV 手动导入作为可用降级路径；
5. 一旦账号开通权限，优先通过白名单服务器中继，再把同一组官方接口接入看板。

袁六伟 · 台州汇芯（公众号/视频号：袁六伟）

