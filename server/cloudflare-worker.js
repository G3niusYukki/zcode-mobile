/**
 * ZCode Mobile · Live Activity 状态中转(Cloudflare Worker + KV)
 *
 * 用途:手机 App 上报活动的 APNs push token 与完整状态;Mac 网关拉取后
 * 结合 ZCode 桌面日志里的审批/运行状态,直推 APNs 实现锁屏真后台更新。
 *
 * 部署:
 *   1) wrangler kv namespace create LA_STATE   → 记下 id
 *   2) wrangler.toml 里绑定 KV(变量名 STATE)
 *   3) wrangler deploy
 *
 * 环境变量(可选):SYNC_SECRET 作为默认密钥;也可完全由 App 上报的 secret 决定。
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "content-type, x-secret",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });

    if (url.pathname === "/sync" && request.method === "POST") {
      let body;
      try { body = await request.json(); } catch { return json({ error: "bad json" }, 400, cors); }
      const { secret, push_token, state } = body || {};
      if (!secret || !push_token) return json({ error: "missing secret/push_token" }, 400, cors);
      if (env.SYNC_SECRET && secret !== env.SYNC_SECRET) return json({ error: "forbidden" }, 403, cors);
      await env.STATE.put("device", JSON.stringify({
        secret, push_token, state, updatedAt: Date.now(),
      }));
      return json({ ok: true }, 200, cors);
    }

    if (url.pathname === "/pending" && request.method === "GET") {
      const secret = request.headers.get("x-secret");
      const raw = await env.STATE.get("device");
      if (!raw) return json({ error: "empty" }, 404, cors);
      const record = JSON.parse(raw);
      if (!secret || secret !== record.secret) return json({ error: "forbidden" }, 403, cors);
      return json(record, 200, cors);
    }

    return json({ error: "not found" }, 404, cors);
  },
};

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", ...cors },
  });
}
