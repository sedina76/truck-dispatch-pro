// Shared Driver Portal field style for phone/tablet screens: 16px text so
// iPhone Safari doesn't zoom in when a field is tapped, and 48px height for
// a comfortable thumb target.
export const driverInputClass =
  "h-12 w-full rounded-xl border border-border bg-card px-4 text-base text-foreground shadow-elevation-1 outline-none placeholder:text-muted-foreground/70 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/25 disabled:opacity-60";

export const driverPrimaryButtonClass =
  "flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary text-base font-semibold text-primary-foreground shadow-elevation-1 disabled:opacity-60";
