# ZCode 官方远程控制协议 —— 帧编码层字节级规格(Swift 实现文档)

目的:供 Swift 1:1 实现「IPC 值编码 + CRC32 + rpc-frame 分片传输」三层。除标注 [存疑] 外,
所有字节级结论均可照抄。

参考来源与可信度:

| 编号 | 来源 | 角色 | 可信度 |
|---|---|---|---|
| [F] | `zcode-remote-app/research/FRAME-CODEC.md`(对官方 Web bundle 与 Electron asar 的逆向,函数级引用) | **权威**(§1–§3 及信封/分片/组装/ack 逐字代码) | 最高 |
| [K] | `ZCode-Android/app/src/main/java/app/zemote/protocol/IpcCodec.kt`、`RpcFrameTransport.kt`、`Proof.kt`、`ChannelClient.kt`、`BridgeSession.kt` | 独立复刻,真机跑通 | 高(实现细节参考) |
| [Z] | `ZLinker/lib/protocol/ipc_codec.dart`、`rpc_transport.dart`、`crc32.dart` | 同一复刻的早期版本 | 高 |
| [M] | `zemote/lib/protocol/*.dart` | [Z] 的演进版(接收侧放宽) | 高 |

本文所有十六进制示例、CRC32、base64 均由独立脚本机器验证
(`/Users/you/zcode-mobile/tmp-verify/verify.py`,自己实现官方语义后回读断言通过)。

注意:[F] §4.4 的手算示例有算术错误(`"zcode-agent"` 实为 11 字节非 12;总长实为 88 非 86;
"87B" 是笔误),本文示例以机器验证值为准。[F] 文首的更正说明(会话方法在 `zcode-agent` 通道、
`subscribeConversationV4` 用 type=100)对本文示例已生效。

---

## 1. 分层总览

```
┌─ WebSocket 中继(JSON 文本帧) ────────────────────────────────────────────┐
│ {"type":"data","payload":<P>,"client_ts":<epoch ms>}  (server_ts 由中继补) │
│  P = rpc-frame | rpc-frame-ack | workspace-bridge-* | bridge-degraded ...  │
└──────────────────────────────────────────────────────────────────────────────┘
              │ payload.dataBase64 → base64 解码(每片独立编码)
              ▼
┌─ 传输层:rpc-frame 分片重组 → 完整二进制消息(≤16 MiB) ────────────────────┐
└──────────────────────────────────────────────────────────────────────────────┘
              │ 完整字节流(bridge 路径上无额外帧头)
              ▼
┌─ RPC 序列化层(§2):serialize(header数组) ++ serialize(data) ──────────────┐
└──────────────────────────────────────────────────────────────────────────────┘
              │ ChannelClient 语义
              ▼
┌─ RPC 类型:100 Promise / 101 PromiseCancel / 102 EventListen / 103 EventDispose │
│           200 Initialize / 201 PromiseSuccess / 202/203 PromiseError* / 204 EventFire │
└──────────────────────────────────────────────────────────────────────────────┘
```

**关键事实(bridge 路径)**:`rpc-frame.dataBase64` 解码拼接后的字节**就是** RPC 序列化报文本身,
**没有** 13 字节 SocketProtocol 头。[M]/[Z] 接线注释明确:"Over the workspace bridge each
rpc-frame message IS one ChannelClient body (value-stream) — no 13-byte IPC framing on this
path";[K] 实际接线(`ChannelClient.sendBody = transport.sendMessage`,直接写值编码字节)亦然。
[K] `RpcFrameTransport.kt` 头注释"ChannelClient includes it (13-byte header)"是**过时注释**,
与代码不符,勿采信。13 字节头仅用于 CLI/SocketProtocol 接入路径,见 §2.9。

---

## 2. IPC 值编码(Vql 二进制)

对应官方 Web 客户端 `Sm()`/`Cm()`(序列化/反序列化)、`writeInt32VQL`/`readIntVQL`
(逆向报告 [F] §3.3 中的 `v`/`x`/`E`/`R`)。

### 2.1 varint(ULEB128)

- **7 bit 一组,低位组在前(little-endian group order)**;每字节最高位 bit7(0x80)是续接标志:
  `1` = 还有后续字节,`0` = 本组是最后一组。
- **无符号,无 zigzag**。
- 官方用 JS 32 位位运算(`e>>>7`、`e&127`)实现,函数名 `writeInt32VQL`/`readIntVQL`,
  即承载 **uint32**(0..4294967295)语义。实际协议中所有 varint 场景(长度、个数、Int 值)
  均为非负数且 ≤ 2^31-1。
- `0` 编码为单字节 `0x00`。
- [K]/[M] 读取端在 `shift==28 && (b & 0xF0)!=0` 时抛"varint overflow"(官方 JS 会静默截断到
  32 位;Swift 建议采用 [K] 的严格抛错)。

机器验证的编码表(照抄即对):

| 值(varint) | 字节 |
|---|---|
| 0 | `00` |
| 1 | `01` |
| 127 | `7F` |
| 128 | `80 01` |
| 300 | `AC 02` |
| 16384 | `80 80 01` |
| 100 | `64` |
| 2147483647 (0x7FFFFFFF) | `FF FF FF FF 07` |

写法伪代码(与官方逐字对应):

```
writeVarint(v: UInt32):
    if v == 0 { write(0x00); return }
    n = 使 v >>> (7*n) == 0 的最小 n   // 即字节数
    for i in 0..<n:
        b = v & 0x7F
        v >>>= 7
        if v > 0 { b |= 0x80 }
        write(b)
```

### 2.2 类型标签(tag,1 字节)

