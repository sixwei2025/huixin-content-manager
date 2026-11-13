import http from "node:http";
import https from "node:https";
import fs from "node:fs";

const port = Number(process.env.PORT || 3002);
const envPath = process.env.WECHAT_ENV || "/root/wechat_publish_workbuddy_ai_team/wechat.env";
const configured = {};
try {
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*["']?([^"']*)["']?\s*$/);
    if (match) configured[match[1]] = match[2];
  }
} catch {}

const json = (res, status, value) => {
  const body = JSON.stringify(value);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(body);
};

const requestJSON = (url, method, body) => new Promise((resolve, reject) => {
  const parsed = new URL(url);
  const payload = body ? JSON.stringify(body) : "";
  const req = https.request({ hostname: parsed.hostname, path: `${parsed.pathname}${parsed.search}`, method, headers: { "content-type": "application/json", ...(body ? { "content-length": Buffer.byteLength(payload) } : {}) } }, response => {
    let text = "";
    response.setEncoding("utf8");
    response.on("data", chunk => { text += chunk; });
    response.on("end", () => {
      try { resolve(JSON.parse(text)); } catch { reject(new Error("微信官方接口返回了无法解析的内容")); }
    });
  });
  req.on("error", reject);
  if (payload) req.write(payload);
  req.end();
});

const tokenFor = async (appID, secret) => {
  const query = new URLSearchParams({ grant_type: "client_credential", appid: appID, secret });
  const result = await requestJSON(`https://api.weixin.qq.com/cgi-bin/token?${query}`, "GET");
  if (!result.access_token) throw new Error(result.errmsg || "公众号授权失败");
  return result.access_token;
};

const official = async (path, token, body = {}) => {
  const result = await requestJSON(`https://api.weixin.qq.com${path}?access_token=${encodeURIComponent(token)}`, "POST", body);
  if (result.errcode && result.errcode !== 0) throw new Error(result.errmsg || `微信接口错误 ${result.errcode}`);
  return result;
};

const summary = async token => {
  const day = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const [users, cumulate, articles, reads] = await Promise.all([
    official("/datacube/getusersummary", token, { begin_date: day, end_date: day }),
    official("/datacube/getusercumulate", token, { begin_date: day, end_date: day }),
    official("/datacube/getarticlesummary", token, { begin_date: day, end_date: day }),
    official("/datacube/getuserread", token, { begin_date: day, end_date: day })
  ]);
  const sum = (row, keys) => keys.reduce((total, key) => total + (Number(row?.[key]) || 0), 0);
  const userRows = users.list || [];
  return {
    followers: Number(cumulate.list?.at(-1)?.cumulate_user) || 0,
    newFollowers: userRows.reduce((total, row) => total + (Number(row.new_user) || 0) - (Number(row.cancel_user) || 0), 0),
    articleReads: (articles.list || []).reduce((total, row) => total + sum(row, ["int_page_read_count", "ori_page_read_count"]), 0),
    articleShares: (reads.list || []).reduce((total, row) => total + sum(row, ["share_count", "add_to_fav_count"]), 0)
  };
};

const drafts = async token => {
  const result = await official("/cgi-bin/draft/batchget", token, { offset: 0, count: 20, no_content: 0 });
  return (result.item || []).map(item => {
    const news = item.content?.news_item || [];
    return { id: item.media_id, title: news[0]?.title || "未命名草稿", updateTime: item.update_time || null, articleCount: news.length };
  });
};

const server = http.createServer(async (req, res) => {
  const path = new URL(req.url, "http://127.0.0.1").pathname;
  if (req.method === "GET" && (path === "/health" || path.endsWith("/health"))) return json(res, 200, { status: "ok" });
  if (req.method !== "POST" || !(path === "/wechat" || path.endsWith("/wechat"))) return json(res, 404, { error: "not_found" });
  let raw = "";
  req.on("data", chunk => { raw += chunk; if (raw.length > 20000) req.destroy(); });
  req.on("end", async () => {
    try {
      const input = JSON.parse(raw || "{}");
      const appID = String(input.appID || "");
      const secret = String(input.secret || "");
      const action = input.action === "drafts" ? "drafts" : "summary";
      if (!appID || !secret) return json(res, 400, { error: "missing_credentials" });
      const token = await tokenFor(appID, secret);
      return json(res, 200, { action, data: action === "drafts" ? await drafts(token) : await summary(token) });
    } catch (error) {
      return json(res, 502, { error: error instanceof Error ? error.message : "relay_failed" });
    }
  });
});

server.listen(port, "127.0.0.1", () => console.log(`wechat relay listening on 127.0.0.1:${port}`));
