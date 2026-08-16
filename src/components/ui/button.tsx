import { type ButtonHTMLAttributes, forwardRef } from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-sm border border-transparent font-medium transition-colors active:translate-y-px disabled:opacity-50 disabled:pointer-events-none focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/30",
  {
    variants: {
      variant: {
        primary: "bg-primary text-primary-foreground shadow-elevation-1 hover:bg-primary-hover",
        secondary: "bg-secondary text-secondary-foreground shadow-elevation-1 hover:opacity-90",
        success: "bg-success text-success-foreground shadow-elevation-1 hover:opacity-90",
        outline: "border-desktop-border bg-card text-foreground hover:bg-muted",
        ghost: "border-desktop-border text-foreground hover:bg-muted",
        subtle: "bg-muted text-foreground hover:opacity-80",
        danger:
          "border-danger/30 text-danger hover:bg-danger/10 dark:border-danger/40 dark:hover:bg-danger/15",
        link: "border-transparent text-primary underline-offset-4 hover:underline",
      },
      size: {
        sm: "h-7 px-2 text-xs",
        md: "h-8 px-3 text-[13px]",
        lg: "h-9 px-4 text-sm",
        icon: "size-7",
      },
    },
    defaultVariants: {
      variant: "primary",
      size: "md",
    },
  }
);

export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, ...props }, ref) => {
    return <button ref={ref} className={cn(buttonVariants({ variant, size }), className)} {...props} />;
  }
);
Button.displayName = "Button";