| tag | 官方名 | 载荷 |
|---|---|---|
| `0x00` | Undefined | 无载荷(0 字节) |
| `0x01` | String | `varint(byteLength) + UTF-8 字节` |
| `0x02` | Buffer(`Uint8Array`) | `varint(byteLength) + 原始字节` |
| `0x03` | VSBuffer | `varint(byteLength) + 原始字节`(与 0x02 字节级相同) |
| `0x04` | Array | `varint(elementCount) + 逐个元素递归编码` |
| `0x05` | Object(JSON) | `varint(byteLength) + JSON 文本的 UTF-8 字节` |
| `0x06` | Int | `varint(int32 值)`(无额外长度) |

tag 之外没有 magic、没有字段编号、没有 protobuf wire-type。未知 tag(>6)→ 解码失败
(官方 switch 无 default;[K]/[M] 显式抛 `unknown value tag`)。

### 2.3 各类型编码规则(官方 JS 语义,判定顺序即官方 `v()` 的 if 链顺序)

1. `undefined` → `0x00`,零载荷。(官方判定:`typeof e > "u"`)
2. `string` → `0x01 + varint(utf8字节数) + UTF-8 字节`。空串 → `01 00`(长度 0,后无字节)。
3. `Uint8Array` → `0x02 + varint(len) + 原始字节`。
4. `VSBuffer`(字节缓冲包装) → `0x03 + varint(len) + 原始字节`。
   **[K]/[M] 编码端只有一种字节类型并统一用 tag 3**;解码端 2/3 同样处理(见 §7)。
   Swift 建议:字节一律编 tag 3;解码 2/3 都接受。0x02/0x03 线上字节完全一致,互操作无影响。
5. `Array` → `0x04 + varint(元素个数) + 每个元素递归`。空数组 → `04 00`。
6. `number` 且 `(e|0)===e`(32 位整数,含负数!)→ `0x06 + varint`。
   ⚠️ 负数按 uint32 补码编码(如 -1 → `06 FF FF FF FF 01`),**读回会变成 4294967295(有损)**。
   协议实际值(type/id/长度/个数)均为非负,Swift 实现只需支持 0..2^31-1,负数走 JSON(见 §8 差异 2)。
7. 其余一切(`null`、`true`/`false`、浮点、超出 int32 的数、普通对象)→
   `0x05 + varint(len) + JSON.stringify(值) 的 UTF-8 字节`。
   - 官方对 JSON 里嵌套的 `Uint8Array` 有专门替换约定,见 §2.6。
   - `null` → `05 04 6E 75 6C 6C`(JSON 文本 `null`,4 字节)。**[K]/[M] 把 null 编成 tag 0**,
     见 §8 差异 1。

### 2.4 嵌套规则

- Array(tag 4)的元素可以是任意类型,递归无深度限制([K]/[M] 解码设了
  `MAX_CONTAINER_ITEMS = 100_000`、`MAX_VALUE_BYTES = 16 MiB` 防御上限,官方 JS 无此检查,
  属接收端加固,可照抄)。
- Object(tag 5)内部不再用 tag 编码——整体是一段 JSON 文本,嵌套的二进制走 §2.6 的 base64 约定。
- RPC 报文 = **两个顶层序列化值顺序拼接**(无总长度前缀,解码方按"值个数"消费,见 §2.7)。

### 2.5 边界情况(机器验证,照抄即对)

| 输入 | 编码 |
|---|---|
| `undefined` | `00` |
| `""`(空串) | `01 00` |
| `0` | `06 00` |
| `300` | `06 AC 02` |
| `"AB"` | `01 02 41 42` |
| `true` | `05 04 74 72 75 65` |
| `null`(官方语义) | `05 04 6E 75 6C 6C` |
| `3.5` | `05 03 33 2E 35` |
| `9007199254740991`(>int32) | `05 10 39 30 30 37 … 39 31`(JSON 数字文本,16 字节) |
| `[]`(空数组) | `04 00` |
| `Uint8List [0xFF]` | `03 01 FF` |

### 2.6 JSON 内嵌二进制约定(官方专用)

tag 5 的 JSON 由 `JSON.stringify(value, replacer)` 产生;replacer 把任何嵌套的 `Uint8Array`
替换为:

```json
{"__zcode_rpc_nested_uint8array_v1":true,"base64":"<标准 base64,含 = 填充>"}
```

解码侧 `JSON.parse(text, reviver)` 把该形状还原为 `Uint8Array`。
**[K]/[Z]/[M] 均未实现此替换**(Kotlin 的 Gson 会把 ByteArray 序列化为数字数组)。
Swift 若要 100% 对齐官方:编码前对参数树做此替换、解码后做 reviver;若只与官方桌面端互通且
参数中无裸二进制,可暂不实现(标注为兼容性 TODO)。

### 2.7 RPC 消息布局

一个 RPC 报文 = 两个顶层值先后序列化、直接拼接(无分隔、无总长):

- **客户端 → 服务端**(官方 `ChannelClient.sendRequest`):

  ```
  serialize([ type, id, channelName, method ])  ++  serialize(args)
  ```

  - `type`:100 Promise(调用)/ 101 PromiseCancel / 102 EventListen(订阅)/ 103 EventDispose(退订)
  - `id`:请求 id,**从 0 开始**自增(官方 `lastRequestId++`;[K]/[M] 同)
  - `channelName`:如 `"zcode-agent"`(会话 V4 方法所在通道;注意不是 `"zcode-session"`)
  - `method`:方法名字符串,如 `"subscribeConversationV4"`
  - `args`:调用参数**数组**(因此第二段以 `04 varint(n)` 开头);事件路径第二段是单个值
    (listen 时传监听参数,dispose 时为 `undefined` → `00`)

- **服务端 → 客户端**(置信中,[F] §3.5-B;[K]/[M] 的 `handleMessage` 与此一致):

  ```
  serialize([ type, id ])  ++  serialize(data)
  ```

  - `type`:200 Initialize(仅 `[200]`,无第二个值)/ 201 PromiseSuccess / 202 PromiseError /
    203 PromiseErrorObj / 204 EventFire
  - `data`:应答值或事件载荷

