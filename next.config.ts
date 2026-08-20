import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Home directory has a stray root-level package-lock.json (unrelated repo
  // state), which makes Next.js misdetect the workspace root. Pin it here.
  // (process.cwd() rather than __dirname: this file is transpiled and
  // __dirname is not reliably defined in that context -- using it silently
  // corrupted output file tracing and broke every route under `next start`.)
  outputFileTracingRoot: process.cwd(),
  experimental: {
    serverActions: {
      // Server Actions called directly from client code (not a traditional
      // multipart form POST) are still subject to Next's own body-size
      // limit before user code ever runs -- default is 1MB, well under
      // this app's own document-upload limit (pod-actions.ts's MAX_BYTES,
      // 15MB). Found live: an oversized-file upload test showed Next's
      // generic redacted digest message ("The specific message is omitted
      // in production builds...") INSTEAD of uploadLoadDocument()'s own
      // "File is too large (15 MB max)." -- Next's platform-level limit
      // was rejecting the request before the action body even ran.
      // Raised to comfortably exceed MAX_BYTES (not just barely) so the
      // application's own, more specific validation is reliably what
      // fires, with headroom for request overhead beyond the raw file
      // bytes.
      bodySizeLimit: "20mb",
    },
  },
};

export default nextConfig;
