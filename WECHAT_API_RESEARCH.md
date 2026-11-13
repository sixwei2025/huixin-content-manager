# 公众号官方接口联调记录

袁六伟 · 台州汇芯（公众号/视频号：袁六伟）

## GitHub 参考项目

本次重点参考了 [Yellowsoy/gzh-data-dashboard](https://github.com/Yellowsoy/gzh-data-dashboard)。这是一个专门做微信公众号运营数据看板的开源项目，使用微信公众平台官方接口，并明确记录了 `48001 api unauthorized` 的处理方式：通常表示账号未认证，或没有开通数据统计类接口权限。

另外两个 GitHub 设计文档给出了更直接的能力矩阵：[hou-cli 的公众号工具设计](https://github.com/jthou/hou-cli/blob/master/docs/design/wechat-mp-tool-design.md) 将个人未认证号限定为 token、草稿箱和图片上传，把发布与数据统计标为不可用；[SpecWeave 的公众号采集规格](https://github.com/xinetzone/SpecWeave/blob/main/.trae/specs/wechat-mp-content-archiver/spec.md) 也把官方 API 作为认证账号的条件性补充，并将后台采集路线单独列为非官方方案。

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

## 产品降级路线

在当前账号类型下，本产品仍然可以作为内容经营工具使用：内容库、平台卡片、CSV 指标导入、复盘和本地保存都可用；公众号统计卡片在没有权限时必须显示“未开通官方统计接口”，而不是显示一组演示数字。若要读取官方粉丝与阅读数据，实际可行的路径只有：使用已认证且具备数据统计权限的公众号，或继续使用平台后台导出的 CSV。

袁六伟 · 台州汇芯（公众号/视频号：袁六伟）