### 2.8 完整十六进制示例(全部机器验证)

**示例 1:最小 RPC 调用** `call("zcode-agent", "ping", args=[])`,请求 id=0:

```
serialize([100, 0, "zcode-agent", "ping"]) ++ serialize([])
```

字节(27 字节):

```
04                          Array tag(第一段:header)
04                          varint 元素个数 = 4
06 64                       Int tag + varint(100)          ← type=Promise
06 00                       Int tag + varint(0)             ← id=0
01 0B 7A 63 6F 64 65 2D     String tag + varint(11) + "zcode-agent"(11 字节)
   61 67 65 6E 74
01 04 70 69 6E 67           String tag + varint(4) + "ping"
04 00                       Array tag + varint(0)          ← 第二段:args=[]
```

- `messageBytes = 27`
- `checksum.value = "0919741f"`(CRC32,§3)
- `dataBase64 = "BAQGZAYAAQt6Y29kZS1hZ2VudAEEcGluZwQA"`(36 字符,无填充)
- `fragmentIndex=0, fragmentCount=1`

**示例 2:带对象参数的调用**([F] §4.4 的更正版)
`serialize([100, 0, "zcode-agent", "subscribeConversationV4"]) ++ serialize([{workspacePath:"/w", sessionId:"abc"}])`

字节(88 字节;JSON 精确文本 `{"workspacePath":"/w","sessionId":"abc"}` 恰 40 字节):

```
04                                   Array tag
04                                   varint(4)
06 64                                Int 100
06 00                                Int 0
01 0B "zcode-agent"                  (13 字节)
01 17 "subscribeConversationV4"      1+1+23 = 25 字节(方法名 23 字符)
04 01                                args: Array tag + varint(1)
05 28 7B 22 77 6F 72 6B 73 70 61 63 65 50 61 74 68 22 3A 22 2F 77 22 2C
   22 73 65 73 73 69 6F 6E 49 64 22 3A 22 61 62 63 22 7D
                                     Object tag + varint(40) + 40 字节 JSON
```

- `messageBytes = 88`
- `checksum.value = "c117de4b"`
- `dataBase64 = "BAQGZAYAAQt6Y29kZS1hZ2VudAEXc3Vic2NyaWJlQ29udmVyc2F0aW9uVjQEAQUoeyJ3b3Jrc3BhY2VQYXRoIjoiL3ciLCJzZXNzaW9uSWQiOiJhYmMifQ=="`(120 字符)
- 对应信封(键序照 §4):

```json
{"zcode_type":"rpc-frame","bridgeSessionId":"bridge-<uuid>","bridgeGeneration":1,
 "seq":1,"messageSeq":1,"fragmentIndex":0,"fragmentCount":1,"messageBytes":88,
 "checksum":{"algorithm":"crc32","value":"c117de4b"},"dataBase64":"BAQG…fQ=="}
```

**示例 3:服务端事件帧** `serialize([204, 7]) ++ serialize({"delta":"hi"})`:

```
04 02                       Array tag + varint(2)
06 CC                       Int 204
06 07                       Int 7
05 12 7B 22 64 65 6C 74 61 22 3A 22 68 69 22 7D
                            Object tag + varint(18) + {"delta":"hi"}(18 字节)
```

共 2+2+2+2+18 = 26 字节,messageBytes=26。(注:204 帧的真实载荷是 logical frame JSON,
见 [F] §7;此处为演示布局的构造值。)

### 2.9 13 字节 SocketProtocol 头(仅 CLI 路径,bridge 路径不用)

格式([Z] `IpcFraming`,溯源官方 `Mne()`/`Nne`;[F] §3.7 的 `p = f + 13`):

```
[type:u8][id:u32 大端][ack:u32 大端][bodyLen:u32 大端] + body
```

- `type` 常量 `typeRegular = 1`;[K]/[M] 的 `ChannelClient` **不**加该头。
- Swift 实现 bridge(WebSocket 中继)接入时:**完全不需要**此头。仅在对接 CLI 子进程
  stdio/socket 形态 host 时才用。该路径下 `dataBase64` 内可能是 NDJSON 文本行
  (`{"method":"v4/...","params":{...}}\n`),判定:解 base64 后首字节 `0x04` = 二进制 RPC,
  `0x7B`(`{`)= NDJSON([F] §3.7,置信中)。

---

## 3. CRC32

**CRC-32/IEEE(iso-hdlc),反射实现,即 zlib/PNG 的标准 CRC32。**

| 参数 | 值 |
|---|---|
| 多项式 | 0xEDB88320(0x04C11DB7 的反射形式) |
| 初始值 | 0xFFFFFFFF |
| 输入/输出反射 | 是(按位右移实现) |
| 最终异或 | 0xFFFFFFFF |
| 测试向量 | `crc32("123456789") = cbf43926`;`crc32(b"") = 00000000` |

逐位参考实现([F] `Gr`、[K] `Proof.kt Crc32`、[Z]/[M] `crc32.dart` 三方一致):

```
crc = 0xFFFFFFFF
for byte in bytes:
    crc ^= byte
    repeat 8: crc = (crc >>> 1) ^ (crc & 1 ? 0xEDB88320 : 0)
return crc ^ 0xFFFFFFFF        // 取无符号 32 位
```

输出格式:小写 16 进制,不足 8 位左侧补 `0`,共 8 字符
(`Integer.toHexString(...).padStart(8,'0')` / `toRadixString(16).padLeft(8,'0')` /
`toString(16).padStart(8,'0')` 三方等价)。zod 校验正则 `^[0-9a-f]{8}$`。

