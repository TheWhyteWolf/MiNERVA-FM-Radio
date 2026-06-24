// MiNERVA-FM metadata bridge — zero-dependency Node (>=18).
// - GET  /events : Server-Sent Events feed of the current now-playing JSON (for listeners)
// - POST /update : the radio host pushes a new track here (Bearer-token protected)
// Also polls Icecast's status-json for the live listener count.
//
// Env: BRIDGE_PORT (8088), BRIDGE_TOKEN, ICECAST_STATUS, ICECAST_MOUNT
import http from "node:http";

const PORT  = Number(process.env.BRIDGE_PORT || 8088);
const TOKEN = process.env.BRIDGE_TOKEN || "change-me";
const ICECAST_STATUS = process.env.ICECAST_STATUS || "http://127.0.0.1:8000/status-json.xsl";
const MOUNT = process.env.ICECAST_MOUNT || "/stream";

let current = {
  source: "ON AIR", id: "—", platform: "",
  game: "", track: "", scheme: "minerva", char: "#", listeners: 0,
};
const clients = new Set();

function broadcast() {
  const payload = `data: ${JSON.stringify(current)}\n\n`;
  for (const res of clients) { try { res.write(payload); } catch {} }
}

async function pollListeners() {
  try {
    const r = await fetch(ICECAST_STATUS);
    const j = await r.json();
    let src = j?.icestats?.source;
    if (Array.isArray(src)) src = src.find(s => (s.listenurl || "").endsWith(MOUNT)) || src[0];
    const n = src ? Number(src.listeners) : 0;
    if (!Number.isNaN(n) && n !== current.listeners) { current.listeners = n; broadcast(); }
  } catch { /* Icecast not up yet — ignore */ }
}
setInterval(pollListeners, 5000);

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");

  if (req.method === "GET" && url.pathname === "/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
      "Access-Control-Allow-Origin": "*",
    });
    res.write("retry: 3000\n\n");
    res.write(`data: ${JSON.stringify(current)}\n\n`);
    clients.add(res);
    const ka = setInterval(() => { try { res.write(": ping\n\n"); } catch {} }, 25000);
    req.on("close", () => { clearInterval(ka); clients.delete(res); });
    return;
  }

  if (req.method === "POST" && url.pathname === "/update") {
    if (req.headers.authorization !== `Bearer ${TOKEN}`) { res.writeHead(401).end("unauthorized"); return; }
    let body = "";
    req.on("data", c => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on("end", () => {
      try {
        const m = JSON.parse(body);
        current = { ...current, ...m, source: "ON AIR" };
        broadcast();
        res.writeHead(204).end();
      } catch { res.writeHead(400).end("bad json"); }
    });
    return;
  }

  res.writeHead(404).end("not found");
});
server.listen(PORT, () => console.log(`metadata bridge: SSE /events, POST /update on :${PORT}`));
