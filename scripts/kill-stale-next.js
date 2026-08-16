#!/usr/bin/env node
// `npm run kill-stale -- --yes`
//
// Kills ONLY the process actually bound to the target port, and only after
// confirming it really looks like a Next.js server -- never a blind
// `pkill -f next`, which has previously matched more than intended. Without
// --yes this just reports what it *would* kill and does nothing, since
// killing a process is hard to reverse.
const { execSync } = require("node:child_process");

const PORT = process.env.PORT || 3000;
const confirmed = process.argv.includes("--yes") || process.argv.includes("-y");

function sh(cmd) {
  return execSync(cmd, { stdio: ["ignore", "pipe", "pipe"] }).toString().trim();
}

let pids = [];
try {
  // -sTCP:LISTEN only -- plain `lsof -ti:PORT` also matches OTHER
  // processes' established client connections that happen to be using
  // this port number as their local ephemeral port (observed in practice:
  // a WebKit networking helper's outbound connection). Matching those
  // meant this script could hit a non-Next PID first and bail out via the
  // safety check below without ever reaching the real listener.
  pids = sh(`lsof -ti:${PORT} -sTCP:LISTEN`).split("\n").filter(Boolean);
} catch {
  pids = [];
}

if (pids.length === 0) {
  console.log(`Nothing is listening on port ${PORT}. Nothing to do.`);
  process.exit(0);
}

const targets = [];
for (const pid of pids) {
  let comm = "";
  let full = "";
  try {
    comm = sh(`ps -p ${pid} -o comm=`);
    full = sh(`ps -p ${pid} -o command=`);
  } catch {
    continue; // process disappeared between lsof and ps
  }
  const looksLikeNext = /next-server|next dev|next start|node_modules[\\/]\.bin[\\/]next|next[\\/]dist[\\/]bin[\\/]next/.test(
    `${comm} ${full}`
  );
  if (!looksLikeNext) {
    console.error(`✖ PID ${pid} is bound to port ${PORT} but doesn't look like a Next.js process:`);
    console.error(`  ${full || comm}`);
    console.error(`  Refusing to kill it -- investigate manually.`);
    process.exit(1);
  }
  targets.push({ pid, full });
}

console.log(`Found ${targets.length} Next.js process(es) on port ${PORT}:`);
for (const t of targets) console.log(`  PID ${t.pid}: ${t.full}`);

if (!confirmed) {
  console.log(`\nDry run -- nothing killed. Re-run with --yes to actually kill ${targets.length === 1 ? "it" : "them"}:`);
  console.log(`  npm run kill-stale -- --yes`);
  process.exit(0);
}

for (const t of targets) {
  console.log(`Killing PID ${t.pid} (SIGTERM)...`);
  try {
    execSync(`kill ${t.pid}`);
  } catch {
    // already gone
  }
}

execSync("sleep 1.5");

let remaining = [];
try {
  remaining = sh(`lsof -ti:${PORT} -sTCP:LISTEN`).split("\n").filter(Boolean);
} catch {
  remaining = [];
}
for (const pid of remaining) {
  console.log(`PID ${pid} still holding port ${PORT} -- sending SIGKILL...`);
  try {
    execSync(`kill -9 ${pid}`);
  } catch {
    // already gone
  }
}

execSync("sleep 0.5");
try {
  const stillThere = sh(`lsof -ti:${PORT} -sTCP:LISTEN`);
  if (stillThere) {
    console.error(`✖ Port ${PORT} is still occupied. Manual investigation needed.`);
    process.exit(1);
  }
} catch {
  // lsof throwing (non-zero exit) means nothing's listening -- good.
}
console.log(`✓ Port ${PORT} is free.`);