**校验对象:整条拼接后的消息字节(不是单个分片,也不是 base64 文本)。** 分片级 CRC 仅出现在
接收端去重指纹里(§6.2),不上线。

---

## 4. rpc-frame JSON 信封

### 4.1 外层中继信封

```json
{"type":"data","payload":<rpc-frame 或 rpc-frame-ack 或控制帧>,"client_ts":<epoch 毫秒>}
```

- 手机端上行只带 `client_ts`;`server_ts` 由中继/服务端补(可选)。
- `maxPhysicalFrameBytes = 1 MiB` 作用于**整条外层 JSON 的 UTF-8 字节数**(含 base64 与全部字段)。
- PC 端在 `workspace-bridge-ready` 发出前不会发送任何 rpc-frame(`readyAnnounced` 门禁);
  手机端在 ready 前也不应发送。

### 4.2 `rpc-frame` 字段表(官方 zod `.strict()`,出现未列出键即非法)

| 字段 | 类型 | 必需 | 约束 |
|---|---|---|---|
| `zcode_type` | 字面量 `"rpc-frame"` | 是 | |
| `bridgeSessionId` | string | 是 | 1..256 字符,`^[A-Za-z0-9._~-]+$` |
| `bridgeGeneration` | int | 否 | ≥0,≤ 2^53-1 |
| `recoveryId` | string | 否 | 1..256 字符,同上正则;仅恢复流程出现 |
| `seq` | int | 是 | >0,≤ 2^53-1,物理帧序号(§5.2) |
| `messageSeq` | int | 是 | >0,≤ 2^53-1,逻辑消息序号 |
| `fragmentIndex` | int | 是 | 0..63,且必须 < fragmentCount |
| `fragmentCount` | int | 是 | 1..64,且 ≤ messageBytes(superRefine) |
| `messageBytes` | int | 是 | >0,≤ 16 MiB,整条消息拼接后字节数 |
| `checksum.algorithm` | `"crc32"` | 是 | |
| `checksum.value` | string | 是 | `^[0-9a-f]{8}$`,整条消息的 CRC32 |
| `dataBase64` | string | 是 | 规范 base64:长度 4..1 MiB 字符,解码后 ≥1 字节,且 re-encode 必须与原串完全一致(`isCanonicalBase64`) |

JSON 键的**生成顺序**(官方 `Lf`,Swift 编码时照此序,虽然对端 zod 不查顺序):

```
zcode_type, bridgeSessionId, [bridgeGeneration], [recoveryId],
seq, messageSeq, fragmentIndex, fragmentCount, messageBytes,
checksum{algorithm,value}, dataBase64
```

`identity` 三元组一律取自 `workspace-bridge-ready` 的 `bridge` 对象回显
(`{bridgeSessionId, bridgeGeneration?, recoveryId?}`;`bridgeGeneration`/`recoveryId` 为
undefined 时整个键不出现)。

### 4.3 `rpc-frame-ack`

```json
{"zcode_type":"rpc-frame-ack","bridgeSessionId":"…","bridgeGeneration":1,"recoveryId":"…","ackMessageSeq":3}
```

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `zcode_type` | `"rpc-frame-ack"` | 是 | |
| `bridgeSessionId` | string | 是 | 同上正则 |
| `bridgeGeneration` | int | 否 | 官方信封构造器会回带规范化 identity;建议 Swift 回带(§8 差异 8) |
| `recoveryId` | string | 否 | 同上 |
| `ackMessageSeq` | int | 是 | >0,≤ 2^53-1,**累计确认**:已完整收到的最大 messageSeq |

### 4.4 常量与上限总表

| 常量 | 值 | 用途 |
|---|---|---|
| `maxPhysicalFrameBytes` | 1 MiB(1,048,576) | 单个外层 JSON 帧 UTF-8 字节数上限 |
| `maxMessageBytes` | 16 MiB | 单条逻辑消息(recommend 发送与接收都用此值,见 §8 差异 7) |
| `maxFragments` | 64 | 单条消息分片数上限 |
| `assemblyTimeoutMs` | 30,000 ms | 组装器超时 |
| `transportIdMaxChars` | 256 | bridgeSessionId / recoveryId 最大长度 |
| `logicalFrameAssembly*` | 16 MiB / 1024 片 / 并发 32 / 暂存 32 MiB / 30 s | 应用层 logical frame 组装(超出本文档范围) |
| 重放缓冲 | 8 MiB;高水位 1 MiB / 回落 256 KiB;宽限 45 s | 官方 AcknowledgedRelayProtocol 流控 |

---

## 5. 发送端流程

### 5.1 切分算法

输入:完整 RPC 报文字节 `bytes`(即 §2.7 两段拼接的结果,bridge 路径不加 13 字节头)。

1. `bytes.isEmpty` → 抛 `remote.rpcFrame.emptyMessage`;`bytes.count > maxMessageBytes` → 抛
   `remote.rpcFrame.messageTooLarge`。
2. `checksum = {algorithm:"crc32", value: crc32hex(bytes)}` —— **对整条消息算一次**。
3. 定单片最大解码字节数 `p`:
   - **官方(权威)**:二分求最大 `p`,使"最坏信封"(client_ts/server_ts 取 2^53-1 的位数、
     id 字段取 256 字符、fragmentIndex 取 fragmentCount-1、fragmentCount 十进制位数回代重算)
     的 JSON UTF-8 字节数仍 ≤ 1 MiB。`fragmentCount = ceil(messageBytes / p)` 需满足 ≤ 64,
     否则抛 `remote.rpcFrame.fragmentLimitExceeded`;p < 1 抛 `remote.rpcFrame.envelopeTooLarge`。
   - **[K]/[Z]/[M](已验证可用)**:固定 `p = 512 KiB`。校验:512 KiB → base64 682,688 字符,
     加信封开销 < 1 MiB,安全。Swift 可采固定 512 KiB。
