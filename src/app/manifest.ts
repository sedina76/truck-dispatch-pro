import type { MetadataRoute } from "next";

// App Router's native manifest convention -- Next.js auto-detects this
// file, serves it at /manifest.webmanifest, and injects
// <link rel="manifest"> into every page's <head> automatically, exactly
// like favicon.ico/icon.png/apple-icon.png (all in this same directory)
// are auto-wired with no explicit metadata.icons entry needed. Values
// below reuse the app's own already-established name/description
// (layout.tsx's own metadata.title) and brand color (globals.css's
// light-mode --primary) rather than introducing new ones.
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Truck Dispatch Pro",
    short_name: "Truck Dispatch",
    description: "Dispatch operations, billing, and compliance for freight dispatch companies.",
    start_url: "/",
    display: "standalone",
    background_color: "#ffffff",
    theme_color: "#1c54b8",
    icons: [
      { src: "/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
  };
}
