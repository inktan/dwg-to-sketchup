// Web frontend. Serves www and forwards /api to the CAD computer.
// ZWCAD, SketchUp, and Rhino stay on the backend machine. This machine does not run them.
//
//   node server.js --upstream http://10.1.12.30:8780
//   node server.js --port 80 --upstream http://10.1.12.30:8780

"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const WWW = path.join(__dirname, "www");
const TIMEOUT_MS = 15 * 60 * 1000;
const UPSTREAM_DOWN = Buffer.from('{"ok":false,"error":"建模电脑没有连上"}', "utf8");

const STATIC = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/index.html": ["index.html", "text/html; charset=utf-8"],
  "/app.css": ["app.css", "text/css; charset=utf-8"],
  "/app.js": ["app.js", "text/javascript; charset=utf-8"]
};

function parseArgs(argv) {
  let port = 8780;
  let upstream = "http://10.1.12.30:8780";
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--port") {
      port = Number(argv[++i]);
    } else if (arg === "--upstream") {
      upstream = argv[++i];
    } else {
      throw new Error("未知参数: " + arg);
    }
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("端口无效: " + port);
  }
  const base = String(upstream || "").trim().replace(/\/+$/, "");
  let url;
  try {
    url = new URL(base);
  } catch (err) {
    throw new Error("上游地址无效: " + upstream);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("上游只支持 http 或 https: " + upstream);
  }
  return { port, upstream: base };
}

function sendBytes(res, status, body, contentType) {
  if (res.headersSent || res.writableEnded || res.destroyed) return;
  res.writeHead(status, {
    "Content-Type": contentType,
    "Content-Length": body.length
  });
  res.end(body);
}

function sendStatic(res, relative, contentType) {
  fs.readFile(path.join(WWW, relative), (err, body) => {
    if (err) {
      sendBytes(res, 404, Buffer.from("not found", "utf8"), "text/plain; charset=utf-8");
      return;
    }
    sendBytes(res, 200, body, contentType);
  });
}

function sendUpstreamDown(res) {
  sendBytes(res, 502, UPSTREAM_DOWN, "application/json; charset=utf-8");
}

function proxy(req, res, upstream) {
  const target = new URL(upstream + req.url);
  const lib = target.protocol === "https:" ? https : http;
  const headers = {};
  if (req.headers["content-type"]) headers["Content-Type"] = req.headers["content-type"];
  if (req.headers["content-length"]) headers["Content-Length"] = req.headers["content-length"];

  const upstreamReq = lib.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port || (target.protocol === "https:" ? 443 : 80),
      method: req.method,
      path: target.pathname + target.search,
      headers,
      timeout: TIMEOUT_MS
    },
    (upstreamRes) => {
      const out = {};
      if (upstreamRes.headers["content-type"]) {
        out["Content-Type"] = upstreamRes.headers["content-type"];
      }
      for (const name of ["content-disposition", "cache-control", "x-accel-buffering"]) {
        const value = upstreamRes.headers[name];
        if (value) out[name] = value;
      }
      if (upstreamRes.headers["content-length"] !== undefined) {
        out["Content-Length"] = upstreamRes.headers["content-length"];
      }
      res.writeHead(upstreamRes.statusCode || 502, out);
      if (res.socket) res.socket.setNoDelay(true);
      upstreamRes.on("error", () => res.destroy());
      upstreamRes.pipe(res);
    }
  );

  const fail = () => {
    if (res.headersSent) res.destroy();
    else sendUpstreamDown(res);
  };
  upstreamReq.on("timeout", () => upstreamReq.destroy(new Error("upstream timeout")));
  upstreamReq.on("error", fail);
  req.on("aborted", () => upstreamReq.destroy());
  req.on("error", () => upstreamReq.destroy());
  res.on("error", () => upstreamReq.destroy());
  if (res.socket) res.socket.setNoDelay(true);
  req.pipe(upstreamReq);
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv);
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const server = http.createServer((req, res) => {
    const pathOnly = (req.url || "/").split("?")[0];
    if (pathOnly.startsWith("/api/")) {
      proxy(req, res, options.upstream);
      return;
    }
    const file = STATIC[pathOnly];
    if (!file) {
      sendBytes(res, 404, Buffer.from("not found", "utf8"), "text/plain; charset=utf-8");
      return;
    }
    sendStatic(res, file[0], file[1]);
  });

  server.requestTimeout = 0;
  server.headersTimeout = 0;
  server.keepAliveTimeout = TIMEOUT_MS;
  server.on("clientError", (_err, socket) => {
    if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
  });
  server.on("error", (err) => {
    if (err.code === "EADDRINUSE") console.error("端口 " + options.port + " 已被占用。");
    else if (err.code === "EACCES") console.error("没有权限监听端口 " + options.port + "。");
    else console.error(err.message);
    process.exit(1);
  });
  server.listen(options.port, "0.0.0.0", () => {
    console.log("网页 http://0.0.0.0:" + options.port + "/  接口转发到 " + options.upstream);
  });
}

main();
