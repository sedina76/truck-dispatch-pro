// Shown the instant a menu item or link is clicked, while the next page's
// data loads (the menus and sidebar stay in place). Without it the old page
// sat frozen until the new one was ready, which felt slow even when it wasn't.
export default function Loading() {
  return (
    <div className="space-y-3" aria-busy="true" aria-live="polite" data-testid="page-loading">
      <span className="sr-only">Loading…</span>
      <div className="h-5 w-48 animate-pulse rounded-sm bg-desktop-muted" />
      <div className="h-3 w-80 max-w-full animate-pulse rounded-sm bg-desktop-muted/70" />
      <div className="grid grid-cols-2 gap-2 pt-1 sm:grid-cols-4">
        {[0, 1, 2, 3].map((i) => (
          <div key={i} className="h-16 animate-pulse rounded-md border border-desktop-border bg-desktop-panel" />
        ))}
      </div>
      <div className="space-y-px overflow-hidden rounded-md border border-desktop-border">
        {Array.from({ length: 8 }, (_, i) => (
          <div key={i} className="h-9 animate-pulse bg-desktop-panel" style={{ opacity: 1 - i * 0.08 }} />
        ))}
      </div>
    </div>
  );
}
