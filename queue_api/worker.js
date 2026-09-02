// Fila de jobs de RPA (encerramento de MDF-e) — Cloudflare Worker + KV.
//
// Endpoints:
//   GET  /health                      -> {ok:true}
//   POST /jobs        (CLIENT_TOKEN)  -> cria job {empresa, mdfe, mode?, force?}
//   GET  /jobs/:id    (qualquer token)-> status/resultado do job
//   GET  /next        (WORKER_TOKEN)  -> worker reivindica o proximo pendente (204 se vazio)
//   POST /jobs/:id/result (WORKER_TOKEN) -> worker devolve {status, result, detail}
//
// Bindings necessarios (no painel do Worker):
//   - KV namespace  -> variavel  JOBS
//   - Secret        -> CLIENT_TOKEN  (quem cria jobs)
//   - Secret        -> WORKER_TOKEN  (o robo na sessao)
//
// mode: "validate" (padrao, so cancela) ou "execute" (encerramento real).
// Idempotencia: mesmo empresa|mdfe|mode nao cria job novo se ja existe e nao falhou
// (evita encerrar o mesmo MDF-e 2x). Use force:true pra reprocessar.

// cria job na fila (usado por /jobs e /cancelarmdfe). forceMode ignora o mode do body.
async function createJob(env, b, forceMode) {
  const empresa = String(b.empresa ?? "").trim();
  const mdfe = String(b.mdfe ?? "").trim();
  const mode = forceMode ? forceMode : (b.mode === "execute" ? "execute" : "validate");
  if (!empresa || !mdfe) return { status: 400, body: { error: "empresa e mdfe sao obrigatorios" } };
  if (!/^\d+$/.test(empresa) || !/^\d+$/.test(mdfe)) return { status: 400, body: { error: "empresa e mdfe devem ser numericos" } };

  const dedupe = `${empresa}|${mdfe}|${mode}`;
  if (!b.force) {
    const existingId = await env.JOBS.get(`idx:${dedupe}`);
    if (existingId) {
      const ex = await env.JOBS.get(`job:${existingId}`, "json");
      if (ex && ex.status !== "error") return { status: 200, body: { id: existingId, status: ex.status, dedupe: true } };
    }
  }
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const job = { id, empresa, mdfe, mode, status: "pending", result: null, detail: null, createdAt: now, updatedAt: now };
  await env.JOBS.put(`job:${id}`, JSON.stringify(job));
  await env.JOBS.put(`pending:${now}-${id}`, id);
  await env.JOBS.put(`idx:${dedupe}`, id);
  return { status: 200, body: { id, status: "pending" } };
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const J = (obj, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

    try {
      if (req.method === "GET" && path === "/health") return J({ ok: true });

      // ---- criar job (cliente) ----
      if (req.method === "POST" && path === "/jobs") {
        if (auth !== env.CLIENT_TOKEN) return J({ error: "unauthorized" }, 401);
        const b = await req.json().catch(() => ({}));
        const r = await createJob(env, b);
        return J(r.body, r.status);
      }

      // ---- alias amigavel: encerrar MDF-e ----
      // Sem "mode" no body -> validacao (ensaio, clica Nao). mode:"execute" -> encerramento
      // real (worker v1 ainda bloqueia ate a guarda de identidade + autorizacao).
      if (req.method === "POST" && path === "/encerrarmdfe") {
        if (auth !== env.CLIENT_TOKEN) return J({ error: "unauthorized" }, 401);
        const b = await req.json().catch(() => ({}));
        const r = await createJob(env, b);
        return J(r.body, r.status);
      }

      // ---- worker reivindica o proximo ----
      if (req.method === "GET" && path === "/next") {
        if (auth !== env.WORKER_TOKEN) return J({ error: "unauthorized" }, 401);
        const list = await env.JOBS.list({ prefix: "pending:", limit: 1 });
        if (!list.keys.length) return new Response("", { status: 204 });
        const key = list.keys[0].name;
        const id = await env.JOBS.get(key);
        await env.JOBS.delete(key); // sai da fila (reivindicado)
        if (!id) return new Response("", { status: 204 });
        const job = await env.JOBS.get(`job:${id}`, "json");
        if (!job) return new Response("", { status: 204 });
        job.status = "running";
        job.updatedAt = new Date().toISOString();
        await env.JOBS.put(`job:${id}`, JSON.stringify(job));
        return J(job);
      }

      // ---- worker devolve resultado ----
      const mRes = path.match(/^\/jobs\/([^/]+)\/result$/);
      if (req.method === "POST" && mRes) {
        if (auth !== env.WORKER_TOKEN) return J({ error: "unauthorized" }, 401);
        const job = await env.JOBS.get(`job:${mRes[1]}`, "json");
        if (!job) return J({ error: "not found" }, 404);
        const b = await req.json().catch(() => ({}));
        job.status = b.status === "error" ? "error" : "done";
        job.result = b.result ?? null;
        job.detail = b.detail ?? null;
        job.updatedAt = new Date().toISOString();
        await env.JOBS.put(`job:${job.id}`, JSON.stringify(job));
        return J({ ok: true });
      }

      // ---- consultar status (cliente) ----
      const mGet = path.match(/^\/jobs\/([^/]+)$/);
      if (req.method === "GET" && mGet) {
        if (auth !== env.CLIENT_TOKEN && auth !== env.WORKER_TOKEN) return J({ error: "unauthorized" }, 401);
        const job = await env.JOBS.get(`job:${mGet[1]}`, "json");
        return job ? J(job) : J({ error: "not found" }, 404);
      }

      return J({ error: "not found" }, 404);
    } catch (e) {
      return J({ error: String(e && e.message ? e.message : e) }, 500);
    }
  },
};
