#!/usr/bin/env bun
// screencast.ts — Single-file CDP Screencast Viewer
// Usage: bun screencast.ts [--port 3000]

const PORT = parseInt(
  Bun.argv.find((_, i, a) => a[i - 1] === "--port") ?? process.env.PORT ?? "3000",
);

// ── Container discovery ───────────────────────────────────────────────────────

async function getContainers() {
  try {
    const proc = Bun.spawn(["container", "ls", "--format", "json"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const text = await new Response(proc.stdout).text();
    const code = await proc.exited;
    if (code !== 0 || !text.trim()) return [];

    const raw = JSON.parse(text);
    const list: any[] = Array.isArray(raw) ? raw : [raw];

    return list
      .filter((c) => String(c.status ?? "").toLowerCase() === "running")
      .filter((c) => {
        const ref = c.configuration?.image?.reference;
        const img = typeof ref === "object" ? ref?.description ?? ref?.name ?? "" : String(ref ?? "");
        return img === "browser:latest";
      })
      .map((c) => {
        const cfg = c.configuration ?? {};
        const nets = c.networks ?? [];
        const addr = (nets[0]?.ipv4Address ?? "").replace(/\/\d+$/, "");
        const ports: any[] = cfg.publishedPorts ?? [];
        const cdp = ports.find((p: any) => p.containerPort === 9222);
        const rdp = ports.find((p: any) => p.containerPort === 3389);

        return {
          id: cfg.id ?? "",
          image: typeof cfg.image?.reference === "object"
            ? cfg.image.reference.description ?? cfg.image.reference.name ?? ""
            : String(cfg.image?.reference ?? ""),
          addr,
          cpus: cfg.resources?.cpus ?? 0,
          memoryMB: cfg.resources?.memoryInBytes
            ? Math.round(cfg.resources.memoryInBytes / 1048576)
            : 0,
          cdpHost: cdp ? "127.0.0.1" : addr,
          cdpPort: cdp?.hostPort ?? 9222,
          rdpPort: rdp?.hostPort ?? null,
        };
      });
  } catch {
    return [];
  }
}

// ── HTML application ──────────────────────────────────────────────────────────

const HTML = `<!DOCTYPE html>
<html lang="en" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Screencast</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🖥</text></svg>">
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: "class",
      theme: {
        extend: {
          fontFamily: {
            sans: ["-apple-system", "BlinkMacSystemFont", "Inter", "system-ui", "sans-serif"],
            mono: ["SF Mono", "Menlo", "Consolas", "monospace"],
          },
        },
      },
    };
  </script>
  <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
  <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
  <script crossorigin src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
  <style>
    @keyframes fade-in { from { opacity: 0; transform: scale(0.98); } to { opacity: 1; transform: scale(1); } }
    .fade-in { animation: fade-in 0.2s ease-out; }
    select { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' fill='%2371717a' viewBox='0 0 16 16'%3E%3Cpath d='M8 11L3 6h10z'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 8px center; }
  </style>
</head>
<body class="bg-zinc-950 text-zinc-200 h-screen flex flex-col overflow-hidden">
  <div id="root" class="flex flex-col h-full"></div>
  <script type="text/babel">
    const { useState, useEffect, useRef } = React;

    // ── Status dot ───────────────────────────────────────
    function Dot({ state }) {
      var cls = "w-2 h-2 rounded-full shrink-0 ";
      if (state === "streaming") cls += "bg-emerald-400 shadow-[0_0_6px_rgba(52,211,153,0.5)]";
      else if (state === "discovering" || state === "connecting") cls += "bg-amber-400 animate-pulse";
      else if (state === "error") cls += "bg-red-400";
      else cls += "bg-zinc-600";
      return <div className={cls} />;
    }

    // ── Spinner ──────────────────────────────────────────
    function Spinner() {
      return (
        <svg className="animate-spin h-5 w-5 text-zinc-500" fill="none" viewBox="0 0 24 24">
          <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
          <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
        </svg>
      );
    }

    // ── Empty / status states ────────────────────────────
    function Placeholder({ state, hasContainers, error }) {
      if (state === "streaming") return null;

      var icon = null;
      var title = "";
      var subtitle = "";

      if (state === "discovering") {
        icon = <Spinner />;
        title = "Discovering CDP targets";
      } else if (state === "connecting") {
        icon = <Spinner />;
        title = "Connecting";
      } else if (state === "error") {
        icon = (
          <svg className="w-8 h-8 text-red-400/80" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z" />
          </svg>
        );
        title = error || "Connection failed";
        subtitle = "Retrying...";
      } else if (state === "disconnected") {
        icon = <Spinner />;
        title = "Disconnected";
        subtitle = "Reconnecting...";
      } else if (!hasContainers) {
        icon = (
          <svg className="w-10 h-10 text-zinc-700" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1">
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25A2.25 2.25 0 015.25 3h13.5A2.25 2.25 0 0121 5.25z" />
          </svg>
        );
        title = "No containers running";
        subtitle = "Start a browser container to begin";
      } else {
        icon = (
          <svg className="w-8 h-8 text-zinc-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
            <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 6.75L12 3m0 0l3.75 3.75M12 3v18" />
          </svg>
        );
        title = "Select a container";
      }

      return (
        <div className="flex flex-col items-center gap-3 text-center fade-in">
          {icon}
          <p className="text-sm text-zinc-400 font-medium">{title}</p>
          {subtitle && <p className="text-xs text-zinc-600">{subtitle}</p>}
        </div>
      );
    }

    // ── Main application ─────────────────────────────────
    function App() {
      var [containers, setContainers] = useState([]);
      var [selectedId, setSelectedId] = useState(function () {
        return new URLSearchParams(location.search).get("c") || null;
      });
      var [connState, setConnState] = useState("idle");
      var [stats, setStats] = useState({ fps: 0, frames: 0, w: 0, h: 0 });
      var [error, setError] = useState(null);
      var imgRef = useRef(null);
      var wsRef = useRef(null);
      var containersRef = useRef(containers);
      containersRef.current = containers;

      // Fetch containers periodically
      useEffect(function () {
        var active = true;
        function tick() {
          fetch("/api/containers")
            .then(function (r) { return r.json(); })
            .then(function (d) { if (active) setContainers(Array.isArray(d) ? d : []); })
            .catch(function () {});
        }
        tick();
        var iv = setInterval(tick, 4000);
        return function () { active = false; clearInterval(iv); };
      }, []);

      // Deselect if container disappears
      useEffect(function () {
        if (selectedId && containers.length > 0 && !containers.find(function (c) { return c.id === selectedId; })) {
          setSelectedId(null);
        }
      }, [containers, selectedId]);

      // Sync selected container to URL
      useEffect(function () {
        var params = new URLSearchParams(location.search);
        if (selectedId) params.set("c", selectedId);
        else params.delete("c");
        var qs = params.toString();
        history.replaceState(null, "", qs ? "?" + qs : location.pathname);
      }, [selectedId]);

      // Connect to selected container
      useEffect(function () {
        if (!selectedId) {
          setConnState("idle");
          return;
        }

        var container = containersRef.current.find(function (c) { return c.id === selectedId; });
        if (!container) return;

        var cancelled = false;
        var currentWs = null;

        function connect() {
          if (cancelled) return;
          setError(null);
          setConnState("discovering");
          setStats({ fps: 0, frames: 0, w: 0, h: 0 });

          fetch("/api/cdp-targets?host=" + container.cdpHost + "&port=" + container.cdpPort)
            .then(function (r) { return r.json(); })
            .then(function (targets) {
              if (cancelled) return;

              var wsUrl = null;
              var mode = "page";

              if (Array.isArray(targets)) {
                var page = targets.find(function (t) { return t.type === "page"; });
                if (page && page.webSocketDebuggerUrl) {
                  var pathname = new URL(page.webSocketDebuggerUrl).pathname;
                  wsUrl = "ws://" + container.cdpHost + ":" + container.cdpPort + pathname;
                }
              }

              if (!wsUrl) {
                // Try browser-level
                return fetch("/api/cdp-targets?host=" + container.cdpHost + "&port=" + container.cdpPort + "&path=/json/version")
                  .then(function (r) { return r.json(); })
                  .then(function (info) {
                    if (cancelled) return;
                    if (info && info.webSocketDebuggerUrl) {
                      var pathname = new URL(info.webSocketDebuggerUrl).pathname;
                      wsUrl = "ws://" + container.cdpHost + ":" + container.cdpPort + pathname;
                      mode = "browser";
                    }
                    if (!wsUrl) throw new Error("No CDP endpoint found");
                    openWs(wsUrl, mode);
                  });
              }

              openWs(wsUrl, mode);
            })
            .catch(function (e) {
              if (cancelled) return;
              setConnState("error");
              setError(e.message || "Discovery failed");
              setTimeout(function () { if (!cancelled) connect(); }, 3000);
            });
        }

        function openWs(wsUrl, mode) {
          if (cancelled) return;
          setConnState("connecting");

          var proxyUrl = "ws://" + location.host + "/ws-proxy?target=" + encodeURIComponent(wsUrl);
          var ws = new WebSocket(proxyUrl);
          currentWs = ws;
          wsRef.current = ws;

          var msgId = 0;
          var targetSessId = null;
          var fpsState = { lastTime: 0, fps: 0, frames: 0 };

          function send(method, params, sessId) {
            var msg = { id: ++msgId, method: method, params: params || {} };
            if (sessId) msg.sessionId = sessId;
            ws.send(JSON.stringify(msg));
          }

          function onFrame(fp, sessId) {
            fpsState.frames++;
            var now = performance.now();
            if (fpsState.lastTime > 0) {
              fpsState.fps = fpsState.fps * 0.9 + (1000 / (now - fpsState.lastTime)) * 0.1;
            }
            fpsState.lastTime = now;

            if (imgRef.current) {
              imgRef.current.src = "data:image/jpeg;base64," + fp.data;
            }

            send("Page.screencastFrameAck", { sessionId: fp.sessionId }, sessId);

            setConnState("streaming");
            var m = fp.metadata || {};
            setStats({ fps: fpsState.fps, frames: fpsState.frames, w: m.deviceWidth || 0, h: m.deviceHeight || 0 });
          }

          ws.onopen = function () {
            if (cancelled) { ws.close(); return; }
            if (mode === "browser") {
              send("Target.getTargets");
            } else {
              send("Page.startScreencast", { format: "jpeg", quality: 80, everyNthFrame: 1 });
            }
          };

          ws.onmessage = function (e) {
            var msg = JSON.parse(e.data);

            if (msg.result && msg.result.targetInfos) {
              var page = msg.result.targetInfos.find(function (t) { return t.type === "page"; });
              if (page) send("Target.attachToTarget", { targetId: page.targetId, flatten: true });
            }

            if (msg.result && msg.result.sessionId) {
              targetSessId = msg.result.sessionId;
              send("Page.startScreencast", { format: "jpeg", quality: 80, everyNthFrame: 1 }, targetSessId);
            }

            if (msg.method === "Page.screencastFrame") {
              onFrame(msg.params, msg.sessionId || targetSessId);
            }
          };

          ws.onerror = function () {
            if (!cancelled) { setConnState("error"); setError("WebSocket error"); }
          };

          ws.onclose = function () {
            if (!cancelled) {
              setConnState("disconnected");
              setTimeout(function () { if (!cancelled) connect(); }, 2000);
            }
          };
        }

        connect();

        return function () {
          cancelled = true;
          if (currentWs) try { currentWs.close(); } catch (e) {}
          if (wsRef.current) try { wsRef.current.close(); } catch (e) {}
          wsRef.current = null;
        };
      }, [selectedId]);

      // ── Render ─────────────────────────────────────────

      var dotState = connState;
      var statusText = "";
      if (connState === "streaming") {
        statusText = stats.w + "\\u00d7" + stats.h + "  " + Math.round(stats.fps) + " fps  #" + stats.frames;
      }

      var selectedContainer = selectedId ? containers.find(function (c) { return c.id === selectedId; }) : null;

      return (
        <div className="flex flex-col h-full">
          {/* Header */}
          <header className="flex items-center gap-3 px-4 h-11 bg-zinc-900/80 border-b border-zinc-800/50 backdrop-blur-sm shrink-0 z-10">
            <div className="flex items-center gap-2.5">
              <Dot state={dotState} />
              <span className="text-[13px] font-semibold tracking-tight text-zinc-300">Screencast</span>
            </div>

            <select
              value={selectedId || ""}
              onChange={function (e) { setSelectedId(e.target.value || null); }}
              className="bg-zinc-800/60 border border-zinc-700/40 rounded-md px-2.5 py-1 pr-6 text-xs text-zinc-300 outline-none focus:border-zinc-500 focus:ring-1 focus:ring-zinc-500/30 transition-colors cursor-pointer min-w-[200px] appearance-none font-mono"
            >
              <option value="">Select container...</option>
              {containers.map(function (c) {
                var label = c.id.slice(0, 12) + " \\u00b7 " + (c.image || c.addr || "unknown");
                return <option key={c.id} value={c.id}>{label}</option>;
              })}
            </select>

            {containers.length > 0 && (
              <button
                onClick={function () {
                  fetch("/api/containers")
                    .then(function (r) { return r.json(); })
                    .then(function (d) { setContainers(Array.isArray(d) ? d : []); });
                }}
                className="text-zinc-600 hover:text-zinc-400 transition-colors"
                title="Refresh containers"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
              </button>
            )}

            {selectedContainer && selectedContainer.rdpPort && (
              <a
                href={"rdp://localhost:" + selectedContainer.rdpPort}
                className="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs text-zinc-400 hover:text-zinc-200 bg-zinc-800/60 border border-zinc-700/40 hover:border-zinc-600/60 transition-colors"
                title="Open in Remote Desktop"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25A2.25 2.25 0 015.25 3h13.5A2.25 2.25 0 0121 5.25z" />
                </svg>
                RDP
              </a>
            )}

            {statusText && (
              <div className="ml-auto text-[11px] text-zinc-500 font-mono tracking-wide">
                {statusText}
              </div>
            )}
          </header>

          {/* Screencast area */}
          <main className="flex-1 flex items-center justify-center overflow-hidden relative">
            <img
              ref={imgRef}
              className="max-w-full max-h-full object-contain"
              style={{ display: connState === "streaming" ? "block" : "none" }}
              alt="screencast"
            />

            {connState !== "streaming" && (
              <Placeholder state={connState} hasContainers={containers.length > 0} error={error} />
            )}
          </main>
        </div>
      );
    }

    ReactDOM.createRoot(document.getElementById("root")).render(<App />);
  </script>
</body>
</html>`;

// ── HTTP + WebSocket server ───────────────────────────────────────────────────

Bun.serve({
  port: PORT,

  async fetch(req, server) {
    const url = new URL(req.url);

    // ── WebSocket upgrade for CDP proxy ──
    if (url.pathname === "/ws-proxy") {
      const target = url.searchParams.get("target");
      if (!target) return new Response("Missing target param", { status: 400 });
      if (server.upgrade(req, { data: { target, upstream: null as WebSocket | null, ready: false, buffer: [] as string[] } })) {
        return undefined;
      }
      return new Response("WebSocket upgrade failed", { status: 500 });
    }

    // ── API: list containers ──
    if (url.pathname === "/api/containers") {
      return Response.json(await getContainers());
    }

    // ── API: proxy CDP HTTP (avoids CORS) ──
    if (url.pathname === "/api/cdp-targets") {
      const host = url.searchParams.get("host") || "127.0.0.1";
      const port = url.searchParams.get("port") || "9222";
      const path = url.searchParams.get("path") || "/json";
      try {
        const res = await fetch("http://" + host + ":" + port + path, {
          signal: AbortSignal.timeout(3000),
        });
        const body = await res.text();
        return new Response(body, {
          status: res.status,
          headers: { "Content-Type": "application/json" },
        });
      } catch (e: any) {
        return Response.json({ error: e?.message ?? "CDP fetch failed" }, { status: 502 });
      }
    }

    // ── Serve HTML ──
    return new Response(HTML, {
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  },

  websocket: {
    open(ws) {
      const d = ws.data as any;
      const upstream = new WebSocket(d.target);
      d.upstream = upstream;

      upstream.addEventListener("open", () => {
        d.ready = true;
        for (const msg of d.buffer) upstream.send(msg);
        d.buffer = [];
      });

      upstream.addEventListener("message", (e) => {
        try { ws.send(e.data as string); } catch {}
      });

      upstream.addEventListener("close", () => {
        try { ws.close(); } catch {}
      });

      upstream.addEventListener("error", () => {
        try { ws.close(); } catch {}
      });
    },

    message(ws, message) {
      const d = ws.data as any;
      if (d.ready && d.upstream?.readyState === WebSocket.OPEN) {
        d.upstream.send(message);
      } else {
        d.buffer.push(typeof message === "string" ? message : new TextDecoder().decode(message));
      }
    },

    close(ws) {
      const d = ws.data as any;
      try { d.upstream?.close(); } catch {}
    },
  },
});

console.log("Screencast \u2192 http://localhost:" + PORT);
