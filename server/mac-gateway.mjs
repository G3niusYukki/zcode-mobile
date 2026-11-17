#!/usr/bin/env node
/**
 * ZCode Mobile · Live Activity APNs 网关(在本机 Mac 上常驻)
 *
 * 数据来源:
 *   - 中转(Cloudflare Worker):App 上报的活动 push token 与完整状态
 *   - 本机 ZCode 桌面日志:agent.pendingPermissions / pendingUserInputs / bots.runningTasks
 * 合并后直推 APNs,实现锁屏/灵动岛的真后台更新。
 *
 * 用法:
 *   RELAY_URL=https://xxx.workers.dev \
 *   SECRET=change-me \
 *   APNS_KEY_PATH=./AuthKey_ABC123.p8 \
 *   APNS_KEY_ID=ABC123 \
 *   APNS_TEAM_ID=TEAM123456 \
 *   BUNDLE_ID=dev.example.ZCodeMobile \
 *   APNS_ENV=sandbox \
 *   node server/mac-gateway.mjs
 *
 * 说明:自签/开发版用 sandbox,TestFlight/App Store 用 production。
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import http2 from "node:http2";
import os from "node:os";

const RELAY_URL = (process.env.RELAY_URL || "").replace(/\/$/, "");
const SECRET = process.env.SECRET || "";
const KEY_PATH = process.env.APNS_KEY_PATH || "";
const KEY_ID = process.env.APNS_KEY_ID || "";
const TEAM_ID = process.env.APNS_TEAM_ID || "";
const BUNDLE_ID = process.env.BUNDLE_ID || "dev.example.ZCodeMobile";
const APNS_HOST = (process.env.APNS_ENV || "sandbox") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";
const POLL_MS = Number(process.env.POLL_MS || 5000);
const LOG_DIR = process.env.ZCODE_LOG_DIR || path.join(os.homedir(), ".zcode", "v2", "logs");

if (!RELAY_URL || !SECRET) {
  console.error("缺少 RELAY_URL 或 SECRET");
  process.exit(1);
}

// ---------- APNs JWT(ES256) ----------

let cachedJWT = { value: "", expiresAt: 0 };

function apnsJWT() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT.value && cachedJWT.expiresAt > now + 60) return cachedJWT.value;
  const key = fs.readFileSync(KEY_PATH, "utf8");
  const header = { alg: "ES256", kid: KEY_ID };
  const claims = { iss: TEAM_ID, iat: now };
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const signingInput = `${enc(header)}.${enc(claims)}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key, dsaEncoding: "ieee-p1363",
  });
  const token = `${signingInput}.${signature.toString("base64url")}`;
  cachedJWT = { value: token, expiresAt: now + 3000 };
  return token;
}

function sendAPNs(pushToken, payload) {
  return new Promise((resolve) => {
    const client = http2.connect(APNS_HOST);
    client.on("error", (e) => resolve({ ok: false, error: String(e) }));

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${pushToken}`,
      "apns-topic": `${BUNDLE_ID}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "authorization": `bearer ${apnsJWT()}`,
    });
    let body = "";
    let status = 0;
    req.on("response", (h) => { status = Number(h[":status"] || 0); });
    req.setEncoding("utf8");
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      client.close();
      resolve({ ok: status === 200, status, body });
    });
    req.end(JSON.stringify(payload));
  });
}

// ---------- ZCode 桌面日志解析 ----------

function newestLogFile() {
  try {
    const files = fs.readdirSync(LOG_DIR)
      .filter((f) => /^\d{4}-\d{2}-\d{2}\.log$/.test(f))
      .sort();
    if (!files.length) return null;
    return path.join(LOG_DIR, files[files.length - 1]);
  } catch { return null; }
}

let logOffset = 0;
let currentFile = null;

/** 读取新增日志行,返回最新一次 memory 统计 */
function readDesktopCounters() {
  const file = newestLogFile();
  if (!file) return null;
  if (file !== currentFile) { currentFile = file; logOffset = 0; }

  let stat;
  try { stat = fs.statSync(file); } catch { return null; }
  if (stat.size <= logOffset) return null;

  const fd = fs.openSync(file, "r");
  const length = stat.size - logOffset;
  const buffer = Buffer.alloc(Math.min(length, 512 * 1024));
  fs.readSync(fd, buffer, 0, buffer.length, stat.size - buffer.length);
  fs.closeSync(fd);
  logOffset = stat.size;

  const text = buffer.toString("utf8");
  const re = /agent\.pendingPermissions=(\d+) agent\.pendingUserInputs=(\d+).*?bots\.runningTasks=(\d+)/g;
  let last = null;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    last = {
      pendingPermissions: Number(m[1]),
      pendingUserInputs: Number(m[2]),
      runningTasks: Number(m[3]),
    };
  }
  return last;
}

// ---------- 主循环 ----------

let lastPushedSignature = "";
let endedActivityToken = "";

async function tick() {
  try {
    const res = await fetch(`${RELAY_URL}/pending`, { headers: { "x-secret": SECRET } });
    if (!res.ok) return;
    const record = await res.json();
    const { push_token: pushToken, state } = record;
    if (!pushToken || !state) return;

    const counters = readDesktopCounters() ?? global.lastCounters ?? { pendingPermissions: 0, pendingUserInputs: 0, runningTasks: 0 };
    global.lastCounters = counters;

    const contentState = JSON.parse(state);

    // 合并桌面端真实状态
    let phase = contentState.phase;
    let approvalCount = contentState.approvalCount ?? 0;
    if (typeof counters === "object") {
      approvalCount = counters.pendingPermissions + counters.pendingUserInputs;
      if (counters.pendingPermissions > 0) phase = "awaitingApproval";
      else if (counters.pendingUserInputs > 0) phase = "awaitingInput";
      else if (counters.runningTasks > 0) phase = "running";
      else if (phase === "running" || phase === "awaitingApproval" || phase === "awaitingInput") phase = "idle";
    }
    contentState.phase = phase;
    contentState.approvalCount = approvalCount;

    const signature = JSON.stringify([pushToken, phase, approvalCount, contentState.lastToolName]);
    if (signature === lastPushedSignature) return;
    lastPushedSignature = signature;

    const now = Math.floor(Date.now() / 1000);
    const isTerminal = phase === "failed";
    const payload = isTerminal
      ? {
          aps: {
            timestamp: now,
            event: "end",
            "content-state": contentState,
            "dismissal-date": now + 30,
          },
        }
      : {
          aps: {
            timestamp: now,
            event: "update",
            "content-state": contentState,
            "stale-date": now + 15 * 60,
          },
        };

    if (isTerminal && endedActivityToken === pushToken) return;
    const result = await sendAPNs(pushToken, payload);
    if (isTerminal) endedActivityToken = pushToken;
    console.log(`[gateway] push ${phase} approvals=${approvalCount} →`, result.ok ? "ok" : `${result.status} ${result.body}`);
  } catch (e) {
    console.error("[gateway] tick error:", e?.message || e);
  }
}

console.log(`[gateway] relay=${RELAY_URL} apns=${APNS_HOST} bundle=${BUNDLE_ID}`);
setInterval(tick, POLL_MS);
tick();