4. 分片**等长**:第 i 片 = `bytes[i*p ..< min((i+1)*p, messageBytes)]`(最后一片可短)。
5. 每片独立 base64(标准字母表 + `=` 填充,无换行;[K] 用 `Base64.NO_WRAP`,[M] 用
   `dart:convert base64.encode`,等价)。

### 5.2 `seq` 与 `messageSeq` 的递增规则(关键,错会被对端判 terminal 故障)

- **每个方向独立维护一套,每个 bridge 身份(三元组)独立维护一套**;方向 = 手机→PC、PC→手机,
  互不相干。
- 初值:**两者都从 1 开始**(`nextPhysicalSeq=1; nextMessageSeq=1`)。
  [K]/[M] 内部置 0 再先加后用,线上第一个值同样是 1,等价。
- `seq`(物理帧序号):每发一个分片 +1;`seq = firstPhysicalSeq + fragmentIndex`,
  `firstPhysicalSeq = 上一条消息最后一片的 seq + 1`。**全局连续、不允许跳号/重号**(重放
  场景例外:同 seq 同内容重发会被去重,见 §6.2)。
- `messageSeq`(逻辑消息序号):一条消息的所有分片共用同一个 `messageSeq`;消息发完后 +1。
- 这两个序号**不由业务层决定**,由传输层统一分配;`requestId`(RPC 层 id,从 0 起)与之无关。
- 换桥(recovery 重开)后:新 bridge = 新的一套计数器,从 1 重新开始(官方在 ready 后重建
  协议栈;[K] `swapBridge`、[M] `_attachStack` 亦整体重建)。

### 5.3 `checksum` 与 `dataBase64` 语义(再次强调)

- `checksum.value` = **整条消息**(所有分片拼接后)的 CRC32;不是分片的、不是信封 JSON 的。
- `dataBase64` = **本分片内容**的 base64;不是整条消息的。
- `messageBytes` = 整条消息字节数(所有分片解码后长度之和必须等于它)。

### 5.4 发送门禁

- 必须先完成 `workspace-bridge-open` → 收到 `workspace-bridge-ready`(身份三元组从
  `ready.bridge` 取),且未处于 degraded 状态,才允许发 rpc-frame。
- 官方还有流控(高水位 saturated 暂发/低水位 drained 恢复 + 8 MiB 重放缓冲 + 45 s ack 宽限);
  [K]/[M] 未实现流控,靠 bridge 重开兜底(见 §8 差异 9)。

---

## 6. 接收端流程

### 6.1 入口分流

收到 WS 文本 → `JSON.parse` → `type === "data"` → 取 `payload`:

- `payload.zcode_type === "rpc-frame" | "rpc-frame-ack"` → 交给帧传输层;
- `"bridge-degraded"` → §6.6;
- 其余 → 控制帧匹配器(`workspace-bridge-ready` 等,响应**不保证**回带 requestId,需用
  matcher 逐个测试——[M] `_dispatchPayload` 注释)。

身份匹配:官方 `a2t` 要求 `bridgeSessionId / bridgeGeneration / recoveryId` **三个字段全等
(含 undefined===undefined)**才接受。bridgeGeneration 已设但来帧未带 → 不匹配 → 丢弃。
[K] 只比对 bridgeSessionId,较宽松(见 §8 差异 8)。

### 6.2 重组器(官方 `WebRemoteControlRpcTransportAssembler.accept` 状态机,权威)

状态:`expectedPhysicalSeq`(初值 1)、`expectedMessageSeq`(初值 1)、`active`(当前正在组装
的消息:`fragments[]`、`fragmentCount`、`messageBytes`、`checksum.value`、`stagedBytes`)、
已见帧指纹表。对每个 `rpc-frame` 依次:

1. 身份不匹配 → `remote.rpcFrame.identityMismatch`。
2. `dataBase64` 超长或非规范 base64(重编码不还原)→ `remote.rpcFrame.invalidBase64`。
3. zod 校验失败 → `remote.rpcFrame.invalidMetadata`;`messageBytes > 16 MiB` →
   `messageTooLarge`;`fragmentCount > 64` → `fragmentLimitExceeded`;信封 > 1 MiB →
   `envelopeTooLarge`。
4. **去重指纹** = `JSON.stringify([identity…, seq, messageSeq, fragmentIndex, fragmentCount,
   messageBytes, checksum.algorithm, checksum.value, sliceBytes, crc32(sliceBytes)])`:
   - 与已见指纹完全一致 → `kind:"duplicate"`,**重新 ack 上次完成的 messageSeq,不重复投递**;
   - 同键指纹冲突 → `remote.rpcFrame.conflictingDuplicate`(terminal)。
5. `seq < expectedPhysicalSeq` → duplicate(重放旧帧,重新 ack);
   `seq > expectedPhysicalSeq` → `remote.rpcFrame.physicalGap`(**terminal**,触发降级)。
6. `messageSeq !== expectedMessageSeq` → `remote.rpcFrame.messageGap`(terminal)。
7. `fragmentIndex !== active.fragments.length`(当前消息内必须从 0 起严格连续)→
   `remote.rpcFrame.fragmentGap`。
8. 与 active 的 `fragmentCount`/`messageBytes` 不一致 → `metadataMismatch`;
   `checksum.value` 不一致 → `checksumMismatch`;`stagedBytes + 本片长 > messageBytes` →
   `lengthMismatch`。
9. 追加分片,`expectedPhysicalSeq += 1`;`fragments.length < fragmentCount` → `incomplete`。
10. 齐了之后:`stagedBytes !== messageBytes` → `lengthMismatch`;拼接全部分片 →
    `crc32(bytes) !== checksum.value` → `checksumMismatch`;否则
    `kind:"complete", messageSeq, bytes` —— bytes 即完整 RPC 报文,交给 ChannelClient。

