import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Home directory has a stray root-level package-lock.json (unrelated repo
  // state), which makes Next.js misdetect the workspace root. Pin it here.
  // (process.cwd() rather than __dirname: this file is transpiled and
  // __dirname is not reliably defined in that context -- using it silently
  // corrupted output file tracing and broke every route under `next start`.)
  outputFileTracingRoot: process.cwd(),
};

export default nextConfig;
