#!/usr/bin/env node
const { createHmac, timingSafeEqual } = require("crypto");
const { spawn } = require("child_process");
const http = require("http");

const appRoot = process.env.APP_ROOT || "/opt/visiontemplate";
const deployScript = process.env.DEPLOY_SCRIPT || `${appRoot}/bin/deploy.sh`;
const branch = process.env.BRANCH || "main";
const port = Number(process.env.WEBHOOK_PORT || 9000);
const secret = process.env.GITHUB_WEBHOOK_SECRET;

if (!secret) {
  console.error("GITHUB_WEBHOOK_SECRET is required");
  process.exit(1);
}

let running = false;
let pendingSha = null;

function readBody(req, limitBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > limitBytes) {
        reject(new Error("body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function verifySignature(rawBody, signatureHeader) {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expected = Buffer.from(
    `sha256=${createHmac("sha256", secret).update(rawBody).digest("hex")}`,
  );
  const received = Buffer.from(signatureHeader);
  return (
    expected.length === received.length && timingSafeEqual(expected, received)
  );
}

function runDeploy(sha) {
  running = true;
  console.log(`[${new Date().toISOString()}] deploying ${sha}`);

  const child = spawn("bash", [deployScript, sha], {
    env: process.env,
    stdio: ["ignore", "inherit", "inherit"],
  });

  child.on("close", (code) => {
    console.log(`[${new Date().toISOString()}] deploy ${sha} exited ${code}`);
    running = false;

    if (pendingSha && pendingSha !== sha) {
      const nextSha = pendingSha;
      pendingSha = null;
      runDeploy(nextSha);
    } else {
      pendingSha = null;
    }
  });
}

function enqueueDeploy(sha) {
  if (running) {
    pendingSha = sha;
    return "queued";
  }

  runDeploy(sha);
  return "started";
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method !== "POST" || !["/_deploy/github", "/github"].includes(req.url)) {
      res.writeHead(404);
      res.end("not found\n");
      return;
    }

    const rawBody = await readBody(req);
    if (!verifySignature(rawBody, req.headers["x-hub-signature-256"])) {
      res.writeHead(401);
      res.end("bad signature\n");
      return;
    }

    const event = req.headers["x-github-event"];
    const payload = JSON.parse(rawBody);

    if (event === "ping") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (event !== "push") {
      res.writeHead(202, { "content-type": "application/json" });
      res.end(JSON.stringify({ ignored: true, reason: "not a push event" }));
      return;
    }

    if (payload.ref !== `refs/heads/${branch}`) {
      res.writeHead(202, { "content-type": "application/json" });
      res.end(JSON.stringify({ ignored: true, reason: "wrong branch" }));
      return;
    }

    if (!payload.after || /^0{40}$/.test(payload.after)) {
      res.writeHead(202, { "content-type": "application/json" });
      res.end(JSON.stringify({ ignored: true, reason: "deleted ref" }));
      return;
    }

    const state = enqueueDeploy(payload.after);
    res.writeHead(202, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, state, sha: payload.after }));
  } catch (error) {
    console.error(error);
    res.writeHead(500);
    res.end("webhook error\n");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`visiontemplate webhook listening on 127.0.0.1:${port}`);
});
