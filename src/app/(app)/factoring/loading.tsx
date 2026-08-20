export default function FactoringWorkspaceLoading() {
  return (
    <div className="space-y-3">
      <div className="space-y-1">
        <div className="h-4 w-24 animate-pulse rounded-sm bg-muted" />
        <div className="h-3 w-72 animate-pulse rounded-sm bg-muted" />
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7">
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} className="h-16 animate-pulse rounded-md border border-desktop-border bg-desktop-panel" />
        ))}
      </div>
      <div className="h-8 animate-pulse rounded-sm bg-muted" />
      <div className="h-64 animate-pulse rounded-md border border-border bg-card" />
    </div>
  );
}
