# ZCode 远程控制协议 中继客户端 + 认证(Swift 实现规格)

> 目标:为 Swift(桌面 3.18.2 对应的 **V2 账号制**)中继客户端提供可直接实现的精确规格。
> 依据:`/Users/you/zcode-mobile-refs` 下四份参考实现 + 官方 Web bundle 静态提取 + 真机实测记录(全部结论标注来源)。
> 本文只覆盖**中继连接层 + 认证层 + bootstrap/开桥**;会话帧(Vql/204)、Controller 通道等业务层另行成文。
> 字段名一律保留协议原文(snake_case)。不确定处标 [存疑]。

## 0. 参考实现清单与采信优先级

| 优先级 | 实现 | 路径 | 说明 |
|---|---|---|---|
| ★★★ | zcode-remote-app PROTOCOL.md | `zcode-remote-app/PROTOCOL.md` | 逆向+真机实测结论,含 §11(V2)/§12(SID 接续)/§13(3.18.1) |
| ★★★ | 新版 Android App(com.zcode.remote) | `zcode-remote-app/app-android/app/src/main/java/com/zcode/remote/` | **唯一完整实现 V2 的参考**(RelayClient/V2AccountApi/V2RetryPolicy/RpcChannel),2026-11-15 仍在维护,536 项单测钉口径 |
| ★★☆ | probe.py(协议探针) | `zcode-remote-app/tools/probe.py` | 独立第二实现,V2 直连(`ws2`)实测样本来源 |
| ★★☆ | 官方 Web bundle(2026-09-13 拉取,V1 时代) | `ZCode-Android/zcode_downloaded/remote/v4/assets/index-nOVzQNKW.js`、`ZCode-Android/analysis/official/index.js` | OAuth(Z.ai)与心跳/重连官方原始逻辑的静态证据;**不含 V2 `ws2`/`/api/v1/remote/*`**(该部分在 3.16+ 版本化 bundle,仓库未留存) |
| ★☆☆ | ZLinker(Flutter) | `ZLinker/lib/protocol/` | V1 直连的反向移植,类结构清晰适合对照,**无 V2** |
| ★☆☆ | zemote(Flutter)/ ZCode-Android(app.zemote,旧版) | `zemote/lib/protocol/`、`ZCode-Android/app/src/main/java/app/zemote/protocol/` | 同一血统的 V1 硬化分支(10s 心跳/KICKED 抢回),**无 V2**,仅做差异参考 |

冲突时的采信顺序:**新版 Android App ≈ PROTOCOL.md 实测 > 官方 bundle 静态 > probe.py > ZLinker/zemote**。心跳/退避数值以 PROTOCOL.md §4.1(2026-11-14 官方源码勘误)为最终口径。

---

## 1. 总览:V2 认证与连接链路

```
[用户] 扫桌面端二维码(仅 sid/mid/name/app_version)
   → QrParser: passHash 为空 ⇒ ProtocolStack.V2 ⇒ NeedsLogin
[登录] 打开官方落地页 https://zcode.z.ai/remote/v4?sid=&mid=&name= (WebView)
   → 用户选「连接 Z.ai」或「连接 BigModel」完成 OAuth
   → 收割 localStorage["zcodejwttoken"] ⇒ 加密持久化(钥匙串)
[连 REST] POST /api/v1/remote/token {role:"terminal"}  (Bearer JWT) → data.token(短时效 60s)
[连 WS]  wss://<origin>/api/v1/remote/ws2?token=<t>&mid=<mid>  (Origin 头必带)
[握手]   → auth_init{device_sid, meta, client_ts(秒)}   (无 role、无 proof)
         ← auth_ack{device_sid, terminal_sid, pair_status: waiting|matched, server_ts}
[心跳]   pair_status_query{client_ts(秒)}  每 5s±1s;15s 无任何 ack ⇒ 重连
[业务]   {"type":"data","payload":{zcode_type...},"client_ts":<毫秒>}
```

要点(全部实测,来源 PROTOCOL.md §11.3):
- **V2 无 challenge/proof**。`auth_ack` 一帧直达。在 `ws2` 上收到 `auth_challenge` = 协议异常(端点/版本错乱),按 `PROTOCOL_MISMATCH` 终态处理。
- **V1 端点 `wss://zcode.z.ai/ws` 不认 token**:带 token 连 `/ws` 会收 `error WRONG_PARAM`;`/ws` 上 auth_init 带 `role` 字段对 V2 schema 也是未知字段(strictObject 拒绝)。
- JWT 换 token、token 连 WS,**token 每次连接前现取**(`expires_in` 实测 60s,不要缓存)。

---

## 2. 二维码解析与协议栈判定

V2(≥3.16)二维码(官方 `buildWebRemoteControlExternalQrUrl`,`hash`/`t` 被显式 `delete`):

```
https://zcode.z.ai/remote/v4?sid=<deviceSid>&mid=<deviceMid>&name=<PC名>&app_version=<桌面版本>
```

解析规则(采 Kotlin `PairedDevice.kt` / `QrParser`,全仓唯一判据):

- `sid` 缺失 ⇒ 解析失败。
- `hash` 非空 ⇒ V1(本实现不支持,直接报「请升级桌面端」或按 V1 走,超出本文)。
- `hash` 空/缺 ⇒ **V2**,凭据走登录链路。
- 解析 query 前先把字面 `+` 预转义为 `%2B`(V1 hash 是 base64url 前原文可能含 `+`;V2 保守同处理,官方 URLSearchParams 生成端同语义)。
- 保存四元组:`deviceSid`(PC 的 sid)、`deviceMid`(PC 机器 ID,SID 接续与 WS `mid` 参数用)、`deviceName`、`remoteUrl`(去 query 的 base,推导 origin)。
- 派生:`relayWsUrl = wss://<host>/api/v1/remote/ws2`(host 取 QR 的 origin;`chatglm.site` 备线同样按 origin 推导)。

Swift 建议数据模型(对照 Kotlin `PairedDevice`):

```swift
struct PairedDevice: Codable {
    let deviceSid: String        // "d_..."
    let passHash: String?        // V2 恒 nil;非 nil ⇒ V1(不支持)
    let deviceMid: String?       // 机器 ID,WS query 参数 + SID 接续键
    let deviceName: String?
    let remoteUrl: String        // https://zcode.z.ai/remote/v4 (去 query)
    var protocolStack: ProtocolStack { passHash == nil || passHash!.isEmpty ? .v2 : .v1 }
}
```

---

## 3. V2 账号登录(OAuth)

### 3.1 总策略(采信:Android App 实测可行的最简路径)

