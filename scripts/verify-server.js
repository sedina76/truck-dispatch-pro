#!/usr/bin/env node
// `npm run verify` -- run this after `npm start`/`npm run dev` reports
// ready, in a separate terminal.
//
// Confirms two things:
//   1. Which PID is actually bound to the port right now.
//   2. That a real page's served HTML only references JS chunk files that
//      genuinely exist in the current .next build on disk.
//
// (2) is the direct catch for the incident that made /loads/[id] throw
// "Application error: a client-side exception has occurred" with no code
// defect anywhere: a leftover server process served HTML pointing at chunk
// hashes a newer build had already deleted. This script reproduces that
// exact check so it's caught here instead of looking like a new app bug.
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");

const PORT = process.env.PORT || 3000;
const HOST = "localhost";
// Any lightweight, unauthenticated page works -- override with
// `npm run verify -- /some/other/path` if /login isn't reachable.
const CHECK_PATH = process.argv[2] || "/login";

function sh(cmd) {
  return execSync(cmd, { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
}

let pids = [];
try {
  pids = sh(`lsof -ti:${PORT} -sTCP:LISTEN`).split("\n").filter(Boolean);
} catch {
  pids = [];
}

if (pids.length === 0) {
  console.error(`✖ Nothing is listening on port ${PORT}. Is the server actually running?`);
  process.exit(1);
}

console.log(`Server on port ${PORT}:`);
for (const pid of pids) {
  let info = "(unknown)";
  try {
    info = sh(`ps -p ${pid} -o pid=,lstart=,command=`);
  } catch {
    // ignore
  }
  console.log(`  PID ${pid}: ${info}`);
}

const buildIdPath = path.join(process.cwd(), ".next", "BUILD_ID");
const buildId = fs.existsSync(buildIdPath) ? fs.readFileSync(buildIdPath, "utf8").trim() : null;
console.log(`On-disk .next/BUILD_ID: ${buildId ?? "(not found -- did you run `next build`? dev mode has no BUILD_ID, that's fine)"}`);

const req = http.get({ host: HOST, port: PORT, path: CHECK_PATH, timeout: 10_000 }, (res) => {
  let body = "";
  res.on("data", (c) => (body += c));
  res.on("end", () => {
    const chunkPaths = [...body.matchAll(/\/_next\/static\/chunks\/[^"'\s\\]+\.js/g)].map((m) => m[0]);
    const unique = [...new Set(chunkPaths)];

    if (unique.length === 0) {
      console.warn(`⚠ Found no /_next/static/chunks/*.js references in ${CHECK_PATH} -- can't verify from this page. Try: npm run verify -- /some/other/path`);
      process.exit(0);
    }

    const missing = unique.filter((p) => {
      const relative = decodeURIComponent(p.replace("/_next/static/", ""));
      const onDisk = path.join(process.cwd(), ".next", "static", relative);
      return !fs.existsSync(onDisk);
    });

    if (missing.length > 0) {
      console.error(`\n✖ CHUNK MISMATCH DETECTED -- this is the exact condition that produces`);
      console.error(`  "Application error: a client-side exception has occurred" in a real browser.`);
      console.error(`  The server just served HTML referencing JS chunk(s) that don't exist in`);
      console.error(`  the current .next build on disk:`);
      for (const m of missing) console.error(`    ${m}`);
      console.error(`\n  PID(s) ${pids.join(", ")} on port ${PORT} are almost certainly stale (serving an`);
      console.error(`  old build). Fix:`);
      console.error(`    npm run kill-stale -- --yes && npm start\n`);
      process.exit(1);
    }

    console.log(`✓ All ${unique.length} referenced chunk(s) exist in the current build. Server and build are consistent.`);
    process.exit(0);
  });
});

req.on("timeout", () => {
  req.destroy();
  console.error(`✖ Request to http://${HOST}:${PORT}${CHECK_PATH} timed out.`);
  process.exit(1);
});
req.on("error", (err) => {
  console.error(`✖ Could not reach http://${HOST}:${PORT}${CHECK_PATH}: ${err.message}`);
  process.exit(1);
});
