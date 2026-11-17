# 真后台实时更新(APNs 推送)接入指南

App 被系统挂起后无法自己更新实时活动。本目录提供一套**自托管**的最小方案:

```
iPhone App ──上报 token+状态──▶ 中转(Cloudflare Worker/KV) ◀──拉取── Mac 网关 ──APNs──▶ 锁屏/灵动岛
                                    ▲
                          Mac 网关另读 ZCode 桌面日志
                     (pendingPermissions / runningTasks)
```

## 1. 准备 APNs 密钥

1. 打开 [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list),新建 Key,勾选 **Apple Push Notifications service (APNs)**
2. 下载 `AuthKey_XXXXXXXXXX.p8`(只能下载一次),记下 **Key ID**
3. 记下你的 **Team ID**(账号页右上角)

## 2. 部署中转(Cloudflare Worker)

```bash
npm i -g wrangler
wrangler login
wrangler kv namespace create LA_STATE      # 记下返回的 id
```

新建 `wrangler.toml`:

```toml
name = "zcode-mobile-push"
main = "cloudflare-worker.js"
compatibility_date = "2026-01-01"

[[kv_namespaces]]
binding = "STATE"
id = "<上一步的 id>"
```

```bash
wrangler deploy
```

得到形如 `https://zcode-mobile-push.<你>.workers.dev` 的地址。

## 3. 运行 Mac 网关

```bash
RELAY_URL=https://zcode-mobile-push.<你>.workers.dev \
SECRET='换成随机长串' \
APNS_KEY_PATH=/path/to/AuthKey_XXXX.p8 \
APNS_KEY_ID=XXXXXXXXXX \
APNS_TEAM_ID=你的TeamID \
BUNDLE_ID=dev.example.ZCodeMobile \
APNS_ENV=sandbox \
node server/mac-gateway.mjs
```

- `APNS_ENV`:自签/开发版用 `sandbox`;TestFlight/App Store 用 `production`
- 需要 Node 18+
- 想开机常驻可用 launchd 或 `nohup`;日志里应看到 `[gateway] push running/awaitingApproval ... → ok`

## 4. 在 App 内启用

设置 → **真后台推送(可选)**:

- 打开「启用真后台更新」
- 中转地址:第 2 步的 Worker 地址
- 密钥:与网关的 `SECRET` 一致

打开一个会话后,App 上报 token 与状态;之后锁屏,审批/运行状态变化会由网关推送更新。

## 安全说明

- 中转只存一条记录(push token + 状态),用 `SECRET` 保护;请使用足够长的随机串
- APNs 私钥只保存在你 Mac 上,不经过中转
- push token 会随活动重新创建而变化,App 会自动重新上报
