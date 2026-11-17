# ZCode 远程控制协议 · 通道层(zcode-agent / window-controller / Conversation V4)实现规格

> 用途:Swift 实现通道层(Channel RPC + Conversation V4)的**精确规格**。
> 材料来源(全部只读精读,标注「权威」者为真机实测确认):
>
> | 来源 | 路径 | 性质 |
> |---|---|---|
> | A | `zcode-remote-app/research/CONVERSATION-PROTOCOL.md` | M2 真机实测,**对话协议权威** |
> | B | `zcode-remote-app/PROTOCOL.md`(§5/§6/§11.6/§13) | 业务层实测汇总 |
> | C | `zcode-remote-app/research/FRAME-CODEC.md`(§1–§3、§6、§7 有效) | 帧编解码逆向(带 asar 证据) |
> | D | `ZCode-Android/app/src/main/java/app/zemote/protocol/`(ChannelClient.kt / ConversationV4.kt / BridgeSession.kt) | Kotlin 实现(较老,V1 时代) |
> | E | `ZLinker/lib/protocol/`(channel_client.dart / conversation.dart / method_probe.dart / ipc_codec.dart / rpc_transport.dart) | Dart 实现,**命令面最全**(与官方 web v4 对齐) |
> | F | `zcode-remote-app/app-android/.../relay/`(RpcChannel.kt / ConversationChannel.kt / ControllerChannel.kt / SessionsIndexChannel.kt / ConversationFrames.kt / Interactions.kt / WireReassembler.kt) | Kotlin 实现,**最新**(V2/3.16+ 真机实证) |
> | G | `zemote/lib/protocol/` + `zemote/lib/state/session_list_cache.dart` | Dart 实现(E 的旧子集) |
>
> 约定:字段名一律原文(camelCase);不确定处标 **[存疑]**;JSON 块中 `//` 注释仅为说明。

---

## 目录

