#!/usr/bin/env node
// Runs automatically as `predev`/`prestart`. Fails fast if the target port
// is already occupied, instead of letting `next dev`/`next start` either
// silently hop to the next free port or fail with an EADDRINUSE that's
// easy to miss when the process was launched in the background.
//
// This exists because of a real incident: an old `next-server` stayed
// bound to :3000 across a rebuild, a later `npm start` failed silently in
// the background with EADDRINUSE, and the stale process kept serving HTML
// that referenced JS chunk hashes the new build had already deleted from
// disk -- which surfaced in the browser as "Application error: a
// client-side exception has occurred" on /loads/[id], with no code defect
// anywhere. See also verify-server.js, which catches that exact symptom.
const { execSync } = require("node:child_process");

const PORT = process.env.PORT || 3000;

function findPortOwners(port) {
  try {
    // -sTCP:LISTEN only -- a plain lsof -ti:PORT also matches other
    // processes' established client connections that happen to be using
    // this port number as their own local ephemeral port, which isn't a
    // real conflict for binding a new listener.
    return execSync(`lsof -ti:${port} -sTCP:LISTEN`, { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim()
      .split("\n")
      .filter(Boolean);
  } catch {
    return []; // lsof exits non-zero when nothing is listening -- port is free.
  }
}

const pids = findPortOwners(PORT);
if (pids.length === 0) {
  process.exit(0);
}

console.error(`\n✖ Port ${PORT} is already in use -- refusing to start a second server.\n`);
for (const pid of pids) {
  let info = "(could not inspect process)";
  try {
    info = execSync(`ps -p ${pid} -o pid=,lstart=,command=`).toString().trim();
  } catch {
    // process may have exited between lsof and ps; ignore.
  }
  console.error(`  PID ${pid}: ${info}`);
}
console.error(`
This is the same failure mode that previously made /loads/[id] throw
"Application error: a client-side exception has occurred": a leftover
server process kept answering on this port after a rebuild, serving HTML
that referenced chunk files the new build had already removed from disk.

Next steps:
  - If this is a stale process from an earlier run, inspect it above, then:
      npm run kill-stale -- --yes
    and re-run this command.
  - If this is a server you're intentionally running, stop it yourself, or
    run this one on another port: PORT=3001 npm run dev
`);
process.exit(1);
