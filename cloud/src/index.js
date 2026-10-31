// 价值账本 云同步服务（Cloudflare Worker + D1）
// 每条流水 / 物品 / 账户 / 设置是一条记录，服务器给每次写入分配递增的 rev。
// 设备拉取 rev 大于自己游标的记录，再推送本地改过的记录（删除也是一条 deleted=1 的记录）。

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (!authorized(req, env)) return json({ error: "unauthorized" }, 401);
    try {
      if (req.method === "GET" && url.pathname === "/status") return status(env);
      if (req.method === "GET" && url.pathname === "/pull") return pull(env, url);
      if (req.method === "POST" && url.pathname === "/push") return push(env, await req.json());
      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e?.message ?? e) }, 500);
    }
  },
};

function authorized(req, env) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!env.SYNC_TOKEN || token.length !== env.SYNC_TOKEN.length) return false;
  let diff = 0;
  for (let i = 0; i < token.length; i++) diff |= token.charCodeAt(i) ^ env.SYNC_TOKEN.charCodeAt(i);
  return diff === 0;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

async function maxRev(env) {
  return (await env.DB.prepare("SELECT IFNULL(MAX(rev), 0) AS r FROM records").first("r")) ?? 0;
}

async function status(env) {
  const row = await env.DB.prepare(
    "SELECT IFNULL(MAX(rev), 0) AS rev, SUM(deleted = 0) AS live, COUNT(*) AS total FROM records"
  ).first();
  return json({ rev: row.rev, live: row.live ?? 0, total: row.total });
}

async function pull(env, url) {
  const since = Number(url.searchParams.get("since") ?? 0) || 0;
  const limit = Math.min(Number(url.searchParams.get("limit") ?? 1000) || 1000, 2000);
  const { results } = await env.DB.prepare(
    "SELECT key, kind, data, deleted, rev FROM records WHERE rev > ?1 ORDER BY rev LIMIT ?2"
  ).bind(since, limit + 1).all();
  const more = results.length > limit;
  const records = more ? results.slice(0, limit) : results;
  const cursor = records.length ? records[records.length - 1].rev : since;
  return json({ records, cursor, more });
}

// 一次推送用一条 SQL 写完（json_each 展开），整批原子，rev 连续递增
async function push(env, body) {
  const records = Array.isArray(body?.records) ? body.records : [];
  if (records.length) {
    const rows = records.map((r) => ({
      key: String(r.key),
      kind: String(r.kind ?? ""),
      data: r.deleted ? "" : String(r.data ?? ""),
      deleted: r.deleted ? 1 : 0,
    }));
    await env.DB.prepare(
      `INSERT INTO records (key, kind, data, deleted, rev)
       SELECT json_extract(j.value, '$.key'), json_extract(j.value, '$.kind'), json_extract(j.value, '$.data'),
              json_extract(j.value, '$.deleted'), base.r + j.key + 1
       FROM json_each(?1) AS j, (SELECT IFNULL(MAX(rev), 0) AS r FROM records) AS base
       WHERE true
       ON CONFLICT(key) DO UPDATE SET kind = excluded.kind, data = excluded.data,
                                      deleted = excluded.deleted, rev = excluded.rev`
    ).bind(JSON.stringify(rows)).run();
  }
  return json({ cursor: await maxRev(env), count: records.length });
}