超时:`assemblyTimeoutMs = 30 s` 内未 complete 的 active 组装报超时故障([Z]/[M] 用 60 s
周期清理兜底,[K] 无超时,见 §8 差异 6)。

**[K]/[Z]/[M] 的简化重组器**(实现更简单、真机可用):按 `messageSeq` 建表
`Assembly(crc32, fragmentCount)` + `fragments[index]`,乱序到达直接落槽,集齐即拼接校验,
不校验 seq 连续性/去重指纹/终止故障。Swift 两种都可;若要与官方桌面端对等严格,
照官方状态机实现。

### 6.3 乱序 / 丢片处理

- **官方语义:不容忍乱序与丢片**。seq 有洞 → `physicalGap`(terminal);乱序提前到 → 同样判
  gap/fragmentGap;丢片只能靠发送端重放补齐(重放帧 seq 与原帧相同,指纹去重)。
- 简化实现([M]):乱序容忍(按 index 落槽),丢片靠 60 s 过期清理;消息永远不齐则最终靠
  bridge 重开兜底。**注意**:官方桌面端作为发送方不会乱序/丢片(可靠 WS + 严格发送序),
  所以简化实现真机无恙。

### 6.4 rpc-frame-ack 的发送

- **何时发**:每完整收到一条消息(complete)后,发送
  `{"zcode_type":"rpc-frame-ack", identity…, "ackMessageSeq": <该消息的 messageSeq>}`。
  官方为**累计确认 + 合并**:`pendingAckMessageSeq` 取更大者,借下一次 flush 一起发。
  [K]/[M] 是每消息立即一条(语义等价,流量略多)。
- **ack 哪个字段**:`ackMessageSeq`(不是 seq!)。收到方处理:`ack ≤ lastAckedMessageSeq`
  → 忽略;`ack > highestFullySentMessageSeq`(ack 了没发过的消息)→ `remote.rpcFrame.futureAck`
  (terminal 降级);否则释放重放缓冲至该 messageSeq。
- **bridgeGeneration 是否必须回带**:schema 中可选;官方信封构造器回带规范化 identity 全集。
  由于对端身份匹配是三字段全等,**身份里存在 bridgeGeneration 时 ack 必须回带**,否则会被
  丢弃导致对端重放不止、45 s 后 ackGraceExceeded 降级。[M] 的 ack 只带 bridgeSessionId
  (见 §8 差异 8),Swift 建议**完整回带 identity**。

### 6.5 replay(重放)怎么发

- 官方手机端没有"replay 请求"这种对端消息;重放是**发送端本地行为**:
  `onSendReady`(WS 重新可写)→ `replayUnacknowledged()` → 把所有
  `messageSeq > lastAckedMessageSeq` 的批次 `nextFrameIndex` 归零,**原样重发全部未确认帧**
  (seq 不变)。接收端按指纹判 duplicate → 重新 ack → 不重复投递。
- 触发条件:发送就绪回调、且未 degraded。配合 45 s 宽限:45 s 内既没收到数据 ack 也没发出
  ack → `ackGraceExceeded` / `replayGraceExceeded`(terminal)。
- [K]/[M] **未实现重放**:WS 重连即走 bridge 重开(§6.6),不做帧级重传。该策略已被真机
  验证可用(桌面端超时未 ack 会主动 bridge-degraded,手机端重开)。Swift 二选一即可,
  简单起见推荐 [K] 策略。

### 6.6 bridge-degraded 触发与恢复

**触发**(PC 端发出,手机端接收):

```json
{"zcode_type":"bridge-degraded","bridgeSessionId":"…","bridgeGeneration":1,"recoveryId":"…",
 "reason":"rpc-transport-fault","seq":123,"expectedSeq":124,"droppedCount":2}
```

- `reason` ∈ `rpc-transport-fault | rpc-frame-gap | buffer-overflow | buffer-timeout`;
  `seq/expectedSeq/droppedCount` 可选,用于诊断 gap。
- 上游诱因:接收端 terminal 故障(physicalGap/messageGap/conflictingDuplicate/futureAck 等)、
  45 s ack 宽限超时、重放缓冲 8 MiB 溢出、组装超时。

**恢复**(官方 Web 客户端流程,[F] §4.1/§Q3,权威):

1. 收到 bridge-degraded → `markDegraded()`,停止在该桥上收发。
2. 生成新 `bridgeSessionId = "bridge-" + uuid()`、`bridgeGeneration = ++gen`(每次 open 自增,
   **全局计数器,不是每桥独立**——[M]/[K] 的 `_bridgeGeneration` 也是 client 级字段)。
3. 进入恢复流程时生成 `recoveryId = "recovery-" + uuid()`,随**下一次**
   `workspace-bridge-open` 一并上行(`workspaceKey` 必带);收到 ready 后清空(用后即清)。
4. 等 `workspace-bridge-ready`(match `bridgeSessionId`)→ 从 `ready.bridge` 取新 identity
   → 重建传输层与 ChannelClient(seq/messageSeq 从 1 重新开始)→ 重新等待 `200 Initialize`
   → 重建业务订阅(resubscribe)。
5. relay 静默重连(心跳超时、换网、休眠)同样走此恢复路径。

[K]/[M] 与官方一致,唯一差异:它们的 `recoveryId` 取自**旧 ready.bridge 里的 recoveryId**
(通常不存在 → 不上行),而不是恢复时新生成 `recovery-<uuid>`。[存疑] 两说并存:
官方逆向([F])明确是恢复时新生成;[K]/[M] 复用旧值且真机跑通,说明桌面端对缺省
recoveryId 容忍(把它当全新桥)。Swift 建议:**按官方生成 `recovery-<uuid>`**(语义是
"要恢复哪个旧会话"),最坏情况与 [K]/[M] 一样成立。