**不自行实现 OAuth 跳转的收尾,用内嵌 WebView 打开官方落地页,让官方页面完成两条 OAuth 路,登录完成只收割 JWT**。这是 Android App(WebViewActivity.kt)实测走通的做法,同样适用于 WKWebView。理由:
- Z.ai 路 OAuth 回调地址是 `https://zcode.z.ai/web-remote/callback`(见 §3.3),**不是自定义 URL scheme** ——原生 App 无法直接拦截回调,要么全原生复刻(可行,见 §3.3),要么让官方页跑完全程;
- BigModel 路(互信跳转)的 token 交换端点在 bigmodel.cn 侧,静态提取不全,原生复刻风险高 [存疑:bigmodel 回跳后的交换端点未逆向];
- 登录态(Cookie + localStorage)随 WebView 持久化,二次登录免输。

### 3.2 落地页 URL(terminal 入口)

```
https://zcode.z.ai/remote/v4?sid=<deviceSid>&mid=<deviceMid>&name=<urlEncoded PC名>
```

- Kotlin `WebViewLogin.landingUrl()` 构造(带 sid 必带,mid/name 尽量带;空格编码 `%20` 不是 `+`)。
- 官方 Web bundle 按 `app_version` 版本化(`/remote/v4/<ver>/assets/...`),落地页是入口状态机「登录态 → 设备列表 → 连接」三分支,无登录态显示 "Web Remote Control Sign In"(标题实测),两个按钮:「连接 Z.ai(全球)」「连接 BigModel(中国)」。**要求与电脑端相同的登录平台与同一账号**。

### 3.3 Z.ai 路(全原生复刻用;静态提取自官方 bundle `G2t`/`S2t`/`w2t` 类)

配置(构建期常量,bundle 内嵌,无需动态获取):

```
authorizeUrl  = https://chat.z.ai/api/oauth/authorize        // = `${VITE_ZAI_OAUTH_ORIGIN}/api/oauth/authorize`
tokenUrl      = /api/v1/oauth/token                          // 相对路径 → 实际 https://zcode.z.ai/api/v1/oauth/token
clientId      = client_P8X5CMWmlaRO9gyO-KSqtg               // VITE_ZAI_OAUTH_CLIENT_ID
redirectUri   = https://zcode.z.ai/web-remote/callback      // webRemoteCallbackUrl(dev 时 `${devOrigin}/web-remote/callback`)
```

精确序列(官方 `G2t.startLogin` → `S2t.buildAuthorizeUrl` → 回调 → `S2t.exchangeToken`):

1. **startLogin**: `nonce = UUID()`(crypto.randomUUID;退化:16 字节随机 hex);持久化 nonce(官方存 sessionStorage `oauth_pending_nonce`;原生存内存/Keychain 临时)。
2. **state** = `base64url_no_pad(JSON.stringify({nonce, app_return_to: <当前落地页URL>}))`
   (编码:UTF-8 → btoa → `+`→`-`、`/`→`_`、去尾部 `=`)。
3. **跳转 authorize**(整串 URLSearchParams):
   ```
   https://chat.z.ai/api/oauth/authorize
     ?redirect_uri=https%3A%2F%2Fzcode.z.ai%2Fweb-remote%2Fcallback
     &response_type=code
     &client_id=client_P8X5CMWmlaRO9gyO-KSqtg
     &state=<上一步 state>
   ```
4. **回调**:`https://zcode.z.ai/web-remote/callback?code=<授权码>&state=<原样回传>`。
   判定条件(官方 `D4t`):`pathname === /web-remote/callback && has(state) && (has(code) || has(error))`;**`authCode` query 参数与 `code` 等价**(官方优先 `code` 再取 `authCode`)。
5. **校验**:parse state(JSON.parse(base64url_decode))→ `nonce` 必须等于第 1 步存的值(CSRF),不等即失败;有 `error` 参数即失败。
6. **换 token**:
   ```
   POST https://zcode.z.ai/api/v1/oauth/token
   Content-Type: application/json
   {"code":"<授权码>","redirect_uri":"https://zcode.z.ai/web-remote/callback","state":"<state>"}
   ```
7. **响应**(官方 `x2t` 解析,统一信封):
   ```json
   {
     "code": 0, "msg": "",
     "data": {
       "token": "<204 字符标准 JWT —— 这就是 zcodejwttoken>",
       "zai": { "access_token": "<z.ai access token>" },
       "user": { "id": "...", "username": "...", "displayName": "...", "avatarUrl": "..." },
       "expires_in": <秒数>
     }
   }
   ```
   `code!==0` 抛错(`msg` 为错误文案);`data.token`、`data.zai.access_token`、`data.user` 任缺即错。
8. **存储**(官方 localStorage 键,原生对应 Keychain):
   - `zcodejwttoken` = `data.token`(**远程控制 REST/换 relay token 的唯一凭据**)
   - `oauth:zai:access_token` = `data.zai.access_token`(z.ai 业务用,远程控制不需要)
   - `oauth:zai:user_info` = JSON(user)(展示用)
   - `oauth:active_provider` = `"zai"`
   - 可选记录 `expiresAt = now + expires_in*1000`(官方 `b2t` 计算)

### 3.4 BigModel 路(中国区)

实测形态(PROTOCOL.md §11.2 + probe.py `loginurl` 命令,与官方登录页「连接 BigModel」按钮同形):

```
https://bigmodel.cn/login
  ?redirect=<落地页URL>          # 登录后回跳的落地页(带 sid/mid 等)
  &appId=zcode                   # 常量
  &state=<base64url_no_pad(JSON{"nonce":uuid, "app_return_to":<落地页URL>})>
```

- 用户在 bigmodel.cn 完成登录后回跳落地页;凭据由官方落地页侧写入 web storage(`zcodejwttoken`);**交换端点在 bigmodel/落地页侧,未逆向** [存疑:BigModel 路无原生复刻规格,必须走 WebView]。
- BigModel 登录页对 WebView UA 敏感:Android 实测默认 UA 带 `; wv` 标记时整页白屏,需去掉该标记按移动浏览器身份加载(Android `WebViewActivity` 实证;iOS WKWebView 默认 UA 无此标记,一般无碍,若白屏可同法处理)。
- WebView 需:跨域跳转全放行(不拦截导航)、Cookie(含三方)持久化、`domStorageEnabled`(localStorage)、JS 开启。

### 3.5 登录完成判定与收割(Android `WebViewActivity` 契约,Swift 照搬)

双完成条件(先到先收,`LoginCompletionGuard` 保证只完成一次):
1. 页面 URL 带 `hash=`(V1 凭据形态回调;**V2 实测不走此路**,仅兜底,Swift V2-only 可不做);
2. `localStorage.getItem('zcodejwttoken')` 非空 ⇒ 写入加密存储(Keychain)⇒ 登录完成,回传设备。

