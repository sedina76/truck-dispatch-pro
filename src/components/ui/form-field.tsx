import { Input } from "@/components/ui/input";

export function FormField({
  label,
  name,
  type = "text",
  defaultValue,
  required,
  placeholder,
  step,
  disabled,
}: {
  label: string;
  name: string;
  type?: string;
  defaultValue?: string | number | null;
  required?: boolean;
  placeholder?: string;
  step?: string;
  disabled?: boolean;
}) {
  return (
    // min-w-0: a grid item defaults to min-width:auto, which refuses to
    // shrink below an intrinsically-long value (a long website/email/legal
    // name) and can force the whole FormGrid wider than the viewport at
    // narrow widths -- min-w-0 lets it shrink to the column width instead,
    // since the Input itself is already w-full and clips/scrolls its own
    // overflow.
    <div className="min-w-0 space-y-1">
      <label htmlFor={name} className="text-[12px] font-medium text-desktop-text">
        {label}
        {required && <span className="text-danger"> *</span>}
      </label>
      <Input
        id={name}
        name={name}
        type={type}
        step={step}
        required={required}
        placeholder={placeholder}
        disabled={disabled}
        defaultValue={defaultValue ?? undefined}
      />
    </div>
  );
}

export function FormSelect({
  label,
  name,
  options,
  defaultValue,
  required,
  disabled,
}: {
  label: string;
  name: string;
  options: { value: string; label: string }[];
  defaultValue?: string | null;
  required?: boolean;
  disabled?: boolean;
}) {
  return (
    <div className="min-w-0 space-y-1">
      <label htmlFor={name} className="text-[12px] font-medium text-desktop-text">
        {label}
        {required && <span className="text-danger"> *</span>}
      </label>
      <select
        id={name}
        name={name}
        required={required}
        disabled={disabled}
        defaultValue={defaultValue ?? ""}
        className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-60"
      >
        <option value="" disabled>
          Select...
        </option>
        {options.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
    </div>
  );
}

export function FormTextarea({
  label,
  name,
  defaultValue,
  rows = 3,
  disabled,
}: {
  label: string;
  name: string;
  defaultValue?: string | null;
  rows?: number;
  disabled?: boolean;
}) {
  return (
    <div className="min-w-0 space-y-1 sm:col-span-2">
      <label htmlFor={name} className="text-[12px] font-medium text-desktop-text">
        {label}
      </label>
      <textarea
        id={name}
        name={name}
        rows={rows}
        defaultValue={defaultValue ?? undefined}
        disabled={disabled}
        className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-2 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
      />
    </div>
  );
}

export function FormGrid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">{children}</div>;
}