失败路径:`workspace-bridge-error` 的 `reason` ∈
`session-not-found | session-expired | session-conflict | workspace-closed | desktop-disconnected |
invalid-mobile-connection | desktop-bootstrap-timeout | connection-recovery-timeout |
relay-unavailable | unsupported-action | unexpected-error`。[M] 恢复循环:最多 15 次、间隔 3 s。

---

## 7. Kotlin `IpcCodec.kt` public API ↔ Swift 对照表

`IpcCodec.kt`(/Users/you/zcode-mobile-refs/ZCode-Android/app/src/main/java/app/zemote/protocol/IpcCodec.kt)
全部 public 成员(私有常量一并附上,Swift 需要同款防御):

| Kotlin | 签名 | 语义 | Swift 对应建议 |
|---|---|---|---|
| `ValueWriter` | `class ValueWriter(initialCapacity: Int = 256)` | 无锁可增长字节缓冲(勿用同步的 ByteArrayOutputStream) | `struct ValueWriter` 或 `final class`,容量翻倍策略 |
| ↳ | `fun writeByte(v: Int)` | 写 1 字节(`v.toByte()`) | `mutating func writeByte(_ v: UInt8)` |
| ↳ | `fun writeBytes(b: ByteArray)` | 批量写入;空数组跳过 | `writeBytes(_ b: [UInt8])` |
| ↳ | `fun writeVarint(value: Int)` | ULEB128 写入(§2.1,do-while 保证 0 → 单字节 0x00) | `writeVarint(_ v: UInt32)` |
| ↳ | `val size: Int` | 已写字节数 | `var count: Int` |
| ↳ | `fun toByteArray(): ByteArray` | 复制出结果;空时返回共享 `EMPTY_BYTES` | `func bytes() -> [UInt8]` |
| `ValueReader` | `class ValueReader(data: ByteArray)`;`var pos: Int`;`val remaining: Int` | 游标式读取器 | `final class ValueReader`,同字段 |
| ↳ | `fun readByte(): Int` | 读 1 字节(0..255),越界抛 `IllegalArgumentException("Not enough data")` | `func readByte() throws -> UInt8` |
| ↳ | `fun read(n: Int): ByteArray` | 读 n 字节;n==0 返回共享空数组;越界抛 | `func read(_ n: Int) throws -> [UInt8]` |
| ↳ | `fun readUtf8(n: Int): String` | 读 n 字节直接按 UTF-8 解 String,不复制中间数组(大 JSON 字段的性能优化) | `func readUtf8(_ n: Int) throws -> String` |
| ↳ | `fun readVarint(): Int` | ULEB128 读取;`shift==28 && (b&0xF0)!=0` 抛 "varint overflow";截断抛 "invalid varint" | `func readVarint() throws -> UInt32` |
| `encodeValue` | `fun encodeValue(w: ValueWriter, value: Any?)` | 编码规则:**null→tag0**;String→1;ByteArray→**3**;List→4;Int∈[0,0x7FFFFFFF]→6(否则转 Long 路径);Long→tag5 **带引号**十进制字符串(如 `"123"`,差异见 §8-3);其余(Map/Boolean/Float)→tag5 Gson JSON | `func encodeValue(_ w: inout ValueWriter, _ v: IPCValue)`(用 enum 建模强类型) |
| `decodeValue` | `fun decodeValue(r: ValueReader): Any?` | tag0→null;1→UTF-8 String(len>16MiB 抛 "string too large");2/3→ByteArray(同上限);4→ArrayList(count>100_000 抛 "list too large",预分配 cap 64);5→Gson JSON(→LinkedHashMap/ArrayList,同上限);6→Int;其他抛 `unknown value tag` | `func decodeValue(_ r: ValueReader) throws -> IPCValue` |
| 私有常量 | `MAX_CONTAINER_ITEMS = 100_000` | 解码防御:数组元素数上限 | 同值 |
| ↳ | `MAX_VALUE_BYTES = 16 MiB` | 解码防御:单值字节数上限 | 同值 |
| ↳ | `LIST_PRESIZE_CAP = 64` | 列表预分配上限(防伪造大 count 的内存攻击) | 同值 |

配套(同包其他文件,Swift 需要同款):

- `Proof.kt` → `object Crc32 { fun compute(ByteArray): Int; fun hexOf(ByteArray): String }`(§3);
  `generateRequestId(prefix) = "<prefix>-<uuid4>"`(bridgeSessionId/requestId 生成,满足
  `^[A-Za-z0-9._~-]+$`)。
- `RpcFrameTransport.kt` → 构造参数 `bridgeSessionId / bridgeGeneration / recoveryId /
  sendPayload: (Map<String,Any>) -> Unit / onLog`;`sendMessage(ByteArray)`(§5);
  `acceptPayload(Map<String,Any>): Boolean`(§6);`onMessage: ((ByteArray) -> Unit)?`(完整消息
  回调,直接喂 ChannelClient);`dispose()`。常量 `MAX_FRAGMENT_BYTES=512KiB /
  MAX_MESSAGE_BYTES=16MiB / MAX_FRAGMENTS=64`。
- `ChannelClient.kt` → `call(channel, method, args, timeoutMs)`:`encodeValue(listOf(100,id,
  channelName,method)) + encodeValue(args)` 后整体交给 transport;`addEventListener` 用
  102/103;`handleMessage(frame)` 按两段值解码(§2.7);`awaitReady` 30 s 等 `200 Initialize`。

---

## 8. 参考实现差异点与采信结论

