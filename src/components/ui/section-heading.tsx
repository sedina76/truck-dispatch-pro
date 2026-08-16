export function SectionHeading({ title, description }: { title: string; description: string }) {
  return (
    <div className="border-t border-border pt-6 first:border-0 first:pt-0 sm:col-span-2">
      <h2 className="text-sm font-semibold">{title}</h2>
      <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
    </div>
  );
}