轮询时机:每次 `onPageFinished`(iOS `WKNavigationDelegate.didFinish`)后 evaluateJavaScript 收割一次;三方 OAuth 页(bigmodel/chat.z.ai)本身无该键,收割自然为空,不误判。注意官方 Web 是 SPA,登录完成可能不触发新的 didFinish ——可加 1~2s 间隔的短轮询兜底 [存疑:Android 未加轮询,依赖用户操作触发的导航;实测够用]。

### 3.6 JWT 的存储、有效期与"刷新"

- **无 refresh token**。官方 `restoreCachedSessionState` 启动时校验 JWT(JWT 标准 `exp` 声明):过期 ⇒ `clearAll()` + `reauthentication-required` ⇒ 重新登录(web 弹「登录已过期」)。Swift 同口径:启动/连接前解 JWT `exp`(base64url decode payload),过期即清 Keychain 并引导重登。
- JWT 本体:204 字符标准 JWT(三段式,HS/RS 签名未验,客户端不验签,只读 `exp`)。
- **relay token(22 字符短串,`expires_in` 60s)** 与 JWT 是两回事:每次建 WS 前用 JWT 现换(§4.2),绝不缓存复用。
- token 接口鉴权失败(HTTP 401/403 或业务码拒绝)⇒ JWT 已失效 ⇒ `AUTH_FAILED` 终态 + 重新登录指引(Kotlin `V2AccountApi.TokenAuthException` / `isAuthFailure`:401/403 或 `IllegalStateException("api code=...")` 归为鉴权类,其余(DNS/超时/重置)归网络类可重试)。**这一分类必须有**,否则登录失效会被当网络错误无限重连(真机教训 T10)。

---

## 4. REST API 精确定义(V2,`/api/v1/remote/*`)

Base URL:`https://zcode.z.ai`(按配对 QR 的 origin 推导;`chatglm.site` 备线同构)。
所有请求头:

```
Authorization: Bearer <zcodejwttoken>
Content-Type: application/json    (仅带 body 时)
```

**不存在 `X-Device-Mid` 之类的自定义头**(全部参考实现与官方 bundle 均无;任务书提及的该头未获证据,`mid` 只作为 WS query 参数出现)。官方 bundle 中唯一自定义头是 `X-ZCode-Mobile-Connection-Id`,属**桌面内嵌面板**本地同源路径,与手机配对无关(§11.5 归属确认),不要实现。

### 4.1 统一响应信封

```json
{ "code": 0, "msg": "...", "data": <随接口而异>, "logid": "..." }
```

- `code == 0` 成功;非 0 = 业务拒绝(具体非零码枚举未逆向 [存疑],一律按失败处理并展示 `msg`);
- HTTP 401/403 = 登录态失效(等同需要重新登录),必须与网络错误区分(§3.6);
- `logid` 仅日志追踪用。

### 4.2 `POST /api/v1/remote/token` —— JWT 换 relay token

```
POST https://zcode.z.ai/api/v1/remote/token
Authorization: Bearer <JWT>
Content-Type: application/json

{"role":"terminal"}
```

响应(实测):

```json
{ "code": 0, "msg": "", "data": { "token": "<22 字符短串>", "expires_in": 60 } }
```

- `role ∈ {"device","terminal"}`;terminal 客户端固定 `"terminal"`(PC 端注册时用 `"device"`,与手机无关)。
- token 只进 WS query 参数,**绝不能进日志**(Kotlin 只记长度)。
- 建议实现**单飞(single-flight)**:并发调用共享一次网络往返,key=(jwt, role, baseUrl),jwt 变了必须重取(Kotlin `fetchRelayTokenSingleFlight`)。
- 超时:连接 10s / 读 15s(Android 口径)。

### 4.3 `GET /api/v1/remote/device` —— 账号绑定设备列表

```
GET https://zcode.z.ai/api/v1/remote/device
Authorization: Bearer <JWT>
```

响应 `data` 实测为**数组**(官方亦兼容 `{"devices":[...]}` 包裹,两种都解析):

```json
{ "code": 0, "msg": "", "data": [
    { "device_sid": "d_xxx", "device_mid": "<机器ID>", "online": true,
      "created_at": 1792900000,
      "meta": { "name": "<PC名>", "platform": "win32", "version": "3.16.3" } }
] }
```

无任何凭据字段,纯展示/接续数据源。用途:① 设置页多设备管理;② **SID 自动接续**(§8.3)。

### 4.4 其余端点(PC 侧语义,terminal 不用,列出备查)

- `POST /api/v1/remote/device` body `{"device_mid"}` Bearer JWT → `{device_sid, device_mid, online, created_at, meta}`(设备注册,绑定账号 userId;桌面每次重注册产生**新 sid**,MID 不变)。
- `POST /api/v1/remote/device/delete` body `{"device_sid"}`。

### 4.5 服务发现(V1 时代遗留)

`GET https://zcode.z.ai/api/server-info`、`/api/rpc-host-capability`:V1 时代端点,V2 客户端不使用 [存疑:V2 是否仍引用未验证,不实现]。环境变量覆盖 `ZCODE_WEB_REMOTE_CONTROL_RELAY_WS_URL`/`ZCODE_WEB_REMOTE_CONTROL_URL` 是桌面端机制,移动端无关。

---

## 5. WebSocket 连接

### 5.1 URL 构造(V2)

```
wss://<origin>/api/v1/remote/ws2?token=<relayToken>&mid=<deviceMid>
```