1. [分层总览](#1-分层总览)
2. [通道 RPC 层(IPC 之上的寻址与关联)](#2-通道-rpc-层ipc-之上的寻址与关联)
3. [值编码(Vql 二进制编解码)](#3-值编码vql-二进制编解码)
4. [rpc-frame 传输承载(桥上分片/校验/ack)](#4-rpc-frame-传输承载桥上分片校验ack)
5. [连接级握手(hello / clientHello)](#5-连接级握手hello--clienthello)
6. [Conversation V4 全命令参考](#6-conversation-v4-全命令参考)
7. [对话帧数据模型与渲染](#7-对话帧数据模型与渲染)
8. [权限确认与表单交互(resolveInteraction)](#8-权限确认与表单交互resolveinteraction)
9. [window-controller 通道(Controller V4)](#9-window-controller-通道controller-v4)
10. [sessions-index 通道](#10-sessions-index-通道)
11. [方法全集与探测(MethodProbe)](#11-方法全集与探测methodprobe)
12. [参考实现差异与采信建议](#12-参考实现差异与采信建议)
13. [常量汇总表](#13-常量汇总表)

---

## 1. 分层总览

```
┌─ WebSocket 中继(JSON 文本帧) ──────────────────────────────────────────────┐
│ {"type":"data","payload":<P>,"client_ts":<ms>}        ← 所有出站业务帧的信封 │
│  P = rpc-frame | rpc-frame-ack | workspace-bridge-* | bootstrap-* | …       │
└────────────────────────────────────────────────────────────────────────────┘
                     │ payload.dataBase64 → base64 解码
                     ▼
┌─ 传输层 rpc-frame 组装(§4)────────────────────────────────────────────────┐
│ 身份三元组校验 → 按 messageSeq 组装分片 → CRC32 校验 → 得到完整「IPC 报文」   │
│ → 回 rpc-frame-ack{ackMessageSeq}                                          │
└────────────────────────────────────────────────────────────────────────────┘
                     ▼
┌─ 通道 RPC 层(§2,ChannelClient)───────────────────────────────────────────┐
│ serialize([type,id,channelName,method]) ++ serialize(args|arg)             │
│ 100/101/102/103 出站;200/201/202/203/204 入站                              │
└────────────────────────────────────────────────────────────────────────────┘
                     │ 201 data = 返回值;204 data = 事件载荷
                     ▼
┌─ 应用层逻辑帧(§7)─────────────────────────────────────────────────────────┐
│ {wireVersion:3, kind:complete|fragment, topic, subscriptionId, frame|…}    │
│ → topic 帧 {fromSeq,toSeq,payload:{kind:snapshot|deltas}}                  │
└────────────────────────────────────────────────────────────────────────────┘
```

前置条件(不在本文范围,见 PROTOCOL.md §3/§11):已完成中继认证(V1 challenge/proof 或 V2 token+ws2)、收到 `workspace-bridge-open` → `workspace-bridge-ready` 的桥身份三元组。**通道层的一切请求必须在收到 IPC 层 `200 Initialize` 之后发出**,否则被服务端丢弃(A §3)。

**关于任务书中「zcode-hello / zcode-hello-ack」的命名对齐 [存疑-命名]**:四个参考仓库中**不存在**名为 `zcode-hello` / `zcode-hello-ack` 的帧或方法。最接近的三个事物:

1. IPC 层的 `200 Initialize` 帧(每桥一次,head 只有 `[200]`,无 id、无 data,见 §2.2);
2. `zcode-agent` 通道的 `helloConversationV4`(应答即「hello」)→ `initializeConversationV4`(入参 clientHello),这是 **V4 连接级握手**,§5 给出精确字段;
3. 中继层 V2 的 `auth_init` / `auth_ack`(认证配对层,不属于通道层)。

Swift 实现按 §5 的 `helloConversationV4` / `initializeConversationV4` 落地即可。

---

## 2. 通道 RPC 层(IPC 之上的寻址与关联)

### 2.1 核心规则(权威:A §1–§3,真机实测)

- **通道名与方法名都在 IPC 报文头数组里**:`[type, id, channelName, method]`。
- **方法名 = 桌面端服务对象上的 JS 属性名,原样使用,不做任何变换**。即 camelCase 的 `subscribeConversationV4`,**不是** `v4/conversation/subscribe`(后者是 host→CLI 内部协议的方法枚举,发到通道上必然 `Method not found`)。
- **请求-响应关联靠 `id`(requestId)**:客户端每条 100/102 请求自增分配(从 0 开始);服务端应答 201/202/203 时回带同一 `id`;204 事件推送也挂在该监听请求的 `id` 上。id 线格式为 uint32。
- 服务端→客户端的应答**不重复** channelName/method:`serialize([type, id]) ++ serialize(data)`。

### 2.2 帧类型(A §3 / C §3.4)

| type | 名称 | 方向 | 说明 |
|---|---|---|---|
| 100 | Promise | C→S | 普通请求;参数段是**参数数组** `serialize([arg0, arg1, …])` |
| 101 | PromiseCancel | C→S | 取消一次 Promise |
| 102 | EventListen | C→S | 注册事件监听;参数段是**单个裸值** `serialize(arg)`(不是数组!) |
| 103 | EventDispose | C→S | 移除事件监听;参数段 `serialize(undefined)` |
| 200 | Initialize | S→C | 通道就绪。head 只有 `[200]`,**无 id 无 data**;每桥一次 |
| 201 | PromiseSuccess | S→C | `data` = 返回值 |
| 202 | PromiseError | S→C | `data` = `{message, name, stack[], code?, …}` 错误对象 |
| 203 | PromiseErrorObj | S→C | 非 Error 的失败值,`data` 原样 |
| 204 | EventFire | S→C | 事件推送,`data` = 事件负载,挂监听时的 id |

**关键行为细节**:

- **请求必须在 200 之后发**。收到 200 前发出的请求会被丢弃(客户端应 `awaitReady`,参考 D `ChannelClient.awaitReady` 30s 轮询超时)。
- 方法名不存在:100 → 包成 **202**,`data.message = "Method not found: <method>"`(实测样本:`202 {"message":"Method not found: subscribeConversationV4"}`)。
- **102 走无 try/catch 的路径,异常直接冒泡、不回任何响应**(表现为静默)——排查时不要把「102 无响应」误判为网络问题(A §3)。
- 103 EventDispose 的实测编码:`serialize([103, id]) ++ serialize(undefined)`(F `RpcChannel.encodeEventDispose`,官方 `sendCancelOrDispose` 双确认;发出后服务端静默停止推送、无应答)。
- **ack/应答无「到期」概念**:每条 100 请求必须挂超时(参考实现 30s 默认;订阅类给 45–60s,见 §6.3)。

### 2.3 消息布局(逐字节)

**客户端 → 服务端**:

```
serialize([ type, id, channelName, method ])  ++  serialize(args | arg)
```

- 100(call):`args` = 调用参数数组 → `0x04 varint(count) …` 开头
- 102(listen):`arg` = **单个裸值**(通常一个对象)→ 直接以该值的 tag 开头
- 103(dispose):第二段为 `undefined`(`0x00`)

**服务端 → 客户端**:

```
serialize([ type, id ])  ++  serialize(data)      // 200 例外:只有 [200]
```

手算校验示例(C §4.4):`channelName="zcode-agent"`(12B)、`method="subscribeConversationV4"`(20B)、type=100、id=0、args=`[{"workspacePath":"/w","sessionId":"abc"}]`:

```
04                              Array tag
04                              varint 元素个数 = 4
06 64                           Int tag + varint(100)
06 00                           Int tag + varint(0)
01 0C "zcode-agent"             String tag + varint(12) + 12B UTF-8
01 14 "subscribeConversationV4" String tag + varint(20) + 20B UTF-8
04 01                           args: Array tag + 个数 1
05 28 {"workspacePath":"/w","sessionId":"abc"}   Object tag + varint(40) + 40B JSON
```

### 2.4 通道名全集

权威来源:桌面 asar `chunk-RWMCBKS2.js` 通道枚举(C §3.5)+ ZLinker `Channels`(E,来自官方 web `Wb` 枚举)合并:

```
file, media-preview, system, terminal, git, git-checkpoint, setting, credential,
cua-permission, cua-pip-session, broadcast, zcode-task, window-controller,
zcode-agent, zcode-session, file-watcher, oauth, model-provider, usage-stats,
coding-plan-subscription, skills, skill-sync, mcp-sync, plugin-sync, plugins,
plugin-management, subagents, commands, hooks, memory, output-style,
settings-sync, bots, feedback, repo-wiki, prompt-attachment-transfer, off-peak-task
```

本规格涉及的三个核心通道:

| 通道名 | 承载的服务 | 关键方法 |
|---|---|---|
| **`zcode-agent`** | `createZCodeAgentService` | Conversation V4 全家(hello/initialize/subscribe/unsubscribe/resync/rowsRange/onDynamicConversationFrame/sendConversationCommandV4/queryConversationCommandsV4/sessions-index 家族/attachment 家族/输入预测/legacy sendPrompt) |
| **`window-controller`** | `createAttachmentService`(桌面 host 命名,含 controller 方法族 + listTaskList/mutateTask) | `subscribeControllerV4` / `unsubscribeControllerV4` / `resyncControllerV4` / 事件 `onDynamicControllerFrame` |
| `zcode-session` | `createZCodeSessionService` | `createSession`(会话管理)、`getWorkspaceRuntimeIdentity`、`readWorkspaceState`、`setModel`、`setThoughtLevel`、`readSession`、`closeSession`、`updateProviderRegistry` 等(**不含**任何 `*V4` 会话流方法) |

**通道归属实测铁律**(A §1、B §11.6.7-5):

- 会话流方法在 `zcode-agent`,**不在** `zcode-session`(实测:`zcode-session` 上发 `subscribeConversationV4` → `202 Method not found`)。
- Controller 方法族在 **`window-controller`**,**不在** `zcode-agent`/`zcode-task`(2026-10-26 真机:两通道上调用 `subscribeControllerV4` 均报 Method not found;官方 web 端注册表为 `windowControllerTaskListRegistry`)。
- 注意 ZCode-Android 的 `ChannelClient.Channel` 枚举(D)**没有** `window-controller`——该实现停留在 V1 时代,勿照抄其通道枚举。

### 2.5 事件监听生命周期(102/103)

标准序列(以会话流为例):

```
1) 102  zcode-agent  onDynamicConversationFrame   arg = {workspacePath, workspaceIdentity?}   ← 裸对象
2) 100  zcode-agent  helloConversationV4          args = []
3) 100  zcode-agent  initializeConversationV4     args = [clientHello]
4) 100  zcode-agent  subscribeConversationV4      args = [{...scope, sessionId}]
5) 持续收 204(EventFire id = 第 1 步的请求 id)
```

- **帧先于 ack 到达是常态**:服务端在 subscribe 的 201 应答之前就可能推 204。客户端必须把「subscriptionId 尚未确定时收到的逻辑帧」staging(按到达序缓存),拿到 ack 后按序回放(E `_SubscriptionBase._stagedFrames`;官方 staging 上限 1024 帧 / 32 MiB,超限 `fault.subscription.initialFrameStagingOverflow`,C §7)。
- 逻辑帧必须**同时匹配 `topic` 与 `subscriptionId`** 才接受;不匹配(含旧订阅迟到帧)直接丢弃。
- 退订用 **100 RPC**(`unsubscribeConversationV4`),不是 103;103 只用于撤掉 102 的监听(不再关心任何该事件推送时)。D 的实现退订时既调 unsubscribe(100)又 dispose listener(103)。

### 2.6 本地直连变体:13 字节 IPC 帧(供参考)

`ipc_codec.dart`(E/G)中实现了桌面 `SocketProtocol` 的本地帧头:13 字节 `[type:u8][id:u32be][ack:u32be][bodyLen:u32be]` + body(type=1 regular)。**中继路径上不使用**(rpc-frame 的 dataBase64 解码后直接就是 IPC 报文本体);仅当 Swift 实现走桌面本地 socket 直连时才需要。E/G 当前代码中也未实际引用该 `IpcFraming`(仅保留编解码器)。

---

## 3. 值编码(Vql 二进制编解码)

权威:C §3.3(桌面 asar 带函数名版本,逐字代码)+ E `ipc_codec.dart` / D `IpcCodec.kt` 同构实现。Swift 需要实现等价的 Reader/Writer。

### 3.1 varint(ULEB128,LSB 优先,7-bit 组,高位=续接)

- `0` 编码为单字节 `0x00`。
- 语义为 **uint32**(桌面实现用 32 位位移,`writeInt32VQL`)。rpc-frame 信封里的大数(seq 等)是 JSON 数字,**不走 varint**。

### 3.2 tag 表与编码规则

```
tag: Undefined=0x00 | String=0x01 | Buffer=0x02 | VSBuffer=0x03 | Array=0x04 | Object=0x05 | Int=0x06
```

| 值类型 | 编码 |
|---|---|
| `undefined`/null | `0x00`(无 payload) |
| `string` | `0x01 varint(len) utf8字节` |
| `Uint8Array`/Buffer | `0x02`(或 VSBuffer `0x03`)`varint(len) raw` |
| `Array` | `0x04 varint(count)` + 逐元素递归 |
| JSON 对象/bool/浮点/大整数 | `0x05 varint(len) json-utf8`(`JSON.stringify`) |
| int32 范围整数 | `0x06 varint(int)` |

注意(E `encodeValue` 的实现口径):非负且 ≤0x7FFFFFFF 的 int 才走 `0x06`,其余(负数、浮点、bool、null)统统落 `0x05` 的 JSON。**JSON 内嵌 `Uint8Array` 的约定**:编码成 `{"__zcode_rpc_nested_uint8array_v1":true,"base64":"<std-b64>"}`(C §3.3)。

### 3.3 RPC 消息的组装与拆解

一条 IPC 报文 = 两个顺序序列化的值:head(`[type,id,channelName,method]` 或 `[type,id]`)++ data(args/arg 或返回值/事件载荷)。解码侧:先 `deserialize` 得 head 数组,再从**当前偏移继续** `deserialize` 得 data。Swift 实现务必保持 Reader 的偏移状态(F `Vql.deserialize(bytes, head.nextOffset)` 模式)。

---

## 4. rpc-frame 传输承载(桥上分片/校验/ack)

通道 RPC 报文在桥上以 `rpc-frame` JSON 信封承载。本节字段全部来自 PC 端 zod 权威 schema(C §3.2,`.strict()`),**缺一即拒、多一即拒**。

### 4.1 `rpc-frame`(双向)

```jsonc
{
  "zcode_type": "rpc-frame",
  "bridgeSessionId": "bridge-<uuid>",       // 必填,1..256, /^[A-Za-z0-9._~-]+$/
  "bridgeGeneration": 1,                     // 可选,int ≥0 ≤2^53-1
  "recoveryId": "recovery-<uuid>",           // 可选,仅恢复连接出现,同 bridgeSessionId 正则
  "seq": 12,                                 // 必填,正 int;物理帧序号,从 1 起,全局连续不跳号
  "messageSeq": 7,                           // 必填,正 int;逻辑消息序号,同消息全分片共用,每消息 +1
  "fragmentIndex": 0,                        // 必填,int 0..63
  "fragmentCount": 1,                        // 必填,int 1..64
  "messageBytes": 86,                        // 必填,正 int ≤16MiB;整条消息(拼接后)字节数
  "checksum": {"algorithm": "crc32", "value": "1a2b3c4d"},  // 整条消息字节的 CRC-32,小写 8 位 hex
  "dataBase64": "<本片字节的标准 base64>"     // 必填,规范 base64(需可往返),长度 4..1MiB 字符
}
```

外层再包中继信封:`{"type":"data","payload":<rpc-frame>,"client_ts":<ms>}`。

### 4.2 `rpc-frame-ack`(双向)

```jsonc
{
  "zcode_type": "rpc-frame-ack",
  "bridgeSessionId": "…",
  "bridgeGeneration": 1,        // 同上
  "recoveryId": "…",            // 同上
  "ackMessageSeq": 7            // 累计确认:已完整收到的最大 messageSeq
}
```

### 4.3 身份三元组全等校验(踩坑重点,A §8 实测)

```
bridgeSessionId === 期望 && bridgeGeneration === 期望 && recoveryId === 期望
```

规则:**只要帧里带了任一身份键,三个键就必须全部相等**(含双方都缺省 undefined 的情形)。实测后果:ack 只带 `bridgeSessionId` 漏 `bridgeGeneration` → ack 被静默丢弃 → 服务端持续重放整个缓冲(同一批 200/201/202 每几秒循环重现)。**Swift 实现:凡带 bridgeSessionId 的帧(含 ack),一律同时带上 bridgeGeneration**;recoveryId 可选,两端一致即可。

### 4.4 接收侧组装规则(C §5.2/§6)

按顺序校验,任一失败产生固定 fault(terminal 多数要触发重同步/重开桥):

1. 身份三元组不匹配 → 丢弃且不 ack(旧桥迟到帧,非错误)。
2. base64 非规范(解码重编码 ≠ 原串)→ `remote.rpcFrame.invalidBase64`。
3. zod 解析失败 → `remote.rpcFrame.invalidMetadata`。
4. `messageBytes > 16MiB` → messageTooLarge;`fragmentCount > 64` → fragmentLimitExceeded。
5. `seq < expectedPhysicalSeq` → duplicate(幂等,回 ack);`seq > expected` → `remote.rpcFrame.physicalGap`(terminal)。
6. `messageSeq !== expectedMessageSeq` → `remote.rpcFrame.messageGap`(terminal)。
7. `fragmentIndex !== 已收片数` → `remote.rpcFrame.fragmentGap`。
8. 与活跃分片的 `fragmentCount`/`messageBytes`/`checksum.value` 不一致 → metadataMismatch / checksumMismatch。
9. 收齐后拼接,`crc32(整条) !== checksum.value` → checksumMismatch;通过 → 回 `rpc-frame-ack{ackMessageSeq}` 并把字节交给 ChannelClient。

**A-4 缺口自检**(F `RpcChannel.hasSeqGap`):`lastAckedMessageSeq > 0 && incomingSeq > lastAcked + 1` → 说明有帧被本地丢过(已 ack、服务端不重发)→ 上层必须触发**重订阅**(服务端重放权威快照),这是唯一自愈路径。

### 4.5 发送侧(F `RpcChannel.sendMessage` 简化口径,官方等长切分见 C §3.6)

- 报文 ≤ 700_000 B:单片直发(数学上信封必然 < 1 MiB)。
- 超过则等长切分(每片 ≤ 700_000 B,最后一片可短),共用同一 `messageSeq` 与整条消息的 `checksum`/`messageBytes`,`fragmentIndex` 0..n-1。16MiB 上限下最多 24 片 < 64。官方算法是对「最坏信封(时间戳取 2^53-1)仍 ≤ 1MiB」做二分求单片上限;工程上固定 700KB/片即可满足约束(F 的口径,经 fixture 对拍)。
- 任何分片被拒(超限)→ 整条失败(对端 30s 组装超时,语义一致)。
- 每个方向独立维护 `nextPhysicalSeq`/`nextMessageSeq`,均从 1 起;**新桥 = 新序列空间**,ready 后全部归 1。

### 4.6 重放/降级(C §6 摘要)

- 服务端对未 ack 的帧幂等重放(指纹 = 身份+seq+messageSeq+fragmentIndex/Count+messageBytes+checksum+分片长度+分片 crc32);客户端按 duplicate 处理再回 ack。
- 45s(`replayBufferGraceMs`)无数据 ack 且无待发 ack → `remote.rpcFrame.ackGraceExceeded`/`replayGraceExceeded`(terminal)→ PC 发 `bridge-degraded`,手机端走恢复(重开桥 + `recoveryId`)。
- 重放缓冲上限 8 MiB;流控高低水位 1 MiB/256 KiB。

---

## 5. 连接级握手(hello / clientHello)

**每个桥连接一次**(V2 host ≥3.16 强制;跳过直接 subscribe 会得到 `202 fault.connection.handshakeRequired`)。挂在 `zcode-agent` 通道。

### 5.1 `helloConversationV4`(100 → 201)

- 请求:`args = []`(空数组)。
- 应答(201 data,权威实测样本 A §4.1):

```jsonc
{
  "kind": "hello",
  "protocolVersion": 3,
  "connectionId": "host-rpc-<uuid>",
  "clientMode": "web-remote-replayable",     // 中继/远程客户端;桌面连续模式为 "desktop-continuous"
  "deliveryProfile": "replayable",
  "serverTime": 1789000000000,
  "capabilities": {
    "nativeDialogs": false,
    "localTerminal": false,
    "binaryFrames": false,
    "compression": "none",
    "workspaceHookReview": true
    // v3.18.1 起新增 "inputPrediction": true(见 B §13.2)
  },
  "auth": {}
}
```

需要保存:`connectionId`(attachment 上传要用,见 §6.10)、`protocolVersion`(回显给 initialize)、`capabilities`(能力协商,见下)。

**能力协商铁律**(B §13.1):能力位必须**显式 JSON 布尔 `true`** 才算支持;缺字段/非布尔/字符串 `"true"` 一律 false。kotlinx `JsonPrimitive.booleanOrNull` 对 `"true"` 也返回 true,与 zod 口径不一致——Swift 解析要显式排除字符串原语。

### 5.2 `initializeConversationV4`(100 → 201)

- 请求:`args = [clientHello]`,clientHello zod **`.strict()`**,字段必须精确(A §4.2):

```jsonc
[
  {
    "kind": "clientHello",
    "protocolVersion": 3,               // 回显 hello 里的版本
    "clientId": "<稳定客户端 id>",        // 见下方硬约束
    "clientKind": "mobileApp",           // desktop|web|mobileRemote|mobileApp,可选
    "appVersion": "1.0.0"                // 各实现取值不同,见 §12
  }
]
```

- 应答:201,具体载荷各实现未记录内容(成功即视为握手完成)**[存疑:应答体]**。

**clientId 硬约束**(实测,B §11.6.7-6):

1. `clientId` 被服务端按**桥连接**记住:换值再 initialize → `fault.connection.clientChanged`。V2 host 每桥只认**先到**的那个 clientId(同一 App 的 conversation/sessions-index/controller 三个通道必须共用同一 clientId;后到的 initialize 报 clientChanged 属预期,容忍并继续)。
2. 后续所有 `sendConversationCommandV4` 信封里的 `clientId` 必须与连接绑定的一致,否则 host 抛 `fault.command.clientMismatch`。
3. Swift 建议:每桥连接生成一次(如 `"ios-" + UUID`),三个通道共用。

**clientHello 变体说明**:ZCode-Android(D)额外带 `"capabilities": {"workspaceHookReviewUi": true}` 且 `clientKind` 按 hello 的 `clientMode` 映射(desktop-continuous→"desktop",否则"web")、`appVersion:"unknown"`。`.strict()` 下多余字段理论上应被拒,但该实现实测可用 **[存疑:capabilities 字段在 strict schema 下是否被剥离/接受,以真机为准;Swift 首版建议只发 5 个基础字段]**。

---

## 6. Conversation V4 全命令参考

除特别说明,全部是 `zcode-agent` 通道上的 **100 Promise → 201/202**。参数一律是「**数组包一个对象**」:`args = [ {…} ]`。对象公共前缀 **scope**:

```jsonc
{ "workspacePath": "F:\\AI\\Zcode", "workspaceIdentity": "<可选,远程工作区标识>" }
```

(官方 web 的 scope 也接受 workspaceIdentity 兜底为 workspacePath;ZCode-Android `scope()` 即 path/identity 双写 **[存疑:双写是否多余,建议有 identity 传 identity,没有只传 path]**。)

### 6.1 `helloConversationV4` / `initializeConversationV4`

见 §5。

### 6.2 `subscribeConversationV4`(100 → 201)

请求:

```jsonc
[{
  "workspacePath": "…", "workspaceIdentity": "…?",
  "sessionId": "sess_85338537-8624-46dc-b65a-203cd1706a33",
  "base": {"logEpoch": "<…>", "seq": 123},      // 可选;带上才可能拿 mode:"resume"
  "visibility": "foreground"                     // 可选:foreground|background
}]
```

应答:

```jsonc
{"ack": {"subscriptionId": "sub-mu49pn7t-5clp19di-1",
         "mode": "snapshot",              // "snapshot" | "resume"
         "logEpoch": "mu49pn7t-5clp19di",
         "openTiming": {…}}}              // 可选
```

- 首次订阅不带 `base` → `mode:"snapshot"`。
- `subscriptionId` 是后续帧的关联键(帧必须同时匹配 topic + subscriptionId)。
- **超时要给足**:桌面可能要预热会话运行时(官方 60s);ZLinker 用 60s,CONVERSATION-PROTOCOL 时代的 Kotlin 用 45s,过短拿不到 ack → 历史永远进不来。
- 错误:`fault.connection.handshakeRequired`(跳过握手)。

### 6.3 `unsubscribeConversationV4`(100 → 201)

```jsonc
[{ "…scope…", "subscriptionId": "sub-…" }]
```

### 6.4 `resyncConversationV4`(100 → 201)

seq 断层/看门狗超时/快照迟迟不到时调用:

```jsonc
[{ "…scope…",
   "subscriptionId": "sub-…",
   "forceSnapshot": true,
   "base": {"logEpoch": "<当前 logEpoch>", "seq": <当前已消费 seq>} }]
```

服务端随后重推权威快照(`deliveryKind:"recovery"`)。

### 6.5 `onDynamicConversationFrame`(102 EventListen)

- `arg = scope`(裸对象,不是数组)。
- 之后所有会话帧经 204 推送,`data` = 逻辑帧信封(§7.1)。
- 与 sessions-index 的监听独立(事件名不同),但同一 102 机制。

### 6.6 `conversationRowsRangeV4`(100 → 201,向上翻页拉历史)

请求:

```jsonc
[{ "…scope…", "sessionId": "sess_…",
   "beforeRowId": 833,      // 从当前窗口最早一行往前;缺省 = 初始窗口
   "limit": 60 }]            // 上限 200
```

应答:

```jsonc
{"rows": [ /* row 对象数组,升序 */ ],
 "atSeq": 2691,
 "atLogEpoch": "mu49pn7t-5clp19di",
 "hasMore": true}
```

- **必须校验 `atLogEpoch === 当前快照 logEpoch`**,不等则整批丢弃(日志纪元已变,快照失效)。官方语义:`atLogEpoch == null` 也放行(E `rangeEnvelopeMatches`)。
- `hasMore == true` 就用新窗口首行 `rowId` 继续拉,直到 false。
- 响应形状兼容:ZCode-Android 实测出现过 `{rows:{rows:[…],hasMore,…}}` 的双层包裹(F/D 双实现都做双层兼容),Swift 建议同样兼容。
- 也有实现读 `totalCount` 字段(可选出现)。

### 6.7 `sendConversationCommandV4`(100 → 201,统一命令管道)

请求:**`args = [ {…scope, envelope} ]`**,envelope(官方 web zod):

```jsonc
{
  "commandId": "cmd-<uuid>",          // 每次命令唯一;重试必须换新 id(幂等键)
  "clientId": "<与 initialize 相同>",
  "sessionId": "sess_…",              // createSession 时为 null(字段仍可显式传 null)
  "baseRevision": 2195,               // 仅 CAS 命令(见 6.7.2)
  "baseLogEpoch": "…",                // 仅行目标 CAS 命令
  "type": "sendText",                 // 命令类型,见 6.7.1
  "payload": { … },                   // 按类型
  "issuedAt": 1790000000000           // 客户端 ms 时间戳
}
```

应答(201 data,**命令 ack**,部分实现外面再包一层 `ack`,两种形态都要兼容):

```jsonc
{
  "status": "accepted",               // accepted | duplicate | noop | stale | blocked | reject*
  "reasonCode": "…",                  // 失败/特殊时
  "message": "…",                     // 失败时
  "revisionAtDecision": 2196,         // 决策时的快照 revision(CAS 用)
  "result": { … }                     // 按命令类型,见下
}
```

**成功判据(官方 LOe 口径):`status ∈ {accepted, duplicate, noop}`**。`duplicate`/`noop` 表示他处已消解/命令已处理,不是失败。`stale` 见 6.7.2。`blocked`/`reject*` 是失败。

#### 6.7.1 命令 payload 一览(按 type)

| type | payload 字段 | result(accepted 时) |
|---|---|---|
| `createSession` | `{workspaceId, firstInput?{text, attachments?[]}, config?{provider, model, thought?, mode?}, runtimeModel?, mcpServers?[]}` | `{sessionId: "sess_…"}` |
| `sendText` | `{text, requestedDelivery?: "startNow"\|"queue"\|"guide", attachments?: [{ref,fileName,mime,bytes}], heldQueueDisposition?: "keepQueueAndSend"\|"clearQueueAndSend", expectedHeldQueueItemIds?: [queueItemId…], automationId?, offPeakTaskId?, offPeakRunType?, botDeliveryTarget?, toolDisallowlist?: [string]}` | `{type:"inputAccepted", delivery:"startNow"}` |
| `sendGoalCommand` | `{text, displayText?, heldQueueDisposition?, expectedHeldQueueItemIds?}` | — |
| `stop` | `{expectedForegroundExecutionId?: string.min(1)}`(control.activeWorks 里有就带上,防误停;否则空 `{}`) | — |
| `resolveInteraction` | `{interactionId, answer:{optionId? / freeText? / action? / content?}}` | — |
| `respondWorkspaceHookReview` | `{sessionId, taskId, runId, remoteSessionId?, workspaceIdentity, bundleDigest, reviewFlowId, generation, interactionId, decision:{action:"trust_selected", reviewItemIds:[…]}}` | — |
| `switchModelConfig` | `{provider, model, thought}`(三者全必填;不变的项传当前值) | — |
| `switchCollaborationMode` | `{mode: "build"\|"edit"\|"plan"\|"yolo"}` | — |
| `setFollowupMode` | `{mode: "queue"\|"guide"}` | — |
| `setAssistantFeedback` | `{target:{rowId, entityId?}, feedback: "like"\|"dislike"\|null}` | — |
| `retryTurn` / `forkAssistant` / `editUserQuery` / `applyFileRewind` | `{target:{rowId, entityId?, …}}`;editUserQuery 另有 `newText` | — |
| `sendQueuedNow` | `{queueItemId}` | — |
| `editQueueItem` | `{queueItemId, newText}` | — |
| `deleteQueueItem` | `{queueItemId}` | — |
| `reorderQueueItem` | **冲突见 §12**:ZLinker `{queueItemId, beforeQueueItemId:null=移到末尾}`;ZCode-Android `{queueItemIds:[完整有序列表]}` | — |
| `setAutoDrain` | `{autoDrain: bool}` | — |
| `pauseGoal` / `resumeGoal` / `compact` / `deleteSession` / `createSelectionSideSession` | `{}`(空对象) | createSelectionSideSession → `{sessionId}` |
| `renameSession` | `{title}` | — |
| `snoozeInteractionAutoResolution` | `{interactionId}`(推迟 autoResolution 倒计时,无 CAS 字段) | — |
| `cancelBackgroundWork` | **冲突见 §12**:ZLinker type=`cancelBackgroundWork` payload `{workId}`;ZCode-Android type=`cancel` payload `{workId}` | — |
| `resumeWorkflowRun` | `{workId: runId, name?}`(无 baseRevision) | — |

sendText 队列冲突专用 `reasonCode`:`guard.heldQueueConfirmationStale`——客户端必须明确二选一后重试:`heldQueueDisposition:"keepQueueAndSend"` + `expectedHeldQueueItemIds:[当前队列的 queueItemId]`(保留队列)或 `"clearQueueAndSend"`(丢弃)。

#### 6.7.2 CAS 命令与 stale 重试(E,对齐官方 `eAe`/`tAe`)

- **CAS 命令集**(信封必须带 `baseRevision`):`applyFileRewind, forkAssistant, editUserQuery, retryTurn, setAssistantFeedback, sendQueuedNow, editQueueItem, reorderQueueItem, deleteQueueItem, setAutoDrain, switchModelConfig, switchCollaborationMode, setFollowupMode, pauseGoal, resumeGoal`。
- 其中**行目标命令**另需 `baseLogEpoch`:`applyFileRewind, forkAssistant, editUserQuery, retryTurn, setAssistantFeedback`。
- `baseRevision` 取 `max(当前快照 revision, ackedRevisions[sessionId])`。
- 应答 `status == "stale"`:读 `revisionAtDecision` 作为新的 base,**换新 commandId 重试一次**。
- ack 后记录:`accepted|noop|duplicate` → 下次 CAS 基准 = `revisionAtDecision + 1`;否则 = `revisionAtDecision`(ack 先于 state.updated 帧到达,运行事件也会推 revision,所以必须跟踪)。

#### 6.7.3 命令可重试性

- **sensitive 命令(`resolveInteraction` 等)断线后绝不自动重放**;重连后用 `queryConversationCommandsV4` 回查,或让用户重点(官方口径)。
- 超时重发有双重投递风险:仅当「桥已确认断开(dagrading)且等待恢复后」才允许换 commandId 重试一次(E `_sendCommandWithRetry`);桥健康时超时直接上抛。

### 6.8 `queryConversationCommandsV4`(100 → 201,v3.18)

```jsonc
// 请求
[{ "commands": [ {"sessionId": "sess_…", "commandId": "cmd-…"} ] }]   // ≤64 条
// 应答
{"results": [ {"key": "sess_…|cmd-…", "result": <CommandAck 对象> | "unknown", "turn": …?} ]}
```

- `"unknown"`(或 fault `fault.command.queryUnavailable`)= **无法确认是否执行,不等于失败**,保留 pending 不得破坏性清理。
- `fault.command.inputDiscardedOnRestart` = CLI 重启后未入 transcript 被明确丢弃,绝不自动重放,交用户决定。

### 6.9 `subscribeSessionsIndexV4` / `unsubscribeSessionsIndexV4` / `resyncSessionsIndexV4`

见 §10。

### 6.10 附件四件套 + 读取(zcode-agent,`chunk-RWMCBKS2.js` 实证)

| 方法 | 请求(args[0]) | 应答 |
|---|---|---|
| `attachmentBeginV4` | `{…scope, connectionId?, uploadId, sessionId, fileName, mime, totalBytes, totalChunks, checksum}` | `{uploadId, state, nextChunkIndex, ref?}`;`state=="committed"` 时直接返回 `ref`(秒传幂等) |
| `attachmentChunkV4` | 同上 + `{chunkIndex, dataBase64}` | `{uploadId, nextChunkIndex}`;**必须 `nextChunkIndex == chunkIndex+1`**,否则 `fault.attachment.invalidServerProgress` |
| `attachmentCommitV4` | `{…scope, connectionId?, uploadId, sessionId}` | `{ref}`;`ref = "zcode-artifact://<sessionId>/<artifactId>"` |
| `attachmentAbortV4` | `{…scope, uploadId, sessionId}`(abort 用基础参数) | 失败回滚服务端暂存 |
| `attachmentReadV4` | `{…scope, sessionId, ref, offset, limit}` | `{dataBase64, mediaType, nextOffset, totalBytes}`;循环读到 `nextOffset` 不增/超 total |

- `connectionId`:PROTOCOL.md §6.6 实测「不需要 connectionId(host 从 workspace/session 上下文解析)」;但 D/E 两个实现都带上(取自 hello),未报告冲突 **[存疑:建议带上——多余字段在非 strict 处 tolerated;若 begin 被拒再去掉]**。
- 常量:`attachmentMaxBytes=20MiB`、`attachmentChunkMaxBytes=512KiB`、`attachmentUploadMaxChunks=64`、`attachmentUploadTtlMs=5min`、`attachmentUnreferencedTtlMs=24h`;**客户端分片用 384KiB**(官方 web `_b=384*1024`,留 base64 膨胀余量)。
- `uploadId = "upload-" + uuid`;`checksum = "sha256:" + SHA256(fileBytes).hex()`(小写);`dataBase64` 标准 base64。

### 6.11 其他 zcode-agent 方法(按需)

- `conversationPlansV4`:args `[{…scope, sessionId}]`(计划面板数据源,独立 RPC)。
- `conversationFileChangesV4` / `conversationFileRewindPreviewV4`:args `[{…scope, sessionId, target, baseRevision?, baseLogEpoch?}]`。
- `conversationInputPredictionV4`(v3.18.1):args `[{sessionId, revision, draft?≤4000字符, requestId?}]` → `{decision, candidates[≤3], topConfidence, requestId?}`;decision ∈ `show|suppress_below_threshold|suppress_no_context|unavailable|cancelled`,仅 `show` 展示;失败一律空结果不抛错;RPC 超时 25s、防抖 ~700ms。
- `conversationWorkflowRunArtifactsV4` / `conversationWorkflowRunArtifactDataV4` / `conversationWorkflowRunArtifactReadV4`:工作流产物(参数见 E conversation.dart)。
- legacy `sendPrompt`(非 envelope RPC):args `{workspacePath, sessionId, inputId, content}` → `{sessionId, accepted:true, stateRevision}`。**附件走这条会被 zod strip**(201 accepted 但附件不到模型侧,实测),带附件必须走 sendText envelope。
- `zcode-task.prepareWorkspace`:args `[scope]`(注意通道是 **zcode-task**),返回 `{configOptions:[{id:"model"|"thought_level"|…, options:[{value,name,…}]}], slashCommands:[…]}`。

### 6.12 错误格式汇总

- 通道层:202,`data = {message, name, stack[], code?, detail?, details?, taskId?, traceId?}`;`message` 含 `"Method not found: <方法名>"` 时表示方法/通道错。
- fault code(出现在 202 data 或命令 ack `reasonCode`,双来源都解析):`fault.connection.handshakeRequired`、`fault.connection.clientChanged`、`fault.command.clientMismatch`、`fault.attachment.invalidServerProgress`、`fault.command.queryUnavailable`、`fault.command.inputDiscardedOnRestart`、`guard.heldQueueConfirmationStale`。
- 逻辑帧组装 fault 前缀:`proto.frameAssembly*`(checksumMismatch/metadataMismatch/invalidPayload 等)与 `fault.subscription.initialFrameStagingOverflow`。

---

## 7. 对话帧数据模型与渲染

### 7.1 204 事件载荷 = 逻辑帧信封(wire 层)

`onDynamicConversationFrame` 的 204 `data`:

```jsonc
{
  "wireVersion": 3,
  "kind": "complete",                       // "complete" | "fragment"
  "deliveryKind": "initial",                // "initial" | "online" | "recovery"
  "logicalFrameId": "sub-mu49pn7t-5clp19di-1-lf-1",
  "logicalFrameOrdinal": 1,                 // int > 0
  "topic": "conversation/sess_85338537-…",  // "conversation/" + sessionId
  "subscriptionId": "sub-mu49pn7t-5clp19di-1",
  "frame": { …topic 帧… }                   // kind=complete 时
  // kind=fragment 时改为:
  // "fragmentIndex": int≥0, "fragmentCount": int>0(≤1024),
  // "logicalBytes": int>0, "checksum":{algorithm:"crc32",value:8hex},
  // "dataBase64": <JSON 文本的字节分片>
}
```

**fragment 重组**(A-5,F `WireReassembler`,逐规则转译官方 `wire-reassembly.ts`):

- 按 `logicalFrameId` 建 assembly;元数据(`fragmentCount/logicalBytes/checksum.value/topic/subscriptionId/ordinal`)后续片必须全等,否则 fault。
- 收齐:按 index 拼接 → 长度 === logicalBytes → crc32 === checksum.value → UTF-8 decode → `JSON.parse` → 得到 **topic 帧**,走与 complete 相同路径。
- 缺片等待(不触发重同步);协议违例 → 显式失同步。护栏:并发 assembly ≤32(可收紧至 8)、单 assembly 超时(官方靠订阅生命周期,客户端自带 ~60s)、总预算 16MiB/1024 片。
- 兼容:无 wire 封装、直接下发逻辑帧的旧桌面(D/E 的 `else if wire["payload"] != null` 分支)。

### 7.2 topic 帧(内层 `frame`)

```jsonc
{
  "topic": "conversation/sess_…",
  "subscriptionId": "sub-…",
  "sentAt": 1789573258253,
  "fromSeq": 0,
  "toSeq": 2691,
  "payload": {
    "kind": "snapshot", "snapshot": { … }      // 首帧
    // 或 {"kind":"deltas","deltas":[ …op… ]}
  }
}
```

- 首帧:`deliveryKind:"initial"`、`payload.kind:"snapshot"`、`fromSeq===0`。
- 之后:`deliveryKind:"online"`、`payload.kind:"deltas"`,`fromSeq`/`toSeq` 单调推进。
- **空 `deltas:[]` 合法**(实测大量存在):只推 seq 无内容变更,当心跳忽略。
- **seq 连续性是接受增量前提**:`deltas.fromSeq !== 本地已消费 seq` → 断层 → `resyncConversationV4`(见 §6.4),该帧丢弃。快照帧不检查(全量权威)。

### 7.3 snapshot 全结构(真机骨架,`research/CONVERSATION-FRAME-SKELETON.txt`)

```jsonc
{
  "protocolVersion": 1,
  "sessionId": "sess_85338537-8624-46dc-b65a-203cd1706a33",
  "logEpoch": "mu49pn7t-5clp19di",
  "seq": 2691,
  "revision": 2195,
  "control": {
    "phase": "completedInterrupted",       // running | prewarming | completedInterrupted | …
    "sessionEnded": true,
    "canStop": false,                       // 停止按钮显示条件(服务端算好)
    "stopState": "idle",                    // idle | stoppable | stopping
    "stopTargetKind": "unknown",
    "activeWorks": [],                      // 元素含 foregroundExecutionId
    "lastError": null,
    "apiRetry": null
  },
  "availability": {                         // 控制类命令可用性门禁(fork/compact/queueEdit/…);只读客户端可忽略
    "fork": {}, "compact": {}, "switchModelConfig": {}, "setFollowupMode": {},
    "queueEdit": {}, "sendQueuedNow": {}, "pauseGoal": {}, "resumeGoal": {}
  },
  "inputRouting": {"mode": "startNow"},     // startNow | enqueue | guide | reject | choice (+reasonCode?)
  "meta": {"title": "Zcode远程控制安卓APP方案设计", "titleSource": "generated"},
  "config": {
    "provider": "272c28e1-…", "model": "deepseek/deepseek-v4.1-flash",
    "thought": "high", "thoughtLevels": ["…"],   // 字符串数组,值随模型家族(如 max/high/nothink、enabled/off);骨架未枚举具体值
    "followupMode": "queue", "mode": "yolo"
  },
  "modelTransition": null,
  "usage": {"contextWindow": {"usedTokens":…, "maxTokens":…, "cache":{"hitRate":…}, "breakdown":[{"source":"messages","chars":…}]},
            "cumulative": {}},
  "queue": {"items": [], "autoDrain": true},   // item: {queueItemId, text, createdAt}
  "pendingInteractions": [],                   // 见 §8
  "pendingCommands": [],
  "backgroundWorks": [],                       // {workId, kind:"bash"|"subagent", title, status, startedAt, cancellable}
  "subagents": {"revision":1, "childSessionIds":[…], "running":[…], "endedTotal":3},
  "goal": null,                                // {objective, summaryTitle, status(active|verifying|notSatisfied|…), tokenBudget, tokensUsed, timeUsedSeconds, activeRunStartedAtMs}
  "plan": {"items": [{"id","content","status"}], "updatedAt": 1789302334894},  // status=="completed" 为完成
  "workspaceHookAdmission": null,
  "rows": {"window": [ /* ≤60 行 */ ], "totalCount": 893, "firstRowId": 1}
}
```

- ⚠️ `rows.window` 只是**尾部窗口**(实测 60 条 vs totalCount 893),更早历史走 `conversationRowsRangeV4` 翻页。
- `rows.firstRowId` = **全库最早一行** 的 rowId(「已到顶」判定锚点);翻页游标是 `window[0].rowId`,别混淆。
- v3.18.1 快照字节预算(B §13.5):Web 远控首屏 `messageLimit=10` + `byteBudget=200KB`,被裁字段挂 `bodyRefs`/`snapshotRefs`/`contentRefs`(`{field, refId, hash, fullBytes, previewBytes}`);桥上暂无补拉方法,UI 如实标「已截断」。

### 7.4 行(row)模型

公共字段:`rowId`(服务端递增数字,**排序键与唯一键**)、`turnId`、`entityId`、`productTurnId`、`visibility`("visible" 之外过滤掉)、`createdAt`(ms)、`createdAtSeq`、`kind`。

**没有统一 `role` 字段,角色由 `kind` 表达**(A §6.2):

| kind | 角色 | 关键字段 |
|---|---|---|
| `userInput` | 用户消息 | `text`、`origin`(realUser/backgroundResult/goalContinuation/mailbox/synthetic)、`attachments?`(`{ref,fileName,mime,bytes}`,仅此 kind 回显) |
| `assistantText` | 助手正文 | `text`、`state`(complete/streaming/interrupted)、`assistantResponseId`、`bodyRefs?` |
| `reasoning` | 思考过程 | `text`、`state`、`durationMs?` |
| `toolCall` | 工具调用 | `toolCallId`、`toolName`、`status`(inputStreaming/pendingApproval/running/success/error/cancelled)、`inputText`(JSON 字符串形式)、`input`(解析后对象,两者都在)、`output{text,error?}`、`startedAt`、`endedAt`、`snapshotRefs?` |
| `turnHeader` | 轮次头 | `actions{canFork,canEdit,canRetry,canRewindFiles,editDisposition}`、`origin`、`executionKind`、`activeMs`、`historyRoundCount`(聊天时间线通常不渲染) |
| `subagent` | 子智能体 | `childSessionId`、`subagentType`、`summaryText`(流式摘要) |
| `hookInvocation` / `timelineMarker` | 同族其他 | — |
| `image` | 图片 | [存疑:仅 ZCode-Android ConvKinds 出现 IMAGE="image",无实测样本] |

构造示例(字段名与实测一致,值为示意):

```jsonc
{"rowId": 871, "kind": "assistantText", "turnId": "t-…", "entityId": "e-…",
 "visibility": "visible", "createdAt": 1789573258000, "createdAtSeq": 4,
 "state": "streaming", "text": "我来分析…"}
```

### 7.5 增量 op(deltas[].op)

```jsonc
{"op": "row.appended", "row": {…row…}}                                  // 追加一行(乱序/重放时退化为 upsert)
{"op": "row.upserted", "row": {…row…}}                                  // 按 rowId 覆盖/插入
{"op": "row.removed", "fromRowId": 871}                                  // 删除 rowId >= fromRowId 的所有行(保留 < fromRowId)
{"op": "row.delta", "rowId": 871, "path": "text", "append": "增量片段"}    // 流式文本:append 累加
{"op": "state.updated", "patch": {…}}                                    // 快照顶层键的整块替换(见 7.6)
```

**row.delta 的 path 白名单与 kind 的严格对应**(官方 `dke`):

| path | 允许的 kind | 目标字段 |
|---|---|---|
| `text` | assistantText、reasoning | `text` |
| `inputText` | toolCall | `inputText` |
| `output.text` | toolCall | `output.text` |
| `summaryText` | subagent | `summaryText` |

不匹配的 (path, kind) 组合忽略(静默丢弃,防串字段)。

### 7.6 state.updated patch 语义

- **patch 中出现的键 = 快照顶层的同名键,整块替换**;未出现的键保留。值为 JSON null = 清除该块。
- 可出现的键:`control`、`config`、`usage`、`queue`、`pendingInteractions`(**整组替换**,不是逐条增删)、`backgroundWorks`、`subagents`、`goal`、`plan`、`revision`(数字)、`meta`、`inputRouting`、`availability`、`working` **[存疑:working 仅 ZCode-Android 出现,官方字段可能是 control.phase 派生]**。
- **patch 可能先于首快照到达**:缓冲(`_pendingPatch`),快照落地时合并(E/F/D 三实现一致)。

### 7.7 渲染指导(聊天流)

- **排序键 = `rowId`(升序)**;列表永远按 rowId 有序(快照替换、upsert 二分插入、removed 过滤、翻页前插都保持)。
- **快照 vs 增量**:快照 = window 全量替换 + **保留已翻页加载的更早行**(rowId < window 首行的本地行不清);增量按 op 应用。既有快照又有增量,seq 保证不会交叉错乱。
- **流式性能**:token 级 `row.delta` 先缓冲(rowId → path → StringBuilder),~60ms 批量提交(≈16fps),避免每 token 重建列表;未变行复用同一对象实例(供 UI diff)。
- **delta 早于 appended 到达**:缓冲中的 delta 在该行 finally append/upsert 时就地补上;找不到行的 delta 保留缓冲(上限 ~512 条防泄漏),行由 upsert 补进。
- `state == "streaming"` 的行显示打字态;完成态集合:`complete, completedSuccess, completedInterrupted, error, cancelled, aborted`。
- 运行状态:`control.phase ∈ {running, prewarming}` = 工作中;停止按钮显示 `control.canStop`,「停止中」用 `stopState=="stopping"`。
- **看门狗**(两套,都要):
  1. 订阅 ack 后 **≥10s 无快照落地** → 强制 `resyncConversationV4`(快照可能丢失,会话可能 idle,不能只依赖「运行中」判定);
  2. 快照已落地、**≥20s 无帧且(运行中或有 streaming 行)** → resync。(10s tick 检查)。
- 会话切换:清 rows/delta 缓冲/翻页游标/ackedRevisions/subscriptionId,重新握手(可复用)+ 重新订阅。

---

## 8. 权限确认与表单交互(resolveInteraction)

### 8.1 请求到达路径(两条并存,双源合并)

**路径①(权威,会话帧)**:`snapshot.pendingInteractions[]` 与 `state.updated.patch.pendingInteractions`(整组替换)。条目结构(实测):

```jsonc
{
  "interactionId": "perm_…",                 // 应答时的定位键
  "kind": "permission",                      // "permission" | "userInput" | "workspaceHookReview"
  "anchorRowId": 871,                        // 可选,关联行
  "autoResolution": {"deadlineAt": 1790000300000},   // 桌面倒计时(~5min),超时后应答得 noop
  "payload": {
    // permission 形态:
    "toolName": "Bash", "toolCallId": "call_…",
    "summary": "运行构建命令", "detail": {"command": "npm test", …},
    "options": [
      {"optionId": "opt-…", "label": "允许一次", "kind": "allowOnce",
       "response": {"decision": "allow"}},   // decision: allow|deny|escalate|modify,仅渲染用
      {"optionId": "opt-…", "label": "始终允许", "kind": "allowAlways", "response": {…}},
      {"optionId": "opt-…", "label": "拒绝",   "kind": "rejectOnce|deny|rejectAlways|custom", "response": {…}}
    ]
    // userInput(elicitation)形态:
    // "prompt", "freeText":"true"?, "toolName", "toolCallId", "traceId",
    // "input": {…}, "schema": {"toolName", "interaction"?, "plan"?},
    // "questions": [{"question","header","options":[{"value","label","description"}],"multiSelect"}]
  }
}
```

**路径②(任务事件流,列表页角标用)**:host `permissionRequestToStreamEvent` / `userInputRequestToElicitationStreamEvent`:

```jsonc
{"type":"permission_request", "taskId":"sess_…", "requestId":"<即应答时的 interactionId>",
 "description":"<reason||toolName>", "kind":"<toolName>", "title":"<toolName>",
 "options":[{"optionId","kind","name"?,"response"?}], "raw":{…}}
// 消解推送 {"type":"permission_resolved", "requestId":"…"}
// elicitation 版:{"type":"elicitation_request", taskId, requestId, message, header,
//  options[{value,label,description}], multiSelect?, questions?, schema?}
```

差异:**无 interactionId/payload 包裹(requestId 即 interactionId)、选项无 label**(显示名按 kind 生成,custom 用 name)。事件全集:`created, prompt_sent, resumed, streaming, permission_request, permission_resolved, elicitation_request, elicitation_resolved, updated, completed, error`;字段 `{type, workspacePath, taskId, updatedAt, workspaceIdentity, …}`。

### 8.2 应答:resolveInteraction envelope

```jsonc
// sendConversationCommandV4 args[0]
{
  "workspacePath": "…", "workspaceIdentity": "…?",
  "envelope": {
    "commandId": "cmd-<uuid>",
    "clientId": "<连接绑定的 clientId>",       // 不符 → fault.command.clientMismatch
    "sessionId": "sess_…",                     // 优先用审批所属会话,勿盲目用当前会话(跨会话应答串台)
    "type": "resolveInteraction",
    "payload": {
      "interactionId": "perm_…",
      "answer": { …按形态… }
    },
    "issuedAt": 1790000000000
  }
}
```

**answer 的形态**(host answer zod:`{optionId?, freeText?, action?, content?}`):

| 场景 | answer |
|---|---|
| permission 点选项 | `{"optionId": "<服务端原文字符串,只透传>"}` |
| 无 questions 的确认/文本条目:点选项 / 自由文本 | `{"optionId": …}` / `{"freeText": "…"}` |
| 带 questions 的表单(AskUserQuestion/plan)接受(单题) | `{"action":"accept", "content":{"answer": "<首选值>"}}` |
| 多题接受 | `{"action":"accept", "content":{"answer_0": …, "answer_1": …, "answers":{"<问题文本>":"<合并答案>"}}}` |
| 拒绝 | `{"action":"decline"}` |
| plan_approval 批准 | `{"action":"accept"}`(无 content) |
| 取消 [存疑:action 枚举 accept/decline/cancel 三值来自 host zod 注释,实测样本只有 accept/decline] | `{"action":"cancel"}` |

- **optionId 原样透传,绝不映射序号**(官方 UI 显示顺序是 kind 排序后的位次,与数组下标不一致,按序号回传会答错)。
- ack 判据:`status ∈ {accepted, duplicate, noop}`;`duplicate`/`noop` = 他处已消解,撤卡片即可。
- 同一会话可有多条并行 pending(subagent),按 `interactionId` 精确匹配。
- workspaceHookReview 交互走专用命令 `respondWorkspaceHookReview`(payload 见 §6.7.1 表)。

---

## 9. window-controller 通道(Controller V4)

V2 host(≥3.16)的**会话/任务列表权威数据源**(bootstrap 不再下发 `tasks[]`)。通道名 **`window-controller`**(真机实证,见 §2.4)。

### 9.1 订阅序列

1. **先做 V4 连接级握手**(hello → initialize,同 §5;`clientChanged` 容忍)——Controller 帧虽不经 conversation 管道,但桥上 V4 RPC 强制握手(`fault.connection.handshakeRequired`)。
2. **一次 102 listen**:`window-controller` 通道、事件 `onDynamicControllerFrame`、`arg = null`(两个 topic 共用一个 listen,帧按 subscriptionId 分流;桌面端为单例事件)。
3. 对两个 topic 各发一次 `subscribeControllerV4`(100):

```jsonc
// 请求
[{"topic": "controller/tasks-index", "visibility": "foreground"}]
// 应答
{"ack": {"subscriptionId": "…"}}          // 部分实现顶层直挂 subscriptionId,兼容两种
```

**topic 枚举**(桌面 zod 常量 `Wr`/`Fr`):

```
"controller/tasks-index"     // 任务(会话)列表
"controller/workspaces"      // 工作区事实
```

### 9.2 帧 schema(实测:**裸帧**,无 204 逻辑帧信封)

```jsonc
{
  "topic": "controller/tasks-index",
  "subscriptionId": "…",
  "logEpoch": "…",                  // 服务端 createId();日志重置/进程重启会变
  "fromSeq": 0, "toSeq": 3,         // 单调推进;toSeq < fromSeq 被 schema 拒
  "sentAt": 1793024957000,
  "payload": {
    "kind": "snapshot",
    "snapshot": {"protocolVersion": 1, "logEpoch": "…", "tasks": [ /* Task */ ]}
    // deltas 时:{"kind":"deltas","deltas":[ /* op */ ]}
  }
}
```

⚠️ **没有** conversation 的 wire 信封(无 `kind:complete/fragment`、无嵌套 `frame`)。Swift 解析建议裸帧优先、同时容忍信封形态(F `ControllerFrames.parse` 双形态)。**workspaces 的 snapshot 键是 `workspaces`**:`{"protocolVersion":1, "logEpoch", "workspaces":[WorkspaceFact]}`。

### 9.3 Task 模型(zod strict,`Or`)

```jsonc
{
  "address": {                       // TaskAddress (strict)
    "workspacePath": "F:\\AI\\Zcode",   // 必填
    "taskId": "sess_…",                  // 必填
    "workspaceIdentity": "…?",           // 有 remoteSessionId 时必填
    "remoteSessionId": "…?"
  },
  "meta": {                          // TaskMeta
    "taskId": "…", "title": "…", "workspacePath": "…",
    "createdAt": 0, "updatedAt": 0,
    "mode": "…?", "status": "idle|running|…?", "provider": "…?", "lastError": "…?"
  },
  "membership": {"pinned": false, "archived": false, "active": false},   // strict;归档标志在这里
  "sourceAvailability": "online" | "offline",
  "liveStatus": "idle" | "running" | "waiting" | "completed" | "error",  // 列表实时状态(列表显示用它)
  "activity": {"phase": "…", "lastActivityAt": 0, "hasBackgroundWork": false, "pendingInteractions": …}?,  // 可选
  "searchSnippets": ["…"]?           // 可选
}
```

schema 级约束(不一致整帧被拒):`address.taskId == meta.taskId`、`address.workspacePath == meta.workspacePath`、`address.workspaceIdentity == meta.workspaceIdentity`。

**WorkspaceFact**(`Br`):`{workspacePath 必填, workspaceIdentity?, remoteSessionId?, sourceAvailability: "online"|"offline", connectionState: "connecting"|"online"|"closing"|"failed"|"disconnected"|"reconnecting"}`;约束 `offline` 只能配 `disconnected`/`failed`。

### 9.4 增量 op

```jsonc
// controller/tasks-index
{"op": "task.upserted", "task": { /* 完整 Task */ }}
{"op": "task.removed", "address": { /* TaskAddress,只带 address 不带完整 task */ }}
// controller/workspaces
{"op": "workspace.upserted", "workspace": { /* WorkspaceFact */ }}
{"op": "workspace.removed", "workspacePath": "…", "workspaceIdentity": "…?", "remoteSessionId": "…?"}
```

### 9.5 失同步判定与 resync(对齐官方 web `Uue`)

- **快照帧不判定**(全量权威),但照常刷新水位(logEpoch, toSeq)。
- deltas 帧:`fromSeq !== 上次 toSeq`(缺口**或回退**)或 `logEpoch` 变化 → 失同步。

```jsonc
// resyncControllerV4(100)
[{"subscriptionId": "sub-…",
  "base": {"logEpoch": "<当前>", "seq": <上次 toSeq>},
  "forceSnapshot": true}]
```

- resync 失败 → 退化为 `unsubscribeControllerV4` → 重新 `subscribeControllerV4`。
- 节流:同 conversation(如 5s 窗口),窗口内被抑制的 topic 汇总,下次触发一并补发。

### 9.6 其他

- `unsubscribeControllerV4`:`[{"subscriptionId": "…"}]` → `{ack}`。
- 实测数据特征:seq 严格连续(delta `fromSeq == 上一帧 toSeq`,无跳号);快照帧 `fromSeq` 恒 0;运行中任务 meta/liveStatus 变化即推 `task.upserted`(秒级);归档任务**包含在快照里**(靠 `membership.archived` 过滤,实测 221 条中 101 归档)。
- 列表渲染(F `visibleSessions`):过滤 archived → 置顶优先 → updatedAt 降序 → taskId 稳定排序;`displayStatus = liveStatus ?: meta.status ?: "unknown"`。

---

## 10. sessions-index 通道

workspace 级会话索引:当前工作区所有会话的轻量条目 + **权威待处理角标**。通道 `zcode-agent`。

### 10.1 订阅

```jsonc
// 102 listen:onDynamicSessionsIndexFrame,arg = scope(裸对象)
// 100 subscribeSessionsIndexV4:
[{ "workspacePath": "…", "workspaceIdentity": "…?",
   "runtimePolicy": "existing-only",     // 当前唯一实测值
   "base": {"logEpoch":"…","seq":0}?,    // 可选,同 conversation
   "visibility": "foreground"? }]
// 应答
{"ack": {"subscriptionId": "six-…", "mode": "snapshot", "logEpoch": "…"}}
```

topic:`sessions-index/<workspaceId>`,其中 `<workspaceId> = workspaceIdentity ?? workspacePath`(E:`topic => 'sessions-index/${scope['workspaceIdentity'] ?? scope['workspacePath']}'`)。

退订/重同步:`unsubscribeSessionsIndexV4` / `resyncSessionsIndexV4`,参数 = scope + `{subscriptionId, runtimePolicy:"existing-only"}`(+resync 另带 `base`,可带 forceSnapshot [存疑:E 未带 forceSnapshot,conversation 版带;建议带上])。

### 10.2 帧结构

**与 conversation 相同的 204 逻辑帧信封**(wire kind complete/fragment、需重组;F `SessionsIndexChannel` 直接复用 `ConversationFrames.parseLogicalFrame`),topic 以 `sessions-index/` 开头。topic 帧 payload:

```jsonc
// snapshot
{"kind": "snapshot", "snapshot": {
   "workspaceId": "…?", "logEpoch": "…",
   "sessions": [
     {"sessionId": "sess_…", "parentSessionId": "…?",
      "title": "…", "phase": "running|prewarming|idle|completedSuccess|error|…",
      "lastAssistantPreview": "…?",
      "lastActivityAt": 0, "createdAt": 0,
      "hasBackgroundWork": false,
      "pendingInteraction": {…}?,                     // ZLinker 解析的原始字段
      "pendingInteractionSummary": {"permissionCount": 0, "userInputCount": 1}?}
   ]}}
// deltas(op 与 conversation 行 op 同名但对象级):
{"kind": "deltas", "deltas": [
   {"op": "session.upserted", "session": { /* 同上条目 */ }},
   {"op": "session.removed", "sessionId": "sess_…"}
]}
```

- `pendingInteractionSummary` **可选**(zod `Qce = {permissionCount:int≥0, userInputCount:int≥0}`);无字段 = 0/0;消解后字段回落消失。
- 快照全量替换、upserted 单条覆盖、removed 删除;列表按 `lastActivityAt` 降序。
- seq 断层 → `resyncSessionsIndexV4`(与 conversation 同逻辑)。

---

## 11. 方法全集与探测(MethodProbe)

### 11.1 MethodProbe 机制(E `method_probe.dart`)

- 为「桌面版本方法名漂移」设计的探针:按候选顺序试调,**仅当错误是 no-such-method 类**(`no such method` / `unknown method` / `method not found` / `not found` / `unsupported` / `invalid method` / `cannot read propert`,小写包含匹配)才前进到下一候选;validation/permission 错误立即上抛。胜出方法名按 op 记忆,后续直调。
- Swift 可移植该模式处理不稳定方法面(task 元数据/off-peak/automation 族)。

### 11.2 探测候选全集(按端口)

**zcode-task 任务元数据**(arg 形状 `{taskId, …scope, title|pinned|unread}`;**archiveTask/unarchiveTask 是两个独立方法,无 boolean 字段**):

| op | 候选(确认名在前) |
|---|---|
| rename | `renameTask, updateTaskTitle, setSessionTitle` |
| pin | `setTaskPinned, pinTask` |
| unread | `setTaskUnread, markTaskUnread` |
| archive / unarchive | `archiveTask` / `unarchiveTask`(各仅一个) |
| (枚举,未见探测) | `deleteTask, listArchivedTasks`(官方 web 源确认存在) |

**automation 端口**:

| op | 候选 |
|---|---|
| list | `listAllAutomations, listAutomations` |
| create | `createAutomation, upsertAutomation, automationCreate` |
| update | `updateAutomation, upsertAutomation, automationUpdate`(参数形状 0=`[{automationId,…fields}]` / 1=`[automationId, fields]`) |
| delete | `deleteAutomation, automationDelete, removeAutomation`(args:`deleteAutomation([automationId])` vs `automationDelete([{automationId}])`) |
| runNow | `runAutomationNow, triggerAutomation, automationRunNow, runNow`(args `{…scope, automationId}`) |

**off-peak 端口**(桌面自有名:createTask/updateTask/pauseTask/continueTask/cancelTask/deleteTask/deleteHistory):

| op | 候选 |
|---|---|
| list | `list, listAll, listOffPeakTasks, listTasks` |
| submit | `run, submit, createTask, submitOffPeakTask, createOffPeakTask` |
| pause | `pause, pauseTask, pauseOffPeakTask` |
| resume | `resume, continueTask, resumeOffPeakTask` |
| cancel | `cancel, cancelTask, cancelOffPeakTask` |
| delete | `delete, deleteTask, deleteOffPeakTask` |
| historyDelete | `deleteHistory, delete, deleteTask` |
| update | `updateTask, editOffPeakTask, updateOffPeakTask, update` |
| status | `getStatus, getQuota, status` |
| wake | `wake, wakeScheduler, off-peak-scheduler-wake-request` |

**skills**:`skills` 通道 `list`,args `[{workspacePath, workspaceIdentity?, provider:"glm"}]` → 数组或 `{skills:[…]}`,元素 `{id,name,path,scope,description,argumentHint,enabled}`。

### 11.3 已知远程可达 RPC 面(静态+实测,B §6.1/§10)

- `session/*`(host→CLI 内部层枚举,远程通道上**不可直用**):create, send, stop, resume, list, messages, read, events, event, subscribe, fork, compact, close, usage, subagents, goal, setModel, setMode, setThoughtLevel, cancelBackgroundTask, …
- `zcode-agent` V4 面(本规格 §6):hello/initialize/subscribe/unsubscribe/resync Conversation、rowsRange、plans、fileChanges、fileRewindPreview、sendCommand、queryCommands、onDynamicConversationFrame、attachmentBegin/Chunk/Commit/Abort/Read、sessionsIndex 家族、inputPrediction、workflowRunArtifacts*。
- `window-controller`:subscribe/unsubscribe/resync Controller、onDynamicControllerFrame、(listTaskList/mutateTask)。
- `file` 通道:resolvePath/stat/readTextFile/readFile(startLine/endLine 分段)/readFileRange/readMediaPreview/readBinaryPreview(**无写方法**;路径解析为 resolve 语义,绝对路径可越出工作区基座,安全敏感)。
- `zcode-session`:createSession、readWorkspaceState(`[{workspacePath, preferWorkspaceDefaults:true}]` → 当前模型/可用模型/思考档位/模式)、getWorkspaceRuntimeIdentity、setModel、setThoughtLevel、closeSession、updateProviderRegistry、`setMode`(agent 通道亦有:`{…scope, sessionId, mode}`,只对新 turn 生效)。
- `system.info`、`model-provider`(getAllCached/getAll)、`model-selection`(getView,含各模型合法思考档位)、`zcode-task.prepareWorkspace`、`skills.list`。
- [存疑] `zcode-task`/`workspace`/git 方法族的通道归属未逐一实测。

---

## 12. 参考实现差异与采信建议

| # | 差异点 | ZCode-Android(D) | ZLinker/zemote(E/G) | zcode-remote-app(F) | **采信建议** |
|---|---|---|---|---|---|
| 1 | clientHello | `clientKind` 按 hello clientMode 映射(desktop/web)、`appVersion:"unknown"`、带 `capabilities{workspaceHookReviewUi:true}` | `clientKind:"mobileApp"`、`appVersion:"3.6.5"`(注释:发 0.x 会禁用 V4 能力协商) | `clientKind:"mobileApp"`、`appVersion` 取 App 版本 | **F 口径**(`mobileApp` + 真实版本号);capabilities 字段省略(strict 风险);appVersion 不要低于 "3.x" |
| 2 | clientId | 进程级单例 UUID | transport 级 UUID | **每桥连接一份**(`v4ClientId`),三通道共用 | **F**:每连接一份,三通道共用,容忍 clientChanged |
| 3 | `reorderQueueItem` payload | `{queueItemIds:[完整有序 id 列表]}` | `{queueItemId, beforeQueueItemId:null=末尾}` | 未实现 | **[存疑] 二者形状冲突**。ZLinker 自称对齐 web schema(`CAS + beforeQueueItemId`),优先 ZLinker;真机验证失败再试 ZCode-Android 形状 |
| 4 | 取消后台工作 | type=`cancel`,payload `{workId}` | type=`cancelBackgroundWork`,payload `{workId}` | 未实现 | **[存疑] 冲突**。host 源码注释(F)提及 `sessionCancelBackgroundTask:"session/cancelBackgroundTask"` 为内部层;建议先 `cancelBackgroundWork`(语义明确),失败用 MethodProbe 试 `cancel` |
| 5 | attachment 参数带 `connectionId` | 带(取自 hello) | 带 | — | 带上(两实现一致且实测可用;PROTOCOL.md 称非必需,带上无害 [存疑:strict 拒绝风险极低]) |
| 6 | subscribe 超时 | 45s(重试一次) | 60s | HANDSHAKE_SUBSCRIBE_TIMEOUT(给足,官方 60s) | **60s + 一次重试** |
| 7 | 会话列表数据源 | bootstrap tasks(V1) | sessions-index + relay task 兜底 | **V2:window-controller**(bootstrap tasks 为空且 V2 栈时接管) | Swift 按 F 双栈:V1 用 bootstrap,V2 用 controller;判断 `protocolStack==V2 && bootstrap.tasks 为空` |
| 8 | 通道枚举 | 无 window-controller | Channels 33 个(含 window-controller) | 常量全集 + window-controller 实证 | **E 的枚举 + F 的实证归属** |
| 9 | stale 重试 | 实现(revisionAtDecision) | 实现 | 未做 CAS | **E/D 的 CAS + stale 重试**照抄 |
| 10 | 命令超时重发 | 无 | 仅桥 degraded 时换 commandId 重试一次 | 无 | **E 口径**(防双投递) |
| 11 | 历史翻页游标 | 曾误用 firstRowId(已修) | `hasMore` 优先,兜底 totalCount/到顶判定 | beforeRowId=window 首行 rowId | **E/F**:游标=当前最早已加载行 rowId;`canLoadOlder = hasMore ?? (windowFirst != storeFirstRowId) ?? totalCount>rows` |
| 12 | row.delta 批量 | 60ms 缓冲批量(16fps) | 直接逐条 | 直接逐条 | **D 的批量方案**(性能);path-kind 白名单三实现一致 |
| 13 | 逻辑帧 fragment 重组 | 有(60s 清理,无 crc 校验 [存疑:D 未校验 checksum]) | 有(30s 清理) | **有,逐规则转译官方 wire-reassembly.ts,含全等校验/违例 fault** | **F 的 WireReassembler** |
| 14 | 看门狗 | 20s 静默+运行中 | 20s 静默+运行中 **+ 10s 无快照强制 resync** | 同 E 语义 | **E 双看门狗** |
| 15 | zemote(G) | — | E 的旧子集:无 reorder/snooze/cancel/delete/rename/sessionSide/workflow/sendTextWithDelivery | — | 一律以 **ZLinker(E)** 为准 |

**总体采信优先级**:协议事实 → A(CONVERSATION-PROTOCOL,实测)> B/F(zcode-remote-app,最新实测)> E(ZLinker,命令面最全、与官方 web 对齐)> D(ZCode-Android,工程优化参考)> G(zemote,旧子集)。Swift 实现:帧层抄 F 的 `RpcChannel`+`WireReassembler` 语义,命令层抄 E 的 `ConversationTransport`,状态层抄 D 的 delta 缓冲 + E/F 的快照/翻页语义,Controller/sessions-index 抄 F。

---

## 13. 常量汇总表

| 常量 | 值 | 出处 |
|---|---|---|
| IPC 帧类型 | 100/101/102/103 出;200/201/202/203/204 入 | C §3.4 |
| `maxPhysicalFrameBytes`(rpc-frame 信封,dataBase64 长度上限) | 1 MiB | C §3.9 |
| `maxMessageBytes`(单条 IPC 报文) | 16 MiB | C §3.9 |
| `maxFragments`(rpc-frame) | 64(fragmentIndex ≤ 63) | C §3.9 |
| `assemblyTimeoutMs`(rpc-frame 组装) | 30 s | C §3.9 |
| 逻辑帧组装 | maxBytes 16 MiB / maxFragments 1024 / maxConcurrent 32 / maxStaged 32 MiB / timeout 30 s | C §3.9 |
| 订阅 staging | 1024 帧 / 32 MiB → `fault.subscription.initialFrameStagingOverflow` | C §7 |
| 重放缓冲 | max 8 MiB;高低水位 1 MiB/256 KiB;宽限 45 s(`replayBufferGraceMs`) | C §3.9/§6 |
| 身份串上限 | 256 字符(`transportEnvelopeIdMaxChars`) | C §3.9 |
| CRC-32 | 反射,poly 0xEDB88320,小写 8 位 hex | C §3.6 |
| base64 | 标准(含 `=` 填充),需可往返(isCanonicalBase64) | C §3.6 |
| seq/messageSeq 初值 | 均为 1,方向独立,新桥归 1 | C §6 |
| requestId | 从 0 自增,uint32 | C §3.5 |
| `conversationInputPredictionV4` draft 上限 | 4000 字符(超出客户端截断) | B §13.2 |
| 输入预测防抖/RPC 超时 | 600–800ms(取 700)/ 25s | B §13.2 |
| 命令对账批量上限 | 64 条/批 | B §13.3 |
| renderer 动作超时(task-pin 等) | 30 s | B §13.6 |
| attachment | 20MiB 总量 / 512KiB 服务端片 / 64 片 / TTL 5min / 未引用 24h;客户端片 384KiB | B §6.6 |
| 快照字节预算(v3.18.1 Web 远控) | messageLimit=10,byteBudget=200KB(软) | B §13.5 |
| 缓存命中率显示门限 | 0.78 | F ConversationFrames |
| bridge-open 看门狗 | 6s × 3 次(F 口径;正常 <1s) | F RpcChannel |
| 出站快速路径阈值 / 分片 | 700_000 B / 每片 700_000 B | F RpcChannel |
| 订阅超时 | 60s(官方);ZCode-Android 45s+重试 | E/D |
| 逻辑帧清理周期 / TTL | 30s 清理 / 60s TTL(D/E 口径) | D/E |
| delta 批量提交间隔 | 60ms(≈16fps) | D |
| 看门狗 | 10s 无快照强制 resync;20s 静默+运行中 resync;10s tick | E |
| resync 节流 | 5s(ResyncThrottle,conversation/controller 共参) | F ProtocolLimits |
| 事件流缓冲容量 | `RPC_EVENT_BUFFER_CAPACITY`(F,SUSPEND 背压,不丢帧) | F RpcChannel |
| conversation 翻页 limit | 上限 200(常用 60/100/200) | A §6.3 |
| autoResolution 倒计时 | ~5 分钟(snoozeInteractionAutoResolution 可推迟) | B §6.5 / E |

---

## 附:Swift 实现的最小落地清单(按依赖序)

1. **Vql Reader/Writer**(§3):tag 0–6 + ULEB128;`serialize([t,i,ch,m]) ++ serialize(x)`。
2. **ChannelClient**(§2):requestId 自增表、awaitReady(200)、100/102/103 出站、201/202/203 分发 + 204 事件流(挂监听 id)、每请求超时。
3. **rpc-frame transport**(§4):身份三元组(ready 回填)、出站切分+CRC32、入站组装+校验+ack(带全三元组!)、messageSeq 缺口检测 → 重订阅回调。
4. **桥生命周期**:open → ready(能力解析)→ error/degraded;新桥重置 seq/pending。
5. **V4 握手**(§5):hello(存 connectionId/protocolVersion/capabilities)→ initialize(每桥一个 clientId)。
6. **ConversationSubscription**(§6/§7):102 监听 + staging → subscribe(60s)→ wire/fragment 重组 → topic 帧 → snapshot/deltas 归约(rows + state)→ 看门狗 + resync + 翻页。
7. **命令层**(§6.7):envelope 工厂 + CAS/stale 重试 + ack 判据 + 命令账本(query 对账)。
8. **交互层**(§8):pendingInteractions 双源合并 → resolveInteraction(answer 形态表)。
9. **Controller/SessionsIndex**(§9/§10):裸帧归约 + resync;V2 会话列表。
10. 全链路容错:clientChanged 容忍、identity mismatch 静默丢弃、协议违例 → 重同步,未知 op/kind 宽容忽略 + 日志。