| # | 差异点 | 官方 [F] | [K] ZCode-Android | [Z] ZLinker / [M] zemote | 采信(理由) |
|---|---|---|---|---|---|
| 1 | `null` 编码 | tag5 `"null"`(undefined 才是 tag0) | null→tag0 | null→tag0 | **官方**。但注意官方 dispose 帧第二值就是 `undefined`(tag0),[K] 用 null 表达 undefined 恰好一致;Swift 建议:建模区分 nil-as-undefined(默认)即可,参数树里避免出现 JSON null |
| 2 | 负整数 | (e\|0)===e → tag6,uint32 补码,读回有损 | 负 Int 转 Long→JSON | 负 → JSON | **[K]/[M]**(官方行为有损,协议实际无负数;Swift:Int 只支持 0..2^31-1,负数/超界走 JSON) |
| 3 | 超大整数(>int32) | tag5,JSON **数字**(无引号) | Long → tag5 **带引号字符串** `"123"` | jsonEncode → 无引号数字 | **[Z]/[M]/官方**。Kotlin 的带引号形式会让对端 JSON.parse 得到 string 而非 number,属 [K] 偏差(其注释声称等价,存疑) |
| 4 | 字节类型 tag | 2=Buffer,3=VSBuffer 分开 | 只有 ByteArray→tag3;解码 2/3 同 | 同 [K] | 采纳 [K](线上字节一致,无互操作影响) |
| 5 | JSON 内嵌 Uint8Array | `__zcode_rpc_nested_uint8array_v1` + base64 包装 | 未实现 | 未实现 | **官方**;当前参数集无裸二进制时可延后,Swift 标 TODO |
| 6 | 组装超时 | 30 s(`assemblyTimeoutMs`) | 无 | 60 s 周期清理 | 官方 30 s;[M] 60 s 更宽松也真机可用;Swift 建议 30-60 s 均可,须有 |
| 7 | 接收上限 | 16 MiB / 64 片 | 16 MiB / 64 片 | [Z] 16MiB/64;[M] **64 MiB / 256 片**(为长上下文快照故意放宽,issue #9) | **发送端必须官方值**(对端 zod 硬校验 16MiB/64);接收端可采 [M] 放宽值 |
| 8 | 身份匹配 / ack 回带 | 三字段全等;信封回带完整规范化 identity | 只比 bridgeSessionId;ack 回带全部 identity(有则带) | [Z] 同 [K];[M] ack 只带 bridgeSessionId | **官方**(三字段全等最安全;identity 有 generation/recoveryId 时 ack 必须回带,否则可能被对端丢弃 → 无限重放 → 降级) |
| 9 | 重放/流控 | replayUnacknowledged + 水位 + 45 s 宽限 + 8 MiB 缓冲 | 无(重开桥兜底) | 无(重开桥兜底) | 官方最完整;但 [K]/[M] 的"降级即重开桥"已真机验证,Swift 简单版可采后者 |
| 10 | recoveryId 来源 | 恢复时新生成 `recovery-<uuid>`,ready 后清空 | 复用旧 ready.bridge.recoveryId(通常无) | 同 [K] | **官方**([存疑] 桌面端对缺省容忍,[K] 跑通为证;Swift 按官方生成) |
| 11 | 分片预算 | 动态二分(最坏信封 ≤1MiB) | 固定 512 KiB | 固定 512 KiB | 均可;固定 512 KiB 简单且数学上安全(682,688 base64 字符 + 开销 < 1 MiB) |
| 12 | 信封键序 | zcode_type 在前,identity 次之 | identity 在前,zcode_type 后 | zcode_type 在前 | 对端不查键序,任意;Swift 照官方序 |
| 13 | [K] ack 处理小瑕疵 | — | 收到 rpc-frame-ack 时 `assemblies.remove(ackSeq)`,把出站 ack 序号当入站组装表键删除,语义混用(碰巧无害) | 忽略 ack(`return true`) | Swift:ack 只用于释放出站重放缓冲(若实现重放);无重放则忽略 |
| 14 | FRAME-CODEC §4.4 手算 | 总长 86/87 有误 | — | — | 本文 §2.8 机器验证 88 字节(“zcode-agent” 11 字符),以此为准 |

---

## 9. Swift 移植最小清单

1. `VarintWriter/Reader`(ULEB128,UInt32,§2.1)。
2. `IPCValue` enum(undefined/string/bytes/array/int/object)+ `encode/decode`(§2.2-2.5,
   解码防御上限照 §7)。解码端 tag 2/3 同处理;编码端字节用 tag 3。
3. `CRC32`(表驱动或逐位,§3,`hex8()` 小写补零;用 `"123456789"→cbf43926` 做单测)。
4. `RpcFrameTransport`:
   - 发送(§5):整条消息 CRC32 → 512 KiB 等分 → 每片独立 canonical base64 → 键序照 §4.2;
     `seq` 每片 +1 从 1 起无跳号,`messageSeq` 每消息 +1 从 1 起;每方向/每桥独立。
   - 接收(§6):身份三字段全等过滤 → 按 messageSeq 组装(乱序落槽即可,官方桌面端不会乱序)
     → 集齐后比对 `stagedBytes == messageBytes` 且 CRC32 一致 → 完整 ack(累计)
     → 投递 `onMessage`。
   - 超时清理 30-60 s;degraded 后停止收发。
5. `ChannelClient`(§2.7/§7):id 从 0 自增;两段值编码;`200` 置 ready(30 s 超时);
   `201/202/203` 完成 promise;`204` 派发事件。
6. 桥生命周期(§6.6):open(生成 `bridge-<uuid>`、`++generation`)→ ready 取 identity →
   传输;`bridge-degraded` 或 relay 重连 → 新 `recovery-<uuid>` + 新 bridgeSessionId 重开 →
   重建传输/通道/订阅。
7. base64:标准字母表 + `=` 填充、无换行、编码后须与 `String(data:…)`往返一致。