- `<origin>`:配对 QR/remoteUrl 的 origin(`https://zcode.z.ai` → `wss://zcode.z.ai`;`http://` → `ws://` 仅调试)。端点路径**固定** `/api/v1/remote/ws2`(桌面端代码实证 `relayWsUrl: ${origin}/api/v1/remote/ws2`)。
- `token` 与 `mid` 均 URL-encode;`mid` 缺失时 PC 在线场景会被中继直接 `AUTH_FAILED`(官方终端总是追加;PROTOCOL.md 3.1 实测#1)。`token` 在前 `mid` 在后(Kotlin 构造顺序;参数顺序理论上无关 [存疑:未测乱序])。
- **端点校验**(采 Kotlin `RelayEndpointValidator`):结构化解析(绝不用前缀匹配),Release 只放行绝对 `wss://`(`ws://` 仅 debug);拒绝 userinfo/空 host/非法端口;校验失败 = `INVALID_ENDPOINT` 终态,**不得降级重试**。

### 5.2 Origin 头 —— 必须设置

中继校验请求头 `Origin` 与线路一致,缺失即 `AUTH_FAILED`(PROTOCOL.md 3.1 实测#2;浏览器自带,原生客户端必须手加):

```
Origin: https://<ws-host>        // wss://host/... → https://host;ws://(debug)→ http://host
```

**iOS 可行性**:`URLSessionWebSocketTask` 通过 `URLRequest.setValue("https://zcode.z.ai", forHTTPHeaderField: "Origin")` 设置后传入 `webSocketTask(with:)` 即可 —— `Origin` 不在 URLSession 的保留头列表里,可行。参考做法:
- Android OkHttp:`Request.Builder().url(url).header("Origin", origin)`(实测通过);
- 浏览器:自动带(官方 Web 端);
- 若服务端未来收紧校验(如校验 `Sec-WebSocket-*`),无原生先例 [存疑:未发现此类校验]。

传输层保活:OkHttp 参考实现设 `pingInterval(20s)`(协议层 ping/pong 帧);URLSessionWebSocketTask 有 `sendPing(interval:)`,建议 20s 同口径(非必须,心跳 watchdog 已兜底,但有助于中间盒保活)。

### 5.3 perMessageDeflate

- **不需要**。官方 Web 端只把它作为诊断信息(`socket-extensions` 事件里读 `ws.extensions` 是否含 `permessage-deflate`),不作为功能条件;OkHttp 默认不协商压缩,Android V2 直连实测通过 ⇒ 中继接受无压缩连接。
- `URLSessionWebSocketTask` 不支持 permessage-deflate 协商,**无需处理**;若未来官方强制启用 [存疑:无迹象],需换 Starscream/自定义实现。

### 5.4 帧上限(出站前本地校验,官方常量)

| 常量 | 值 | 说明 |
|---|---|---|
| `maxPhysicalFrameBytes` | 1 MiB (1048576) | 单个 data 信封 UTF-8 字节数上限(`{type,payload,client_ts}` 整体) |
| `maxMessageBytes` | 16 MiB | 单条 rpc 消息(分片重组前)上限 |
| `maxFragments` | 64 | fragmentCount 上限,fragmentIndex ∈ [0,63] |
| `assemblyTimeoutMs` | 30 000 ms | 分片重组超时 |
| `logicalFrameAssemblyMaxBytes / MaxFragments / MaxConcurrent` | 16 MiB / 1024 / 32 | 204 逻辑帧重组上限 |

出站超过 1 MiB(物理帧)必须本地拒绝(可见失败),不得截断发送。

---

## 6. V2 握手(auth_init / auth_ack / pair_status)

### 6.1 帧序列

```
→ {"type":"auth_init","device_sid":"d_...","meta":{...},"client_ts":1792939013}
← {"type":"auth_ack","server_ts":1792939014,"device_sid":"d_...","terminal_sid":"t_...","pair_status":"matched"}
```

WS onOpen 后立即发 `auth_init`;`auth_ack` 直达(无 challenge)。

### 6.2 auth_init 精确 schema(V2,桌面端 zod strictObject)

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | `"auth_init"` | |
| `device_sid` | string | **PC 的 deviceSid**(QR `sid` / 设备列表取)。terminal 与 device 用**同一个** sid 连中继,由中继按 sid 配对两角色 |
| `meta` | object? | `{platform, version, name}` 三键;值不校验,如实上报(probe 用 `"probe-v2"` 也能过) |
| `client_ts` | int(**秒**) | `Date.now()/1000`。schema 上限 253402300799(=9999 年的秒),**传毫秒必超限被拒** |
| ~~`role`~~ | **不得携带** | V1 字段;V2 strictObject 拒未知字段 ⇒ `WRONG_PARAM` |
| ~~`proof`~~ | 无 | V2 免 proof(身份由 URL `?token=` 决定) |

meta 取值参考:
- 官方 Web terminal:`{"platform":"web","version":"<桌面app_version>","name":"mobile-browser"}`(实测样本)
- Android App:`{"platform":"android","version":"<App版本>","name":"zcode-remote-app"}`
- Swift 建议:`{"platform":"ios"|"macos","version":"<App版本>","name":"<App名>"}`

### 6.3 入站帧(V2)

| type | 字段 | 处理 |
|---|---|---|
| `auth_ack` | `device_sid, terminal_sid, pair_status("waiting"\|"matched"), server_ts?` | 进入 WaitingPeer/Paired;`terminal_sid` 是中继分配给**本连接**的 id(`t_...`),记录用于诊断 |
| `pair_status_ack` | `pair_status, ...` | 心跳应答,同上按 pair_status 迁移;**任何 ack 都证明链路双向可用**(清单向失活计时) |
| `data` | `payload` | 业务帧,剥信封投递(§6.4) |
| `error` | `code, message?` | 按 §7.2 错误码处理 |
| `auth_challenge` | — | **V2 设计上不存在**;收到 ⇒ `PROTOCOL_MISMATCH` 终态(端点/版本错乱) |

pair_status 未知值(协议升级):`auth_ack` 上出现未知 `pair_status` ⇒ `PROTOCOL_MISMATCH` 终态,带「官方协议可能已升级」文案;`pair_status_ack` 上未知值可忽略(Kotlin 口径)。

### 6.4 data 信封(业务负载,唯一出站业务形态)

```json
→ {"type":"data","payload":{"zcode_type":"...","requestId":"..."},"client_ts":1792939013123}
← {"type":"data","payload":{...},"client_ts":...}
```

- **`client_ts` 这里是毫秒**(与 auth_init 的秒不同!官方 web `Date.now()`);此字段中继不严格校验单位 [存疑:实测毫秒通过、秒未测],建议毫秒。
- 缺信封/缺 `client_ts` ⇒ 认证成功后收 `WRONG_PARAM`(实测#4)。
- `payload` 内按 `zcode_type` 路由(§9)。

### 6.5 terminal 侧与 device 侧 auth_init 差异(对照)

| | device(PC,≥3.16) | terminal(本实现) |
|---|---|---|
| 前置 | `POST /api/v1/remote/device {device_mid}` 注册拿 sid(绑定账号);token role=`"device"` | 无注册;sid 来自 QR/设备列表;token role=`"terminal"` |
| `device_sid` | 自己注册的 sid | **PC 的 sid**(不是自己的 terminal_sid) |
| `meta` | `{platform: process.platform, version: appVersion, name: deviceName}` | 如实上报移动端身份 |
| `client_ts` | 秒 | 秒 |
| `role` | 不带(V2) | 不带(V2) |
| 配对语义 | `waiting`(无 terminal)→ `matched`(terminal 接入);桌面日志 `waiting_terminal → paired` | `waiting`(PC 未开远程控制/无 device)→ `matched` |
| 心跳 | `pair_status_query`(无 device_sid,秒) | 同左 |

同一 `deviceSid` 在中继上**只有一个 terminal 槽**:第二个 terminal 连入即踢掉第一个(先者收 `KICKED`)。App、官方 Web、调试探针三方互斥。

---

## 7. 心跳、错误码与重连状态机

### 7.1 心跳(官方 `heartbeatTiming.ts` 口径,2026-11-14 源码实证)

| 参数 | 值 | 说明 |
|---|---|---|
| `HEARTBEAT_INTERVAL_MS` | **5 000 ms** | 基准间隔 |
| `HEARTBEAT_JITTER_MS` | **1 000 ms** | `[base-jitter, base+jitter]` 均匀抽样、**每轮重抽**(jitter 必须 < 基准) |
| `HEARTBEAT_ACK_TIMEOUT_MS` | **15 000 ms** | watchdog:发出心跳后 15s 内无**任何** ack ⇒ 失活 |

帧(V2,`pair_status_query`,**无 device_sid**,strictObject 拒多余字段):

```json
→ {"type":"pair_status_query","client_ts":1792939013}
← {"type":"pair_status_ack","pair_status":"matched"}
```

- 运行条件:`Paired` 与 `WaitingPeer` 状态都发(V1 老实现 waiting 时隔轮发,新口径两态都发)。
- 失活判定(单向失活,采 Kotlin T11):记录「首次发出但尚未被 ack 覆盖」的心跳时刻;`now - sentAt >= 15s` ⇒ `fail(NETWORK)`(非终态)→ 走退避重连。收到**任意** `auth_ack`/`pair_status_ack` 即清零。判据必须是「发了但没回」,刚连上未发不判。
- 新一轮连接从零计时,不继承上一条的未 ack 残留。
- 注:旧记「10s/30s」是 v3.11 bundle 误记(`heartbeatIntervalMs ?? 10_000` 是桌面可配置参数默认值);官方源码 V2 为 5s/1s/15s。**不要用 10s/30s**。

### 7.2 中继错误码(`error` 帧)与关闭码

`{"type":"error","code":"KICKED","message":"..."}` —— 行为表(采信 PROTOCOL.md §4 2026-11-14 口径 = 官方 `retry.ts`):

| code | 行为 |
|---|---|
| `KICKED` | 首次 = 可能误报(relay owner 丢失,官方已知限制):**2~5s 随机重连自愈**(见 §7.3);**60s 内第二次 = 真互踢** ⇒ 终态 `KICKED`(「已在别处打开」)。`auth_ack/matched` 只清退避、**不清 KICKED 窗口** |
| `DEVICE_OFFLINE` | 进入 **15s 有界宽限**(首次进入起算,重连不重置;期间保持退避重试);超时 ⇒ 终态 `DESKTOP_DISCONNECTED`(可接续,走 §8.3 SID 接续)。宽限内**不要启动心跳**(ack 永远不来会被判 NETWORK 抢跑,Kotlin 注释实证) |
| `AUTH_FAILED` / `WRONG_PARAM` | 终态 `AUTH_FAILED`(配对失效/二维码过期;官方语义 `device-not-owned`,可参与 SID 接续) |
| `INTERNAL` | 曾配对(`Paired` 或 hadPaired+`WaitingPeer`)⇒ 置 `WaitingPeer` 等设备回来 + 心跳;否则立即重连(不退避,{immediate:true}) |
| 未知 code | 终态 `relay-unavailable` / `INTERNAL` |

V1 时代 WS 关闭码映射(参考;V2 主要走 error 帧,但保留映射兼容):
`4004 session-not-found`、`4009 session-conflict`、`4010 desktop-disconnected`、`4011 session-expired`、`4012 workspace-closed`、`4013 invalid-mobile-connection`。

`app-error` 业务帧(PC 拒绝某请求):`{zcode_type:"app-error", requestId?, bridgeSessionId?, reason, error?}`,reason 枚举 ≈ 上表关闭码族 + `desktop-bootstrap-timeout` / `connection-recovery-timeout` / `relay-unavailable` / `unsupported-action` / `unexpected-error`。

### 7.3 重连退避(官方 `WebRemoteControlV2RetryPolicy`,逐条转译自官方 `retry.ts`)

纯函数,建议独立成 `RetryPolicy` 结构体(可单测):

```
常量:
  SPREAD_MS       = 1_500     // 打散窗口(两端共用 WEB_REMOTE_CONTROL_V2_RECONNECT_SPREAD_MS)
  INITIAL_MS      = 500       // 退避基数(手机端口径;桌面 1s)
  MAX_BACKOFF_MS  = 10_000    // 退避封顶(手机端口径;桌面 30s)
  JITTER          = 0.2       // ±20% 双向抖动
  KICKED_WINDOW_MS  = 60_000  // KICKED 自愈窗口
  KICKED_MIN/MAX_MS = 2_000/5_000   // 官方 2000 + random*3001

状态: failures(退避计数)、spreadNext(下次打散标志)、lastKickAtMs

nextDelay():
  if spreadNext: spreadNext=false; return random()*SPREAD_MS          // 连接建立后的首次重连 0~1.5s 全窗打散(只一次,防 relay 重启 token 雷群;窗口必须 < 桌面 3s 手机断连宽限)
  base = min(MAX_BACKOFF_MS, 500 * 2^min(failures,16)); failures += 1
  jittered = base * (1 - 0.2 + random*0.4)                            // base*(1-jitter+random*jitter*2)
  return min(MAX_BACKOFF_MS, round(jittered))

acknowledged():  // pair_status=matched 时调用
  failures=0; spreadNext=true                                          // 清退避 + 标记下次打散;不动 lastKickAtMs

reset():        // 用户显式连接(扫码/手动重连)时调用
  failures=0; spreadNext=false                                         // 清退避,不打散;不动 lastKickAtMs

kickedDelay():  // KICKED 时调用
  if lastKickAtMs != 0 && now - lastKickAtMs < 60_000: return nil     // 60s 内第二次 → 调用方进 KICKED 终态
  lastKickAtMs = now; return 2000 + random()*3001                     // → [2000,5000] ms
```

### 7.4 状态机(Swift 移植蓝图,对照 Kotlin `RelayClient`)

```
enum RelayState {
  case idle                                  // Idle
  case connecting                            // Connecting(token 换取 + WS 建立)
  case authenticating                        // Authenticating(WS open,auth_init 已发)
  case waitingPeer                           // WaitingPeer(pair_status=waiting)
  case paired                                // Paired(pair_status=matched)
  case failed(FailureReason, String?)        // Failed(reason, message)
}
enum FailureReason { kicked, authFailed, deviceOffline, network, internal,
                     protocolMismatch, invalidEndpoint, desktopDisconnected }
终态集合 TERMINAL_FAILURES = {kicked, authFailed, protocolMismatch, invalidEndpoint, desktopDisconnected}
                            —— 不参与自动重连,关 socket,等用户手动恢复/接续
```

关键守则(每条都有真机教训背书):
1. **连接代次(generation)守卫**:每次 `connect()` 递增;旧 socket 的迟到 onClosed/onFailure 携带旧代次一律丢弃(OkHttp 失败回调可延迟数秒冒出,穿透视守卫会断掉健康连接)。
2. **终态即关 socket**:存活 WS 会收到后续 `pair_status matched` 静默绕过终态(实测:桌面重开远控后后台 App 零操作复活 Paired)。
3. **网络丢失/恢复钩子**:丢网立即断 socket + `retryPolicy.reset()` + 调度重连(不等 WS 超时回调);恢复瞬间 reset + 取消在等的退避 + 立即 connect(Paired/WaitingPeer 除外)。注意 Connecting 不算健康态(socket 失败不改 state,会残留)。
4. **重连调度防重入**:已有在等的重连任务时不再叠加(onClosed/onFailure 可能双触发)。
5. `connect(resetRetryPolicy:)` 二元:用户/网络恢复路径 true;内部重连调度 false(否则清掉打散标志,打散永不生效)。
6. DEVICE_OFFLINE 宽限:首次进入 `WaitingPeer` 起算 15s,重连**不重置**起点(否则归零循环永不到期);`matched` 取消并清零;超时且仍 WaitingPeer ⇒ `desktopDisconnected`。
7. KICKED 自愈路径:先建调度再关 socket(close 触发的迟到回调会被「已有调度」守卫挡住,否则双调度竞态)。
8. 无 JWT / token 401/403 ⇒ `authFailed` 终态 + 登录指引;token 其他失败 ⇒ `network`(可重连)。

### 7.5 出站队列与溢出

- **官方口径(采信)**:断线缓冲出站队列上限 **50 条**,溢出**整批丢弃**,**重连不回放**。
- 参考实现差异:旧 Kotlin/Dart 用 100 条静默丢弃;新 Kotlin 完全不排队(`send` 失败返回 false,由上层 PendingCommandLedger + 重订阅兜底)。
- Swift 建议:实现官方 50 条;`paired` 时 flush;同时注意官方对 `resolveInteraction` 这类 sensitive 命令**断线后不自动重放**(重连要用 `queryConversationCommandsV4` 回查)。
- 入站侧:单泵顺序分发保证帧序;队列有界(Kotlin `INBOUND_QUEUE_CAPACITY=1024`),溢出**不静默**——计数上抛进重同步(被丢弃帧未 ack,服务端可重放)。

---

## 8. bootstrap 与 workspace-bridge 流程

### 8.1 bootstrap(配对成功后第一帧)

请求:

```json
{"zcode_type":"bootstrap-request","requestId":"boot-1699999999999","terminalClientSessionId":"<uuid>"}
```

- `requestId`:`"boot-" + ms 时间戳`(probe/Kotlin 同构)。
- `terminalClientSessionId`(F5 起,3.18 桌面适用):**客户端生成并持久于连接生命周期**(`"swift-term-" + UUID`,与 v4ClientId 同模式,每次连接新建);bootstrap 带上后桌面注册 terminal owner;**后续 `workspace-bridge-open` 必须带同一 id**,否则桌面拒绝 "Terminal page session has ended; bootstrap is required."。桌面重连后 owner 已被 3s 宽限(`MOBILE_DISCONNECT_STATUS_GRACE_MS`)回收,新连接新 id 重新认领。
- 外层仍包 data 信封(§6.4)。

响应(V2,3.16+,**无 tasks[]**):

```jsonc
{"zcode_type":"bootstrap-response","requestId":"boot-...",
 "result":{
   "workspaces":[ /* 工作区列表 */ ],
   "mobileViewState":{...},            // 上次手机视图
   "desktopAppVersion":"3.18.2",
   "windowControlSessionId":"..."
 }}
```

响应(V1 形态,对照;V2 下 `tasks[]` 为空或缺失 ⇒ 会话列表由 Controller 通道提供 —— 本实现按 V2/Controller 走,`tasks[]` 出现也解析但以 Controller 为权威)。

超时:bootstrap 15s 无应答 ⇒ 按 `desktop-bootstrap-timeout` 处理(实测:`waiting` 态下 bootstrap 无应答,PC 必须已开启远程控制面板)。

### 8.2 开桥(workspace-bridge-open → ready)

请求(全部字段):

```json
{
  "zcode_type": "workspace-bridge-open",
  "requestId": "workspace-bridge-<uuid>",
  "bridgeSessionId": "bridge-<uuid>",          // ★ 客户端生成(不是服务端)
  "bridgeGeneration": 1,                        // ★ 初值 1;同一客户端计数器重开时 ++
  "workspaceKey": "<bootstrap 的活动工作区>",
  "taskId": "<可选,进入具体会话时>",
  "terminalClientSessionId": "<与 bootstrap 同一 id>"
}
```

- `bridgeSessionId` **由 terminal 生成**(三个实现一致:`"bridge-"+UUID`);`bridgeGeneration` 初值 **1**(probe/ZLinker/Kotlin 一致)。
- `recoveryId` 初次开桥**不传**(还没有);由服务端在 ready 里分配。

应答:

```jsonc
{"zcode_type":"workspace-bridge-ready",
 "requestId":"workspace-bridge-...",
 "bridgeSessionId":"bridge-...(回显)",
 "bridgeGeneration":1,
 "recoveryId":"<服务端分配>",
 "bridge":{"bridgeSessionId":"...","bridgeGeneration":1,"recoveryId":"...",
           "workspaceKey":"...","initialTaskId":"..."},
 "capabilities":{"windowProjectDirectory":true}   // 可选,严格布尔 true 才算支持
}
```

失败:`{"zcode_type":"workspace-bridge-error","requestId":...,"error":"..."}`;运行中桥异常:PC 推 `bridge-degraded {bridgeSessionId, reason}`(如 `rpc-transport-fault`、`terminal-owner-ended`)。

字段位置注意:Kotlin 从 ready 帧**顶层**读 `bridgeGeneration`/`recoveryId`;ZLinker 从 `bridge` **嵌套对象**读 —— 两者都出现在官方帧里(顶层为主,bridge 对象内含完整身份) [存疑:官方 schema 未直读,建议两处都解析、顶层优先]。

握手看门狗:open 后 **6s**(Kotlin `BRIDGE_OPEN_TIMEOUT_MS = 6_000`)未 ready ⇒ 重开(新 sid、generation 计数 ++),最多 **3 次**(`MAX_BRIDGE_OPEN_ATTEMPTS = 3`)⇒ `Failed` 可见失败。ready/error 会被桌面广播到所有 terminal 连接 ⇒ **只认自己生成的 bridgeSessionId**(他桥 ready/error 一律忽略)。

### 8.3 身份三元组与 rpc-frame(出站必带)

凡带身份键的后续帧(`rpc-frame` / `rpc-frame-ack` / `workspace-reconnect-request` 等):

```json
{"zcode_type":"rpc-frame",
 "bridgeSessionId":"bridge-...","bridgeGeneration":1,"recoveryId":"...",
 "seq":1,"messageSeq":1,"fragmentIndex":0,"fragmentCount":1,
 "messageBytes":123,"checksum":{"algorithm":"crc32","value":"1a2b3c4d"},
 "dataBase64":"..."}
```

- **全等校验铁律**:帧里任一身份键出现,三个键就必须与 ready 建立的当前值全部相等;ack 漏 `bridgeGeneration` 会被**静默丢弃**并导致服务端无限重放。
- `seq`/`messageSeq` 正整数,每桥从 1 起;`fragmentIndex ∈ [0,63] < fragmentCount ∈ [1,64]`;`checksum.value` 为 8 位小写 hex CRC32;`dataBase64` 标准 base64;`messageBytes ≤ 16 MiB`;物理信封 ≤ 1 MiB(分片阈值参考 512 KiB/384 KiB)。
- 收帧按 `messageSeq` 回 `rpc-frame-ack {zcode_type, ackMessageSeq, +三元组}`(单调去重)。

### 8.4 重连恢复(桥三元组怎么变)

WS 断开重连、`Paired` 再次到达后:

1. 发新 `bootstrap-request`(带**本连接的** terminalClientSessionId —— 新连接新 id,重新认领 owner);
2. 从 bootstrap 取活动 `workspaceKey` ⇒ 重新 `workspace-bridge-open`:**全新 `bridgeSessionId`**、generation 计数 ++(新 Kotlin 每次 connect 重建 RpcChannel,从 1 重新计数亦实测可行 —— 语义是"每桥新三元组",连续性由服务端 bootstrap 状态兜底);
3. 若是**同一 WS 会话内的桥降级**(`bridge-degraded` 而 WS 活着,或 re-pair 后快速恢复):官方做法是 `workspace-bridge-open` **携带旧桥 `recoveryId`** 重建(官方源码不区分 reconnect/reopen,统一 open+recoveryId;ZemoteClient/ZLinker 如此实现);另有轻量路径 `workspace-reconnect-request {zcode_type, requestId, workspaceKey}` → `workspace-reconnect-response {success}`(15s 超时,成功则旧桥继续可用;失败再走 open)。
4. 新桥 ⇒ 新 seq 空间(两侧从 1 起)、旧桥挂起请求**立即失败收场**(不能挂着等)、全部订阅**重新订阅**(服务端订阅状态随旧桥死亡);
5. `Paired` 后立即上报 `mobile-view-state-update {zcode_type, viewState{activeWorkspaceKey?, activeTaskId?, updatedAt(ms)}, deviceInfo{platform,version,name}}`。

### 8.5 SID 自动接续(官方 2026-10-27,3.18 桌面适用)

桌面每次重启/重登产生**新 `device_sid`(MID 不变)**;中继不做 old→new 映射。terminal 端恢复策略:

1. 可接续失败仅两类:`AUTH_FAILED`(官方 `device-not-owned`)与 `DESKTOP_DISCONNECTED`(waiting 超时/DEVICE_OFFLINE 宽限超时/回前台恢复超时);`KICKED`/`relay-unavailable` 等保持原行为;
2. 失败后:释放连接 → 用当前 JWT **查一次** `GET /api/v1/remote/device` → 以失败 SID 的 MID 求落点(纯函数,对照 Kotlin `SidContinuation.resolve`):
   - 旧 SID 仍在该 MID 在线集合 → `KeepCurrent`(沿用旧 SID 重建连);
   - 同 MID 其他在线 SID **恰好 1 个** → `Switch`(切新 SID,更新本地设备记录);
   - 0 个 / ≥2 个(歧义)/ MID 缺失 → `None`(维持终态交回用户);
3. 接续出的连接**配对成功前**再失败 ⇒ 不再二次接续(有界,一次性预算,`Paired` 到达即复位);
4. 无定时器、无轮询;业务状态按 SID 隔离不迁移;旧 SID 条目不删除。
5. V2 会话列表数据源:bootstrap 无 `tasks[]` ⇒ 订阅 Controller 通道(`window-controller` 通道 `subscribeControllerV4`,topic `controller/tasks-index`、`controller/workspaces`)——业务层细节另文。

---

## 9. zcode_type 路由表(中继层需要的最小集)

| zcode_type | 方向 | 本层处理 |
|---|---|---|
| `bootstrap-request`/`bootstrap-response` | T↔PC | §8.1 |
| `workspace-list-response`/`-updated` | PC→T | 工作区列表(响应+推送) |
| `workspace-bridge-open`/`-ready`/`-error` | T↔PC | §8.2 |
| `workspace-reconnect-request`/`-response` | T↔PC | §8.4 |
| `rpc-frame`/`rpc-frame-ack` | 双向 | §8.3,内层 Vql/204(业务层) |
| `mobile-view-state-update` | T→PC | §8.4-5 |
| `mobile-task-view-request`/`-update` | PC→T / T→PC | 前台任务视图(epoch/seq,官方 3.18;见 PROTOCOL.md §13.4) |
| `mobile-diagnostic` | T→PC | 诊断上报(state/closeCode/online/visibilityState),可选 |
| `task-pin-request`/`-response`、`task-archive-*`、`workspace-create-*` | T↔PC | 动作帧,30s 超时(§13.6) |
| `app-error` / `bridge-degraded` | PC→T | §7.2/§8.2 |

---

## 10. Kotlin 类结构对照(Swift 移植映射表)

新版 Android(`com.zcode.remote`)为主干:

| Kotlin | 职责 | Swift 对应建议 |
|---|---|---|
| `relay/RelayClient.kt` | WS 状态机、心跳、退避调度、KICKED/离线宽限、入站泵 | `RelayClient`(actor 或 class+serial queue);`RelayState`/`FailureReason` enum 直译 |
| `relay/RelayProtocol.kt` | 帧构造/解析纯函数(authInitV2/heartbeatV2/v2RelayWsUrl/calculateProof) | `RelayProtocol` enum 命名空间;`JSONEncoder` 手构 `JsonObject`(或 Codable 手写) |
| `relay/V2RetryPolicy.kt` | 退避/打散/KICKED 窗口纯函数 | `RetryPolicy` struct,注入 `random()`/`now()` 便于单测 |
| `relay/V2AccountApi.kt` | token/device REST + 单飞 | `V2AccountApi` async funcs;`TokenAuthException` 区分鉴权/网络 |
| `relay/RelayEndpointValidator.kt` | WS URL 安全校验 | `URLComponents` 结构化校验 |
| `relay/BridgeFrames.kt` | bootstrap/pin/create 帧构造与解析 | `BridgeFrames` |
| `relay/RpcChannel.kt` | 开桥、身份三元组、rpc-frame 收发/看门狗/v4ClientId/terminalClientSessionId | `RpcChannel`(桥层);`PendingRequests` 以 `(bridgeEpoch, requestId)` 为 key |
| `relay/SidContinuation.kt` | 接续落点纯函数 | `SidContinuation.resolve` 直译 |
| `storage/TokenStore.kt` / `PairedDevice.kt` | JWT AES-GCM 加密存储 / 设备模型 | Keychain(`kSecClassGenericPassword`)+ `PairedDevice` struct |
| `WebViewActivity.kt` + `WebViewLogin.kt` | V2 登录 WebView + 纯逻辑(landingUrl/回调解析/完成守护) | `WKWebView` + `LoginViewModel`;`LoginCompletionGuard` 原子布尔 |
| `service/ConnectionCoordinator.kt` | 编排:connect→collect state→bootstrap→openBridge→分发 | `ConnectionCoordinator`, Combine/async stream |

主循环(移植顺序建议):`connect()` → token → ws2 open → authInitV2 → auth_ack 状态迁移 → 心跳 loop → inbound pump(zcode_type 分发)→ bootstrap → bridge → rpc。

---

## 11. 参考实现差异标注与采信建议

| 差异点 | 新 Kotlin(app-android) | 旧 Kotlin(app.zemote)/ zemote(Flutter)/ ZLinker(Flutter) | 官方(V2 源码口径) | **采信** |
|---|---|---|---|---|
| 协议栈 | V1+V2 双栈 | 仅 V1 | V2 | 只做 V2(桌面 3.18.2) |
| 心跳 | 5s±1s 每轮重抽,watchdog 15s,单向失活 | 10s 固定,ack 超时 30s(zemote 加 25s 死链阈值/隔轮 waiting 心跳) | 5s/1s/15s | **新 Kotlin**(官方勘误) |
| KICKED | 首次 2~5s 自愈,60s 内二次终态 | 旧 Kotlin/zemote:KICKED 即无限抢回重连(1s<<n、shift 封 3、延迟封顶 8s,无终态);ZLinker:KICKED 直接终态;官方 V1 bundle:终态 session-conflict | V2 retry.ts:60s 窗口 | **新 Kotlin** |
| 退避 | 500ms×2ⁿ±20% 封顶 10s + 首次打散 0~1.5s | 1s×2ⁿ clamp(1s,15s)(三实现一致) | V2:同新 Kotlin;V1 官方 web `min(1e4,500*2ⁿ)` 无抖动 | **新 Kotlin** |
| DEVICE_OFFLINE | 15s 宽限 → desktopDisconnected 终态(可接续) | 无专门处理(旧 Kotlin 靠 close code 4010 映射) | `recoverConnection(15_000)`/`desktopOfflineGraceMs ?? 15_000` | **新 Kotlin** |
| 出站队列 | 无队列(send false + PendingCommandLedger) | 100 条静默丢弃,matched flush | 50 条整批丢弃不回放 | **官方 50 条**(简单起步亦可先无队列+失败上抛) |
| auth_ack unknown pair_status | PROTOCOL_MISMATCH 终态 | 忽略 | — | 新 Kotlin(协议升级可见) |
| token 失败分类 | 401/403/api code≠0 ⇒ AUTH_FAILED 终态;其余 NETWORK | 无(无 V2) | — | 新 Kotlin(T10 教训) |
| Origin 头 | 显式设置(推导同源 https) | Dart web 靠浏览器;无原生处理 | 浏览器自动 | 新 Kotlin 做法;iOS URLRequest.setValue 可行 |
| bootstrap terminalClientSessionId | 带且 bridge-open 同 id | 无此字段(V1 时代) | F5 起要求 | 新 Kotlin(3.18 必带) |
| ready 身份字段位置 | 顶层 bridgeGeneration/recoveryId | ZLinker 读 bridge 嵌套对象 | [存疑] | 两处兼容、顶层优先 |
| 重连后开桥 | 重 bootstrap + 全新三元组(generation 重置 1) | ZemoteClient/ZLinker:重开带 recoveryId、generation++ | open+recoveryId 统一重建 | 桥降级(WS 存活)带 recoveryId;WS 重连走全新 bootstrap+open(实测通过) |
| waiting 超时 | 无专门 waiting 定时器(靠心跳/离线宽限) | 30s waiting 超时 ⇒ invalid-mobile-connection(V1 遗留) | V1 web 30s | V2 简化:不加 waiting 超时,依赖心跳与 DEVICE_OFFLINE 宽限 [存疑:V2 官方是否保留 waitingTimeout 未证实;建议保留 30s 作 UX 兜底] |
| proof(V1 参考) | base64url 无填充 HMAC-SHA256(key=passHash, msg=`${nonce}\|${role}\|${deviceSid}`) | 同 | 同 | (V2 不用;留存备查) |

---

## 12. Swift 实现清单(按此顺序落地)

1. `PairedDevice` + QR 解析(V2-only 判定;`+`→`%2B` 预转义)。
2. `TokenStore`(Keychain:JWT)、JWT `exp` 读取与过期清理。
3. 登录:WKWebView 打开 landingUrl → 跨域放行 + Cookie 持久化 → didFinish 收割 `localStorage.zcodejwttoken` → 完成守护。
4. `V2AccountApi.fetchRelayToken`(Bearer JWT、401/403 → auth 失败分类、单飞)/ `listDevices`。
5. `RelayEndpointValidator` + `RelayProtocol.v2RelayWsUrl`。
6. `RelayClient`:URLSessionWebSocketTask(Origin 头、token+mid query)、代次守卫、authInitV2、状态机、心跳(5±1s/15s watchdog/单向失活)、错误码处理、离线宽限、`RetryPolicy`、NWPathMonitor 网络钩子。
7. 入站泵(zcode_type 分发)+ 出站 data 信封(ms client_ts)+ 50 条断线队列。
8. bootstrap(terminalClientSessionId)→ `RpcChannel` 开桥(三元组、看门狗、ack)→ `mobile-view-state-update`。
9. SID 接续(`SidContinuation` + 一次性预算)。
10. 单测重点:RetryPolicy 全路径、client_ts 单位(auth 秒/data 毫秒)、心跳抽样区间、KICKED 窗口、离线宽限不重置、三元组全等、token 失败分类。

## 附:快查卡(实现时最易错的 8 点)

1. `client_ts`:**auth_init/pair_status_query 用秒**(÷1000),**data 信封用毫秒** ——混用必失败。
2. V2 `auth_init` **不带 `role`**(V1 字段,strictObject 拒)。
3. WS 端点是 `/api/v1/remote/ws2`,不是 `/ws`;query 要 `token` **和** `mid`。
4. `Origin: https://<host>` 头必带(浏览器自动,原生必手加;iOS 经 URLRequest 可设)。
5. relay token 60s 短时效,每次连接现换,不缓存。
6. 心跳 5s±1s **每轮重抽**;失活看「发了但 15s 无任何 ack」;ack 包括 auth_ack。
7. KICKED 首次自愈 2~5s;60s 窗口不被 matched 清除。
8. rpc-frame 三元组「出现一个就必须三个全等」;ack 漏 `bridgeGeneration` = 静默丢弃 + 无限重放。
