import Link from "next/link";
import { Button } from "@/components/ui/button";
import { ConfirmDeleteForm } from "@/components/ui/confirm-delete-form";

// Static id, not React's useId: FormCard is a Server Component (hooks
// aren't available), and every page that renders it only ever mounts one.
const FORM_ID = "form-card";

export function FormCard({
  title,
  description,
  children,
  action,
  cancelHref,
  submitLabel = "Save",
  deleteAction,
}: {
  title: string;
  description: string;
  children: React.ReactNode;
  action: (formData: FormData) => void;
  cancelHref: string;
  submitLabel?: string;
  deleteAction?: () => Promise<void>;
}) {
  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{title}</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
      </div>

      <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
        <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
          {title}
        </div>
        <div className="space-y-4 p-4">
          {/* Fields live in their own <form>; the action bar below is a sibling,
              not a descendant, since the delete confirmation is also a <form>
              and HTML forbids nested forms. The Save button submits via the
              `form` attribute instead of DOM nesting. */}
          <form id={FORM_ID} action={action} className="space-y-4">
            {children}
          </form>

          <div className="flex items-center justify-between border-t border-desktop-border pt-3">
            <div>{deleteAction && <ConfirmDeleteForm action={deleteAction} />}</div>
            <div className="flex items-center gap-2">
              <Link
                href={cancelHref}
                className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted"
              >
                Cancel
              </Link>
              <Button type="submit" form={FORM_ID}>
                {submitLabel}
              </Button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
