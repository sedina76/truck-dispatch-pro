import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import {
  KanbanSquare,
  MapPin,
  Receipt,
  FileSignature,
  Smartphone,
  ShieldCheck,
  CheckCircle2,
  ArrowRight,
} from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { Logo } from "@/components/brand/logo";
import { AuthEnvironment } from "@/components/auth/auth-environment";

// Public homepage at "/". Signed-in users go straight to their dashboard;
// everyone else sees what the product does and starts a free trial. Every
// claim here is something the app actually does today; the only offer
// stated is the real one (30-day trial, no card -- lib/stripe/checkout.ts).

export const metadata: Metadata = {
  title: "Truck Dispatch Pro — dispatch software for dispatch services",
  description:
    "Book loads, track trucks, bill brokers and carriers, and onboard carriers with e-signed agreements — in one place. 30-day free trial, no credit card.",
};

const FEATURES = [
  {
    icon: KanbanSquare,
    title: "Dispatch board & schedule",
    body: "Every load from booking to delivery on one board, with a calendar of pickups, deliveries, maintenance and expirations.",
  },
  {
    icon: MapPin,
    title: "Live tracking & ETAs",
    body: "See every truck on the map with an ETA that counts required rest breaks, plus weather alerts on the route.",
  },
  {
    icon: Receipt,
    title: "Billing that fits dispatch",
    body: "Invoices and billing packets, carrier invoices for factoring sent automatically, and weekly dispatch-fee invoices to carriers.",
  },
  {
    icon: FileSignature,
    title: "Carrier onboarding",
    body: "Invite a carrier, collect W-9, insurance and authority, and get your dispatch agreement e-signed — ready-made agreements included.",
  },
  {
    icon: Smartphone,
    title: "Driver app",
    body: "Drivers share location, upload BOLs and PODs, and submit fuel and expenses from their phone; your office is notified right away.",
  },
  {
    icon: ShieldCheck,
    title: "Safety & compliance",
    body: "Track CDL, medical card and insurance expirations, and keep a safety history of incidents for every driver and truck.",
  },
];

const STEPS = [
  { title: "Create your account", body: "Sign up with Google or your email and set up your dispatch company in a few minutes." },
  { title: "Add carriers and drivers", body: "Send onboarding invites; carriers sign your agreement and upload their documents online." },
  { title: "Dispatch, track, get paid", body: "Book loads, follow trucks live, and send invoices and paperwork to brokers and factors." },
];

const FAQ = [
  {
    q: "Do I need a credit card to start?",
    a: "No. The 30-day trial is free and needs no card. You choose a plan in Settings when you are ready.",
  },
  {
    q: "Is my company's data kept separate?",
    a: "Yes. Every dispatch company has its own account; carriers, loads and invoices are never visible to another company.",
  },
  {
    q: "Does it work when the broker pays the carrier directly?",
    a: "Yes. Set who the broker pays per carrier. The carrier's invoice goes to the broker or factor, and you bill the carrier your dispatch fee.",
  },
  {
    q: "What do drivers need?",
    a: "A smartphone. Drivers sign in to the driver app to share their location, upload documents and submit expenses.",
  },
];

function SectionTitle({ eyebrow, title, id }: { eyebrow: string; title: string; id: string }) {
  return (
    <div className="mx-auto max-w-3xl text-center">
      <p className="text-[12.5px] font-semibold uppercase tracking-[0.14em] text-[#39a0ff]">{eyebrow}</p>
      <h2 id={id} className="mt-3 text-[30px] font-bold tracking-tight text-white sm:text-[36px]">
        {title}
      </h2>
    </div>
  );
}

export default async function HomePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) redirect("/dashboard");

  return (
    <div className="min-h-screen bg-[#05070d] text-white" data-testid="homepage">
      {/* Hero, on the same night-interstate artwork as sign-in */}
      <section className="relative flex min-h-[680px] flex-col overflow-hidden lg:min-h-[800px]" aria-labelledby="hero-title">
        <AuthEnvironment rich />
        {/* Keeps the headline readable over the artwork */}
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-r from-[#05070d]/80 via-[#05070d]/35 to-transparent" aria-hidden="true" />
        <header className="relative z-10 mx-auto flex w-full max-w-[1240px] items-center justify-between gap-4 px-5 py-5 sm:px-8">
          <span className="sm:hidden">
            <Logo dark />
          </span>
          <span className="hidden sm:block">
            <Logo dark subtitle size="lg" />
          </span>
          <nav className="flex items-center gap-2 text-[14px] sm:gap-5">
            <a href="#features" className="hidden text-white/75 hover:text-white md:inline">
              Features
            </a>
            <a href="#how" className="hidden text-white/75 hover:text-white md:inline">
              How it works
            </a>
            <a href="#pricing" className="hidden text-white/75 hover:text-white md:inline">
              Pricing
            </a>
            <Link href="/login" className="whitespace-nowrap rounded-md px-3 py-2 font-medium text-white/90 hover:bg-white/10">
              Sign in
            </Link>
            <Link href="/signup" className="hidden rounded-md bg-[#1c54b8] px-4 py-2 font-semibold hover:bg-[#164291] sm:inline-flex">
              Start free trial
            </Link>
          </nav>
        </header>

        <div className="relative z-10 mx-auto flex w-full max-w-[1240px] flex-1 flex-col justify-center px-5 pb-24 pt-10 sm:px-8">
          <p className="text-[13px] font-semibold uppercase tracking-[0.14em] text-[#39a0ff]">30-day free trial · no credit card</p>
          <h1 id="hero-title" className="mt-4 max-w-[760px] text-[40px] font-bold leading-[1.08] tracking-[-0.025em] sm:text-[56px]">
            Dispatch software built for <span className="text-primary">dispatch services.</span>
          </h1>
          <p className="mt-6 max-w-[620px] text-[17px] leading-7 text-white/70">
            Book loads, track every truck, bill brokers and carriers, and onboard carriers with e-signed agreements — all in one place.
          </p>
          <div className="mt-9 flex flex-wrap items-center gap-3">
            <Link
              href="/signup"
              className="inline-flex h-12 items-center gap-2 rounded-md bg-[#1c54b8] px-6 text-[15.5px] font-semibold shadow-[0_8px_20px_-6px_rgba(28,84,184,0.6)] hover:bg-[#164291]"
            >
              Start your free trial <ArrowRight className="size-4" />
            </Link>
            <Link href="/login" className="inline-flex h-12 items-center rounded-md border border-white/25 bg-white/5 px-6 text-[15.5px] font-medium hover:bg-white/10">
              Sign in
            </Link>
          </div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="scroll-mt-6 border-t border-white/10 px-5 py-20 sm:px-8 sm:py-24" aria-labelledby="features-title">
        <SectionTitle id="features-title" eyebrow="Features" title="Everything a dispatch office runs on" />
        <div className="mx-auto mt-12 grid max-w-[1140px] gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f) => (
            <div key={f.title} className="rounded-xl border border-white/10 bg-white/[0.03] p-6">
              <span className="flex size-11 items-center justify-center rounded-xl border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]">
                <f.icon className="size-5" />
              </span>
              <h3 className="mt-4 text-[17px] font-semibold">{f.title}</h3>
              <p className="mt-2 text-[14.5px] leading-6 text-white/65">{f.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="scroll-mt-6 border-t border-white/10 bg-[#070b15] px-5 py-20 sm:px-8 sm:py-24" aria-labelledby="how-title">
        <SectionTitle id="how-title" eyebrow="How it works" title="Up and running the same day" />
        <ol className="mx-auto mt-12 grid max-w-[1040px] gap-6 md:grid-cols-3">
          {STEPS.map((s, i) => (
            <li key={s.title} className="relative rounded-xl border border-white/10 bg-white/[0.03] p-6">
              <span className="flex size-9 items-center justify-center rounded-full bg-[#1c54b8] text-[15px] font-bold">{i + 1}</span>
              <h3 className="mt-4 text-[17px] font-semibold">{s.title}</h3>
              <p className="mt-2 text-[14.5px] leading-6 text-white/65">{s.body}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* Pricing */}
      <section id="pricing" className="scroll-mt-6 border-t border-white/10 px-5 py-20 sm:px-8 sm:py-24" aria-labelledby="pricing-title">
        <SectionTitle id="pricing-title" eyebrow="Pricing" title="Try everything free for 30 days" />
        <div className="mx-auto mt-12 max-w-[520px] rounded-2xl border border-[#2680ff]/45 bg-[#081426] p-8 text-center shadow-[0_30px_70px_-30px_rgba(25,118,255,0.45)]">
          <p className="text-[15px] font-semibold text-[#39a0ff]">Free trial</p>
          <p className="mt-2 text-[44px] font-bold leading-none">30 days</p>
          <p className="mt-2 text-white/60">No credit card. Every feature included.</p>
          <ul className="mx-auto mt-6 max-w-[320px] space-y-2.5 text-left text-[14.5px] text-white/80">
            {["Loads, dispatches and the dispatch board", "Driver app and live tracking", "Invoicing, factoring and carrier onboarding", "Pick a plan when your trial ends"].map((x) => (
              <li key={x} className="flex items-start gap-2.5">
                <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-[#39a0ff]" />
                {x}
              </li>
            ))}
          </ul>
          <Link href="/signup" className="mt-8 inline-flex h-12 w-full items-center justify-center gap-2 rounded-md bg-[#1c54b8] text-[15.5px] font-semibold hover:bg-[#164291]">
            Start your free trial <ArrowRight className="size-4" />
          </Link>
        </div>
      </section>

      {/* FAQ */}
      <section className="border-t border-white/10 bg-[#070b15] px-5 py-20 sm:px-8 sm:py-24" aria-labelledby="faq-title">
        <SectionTitle id="faq-title" eyebrow="FAQ" title="Questions dispatchers ask" />
        <div className="mx-auto mt-10 max-w-[760px] divide-y divide-white/10 rounded-xl border border-white/10 bg-white/[0.03]">
          {FAQ.map((f) => (
            <details key={f.q} className="group px-6 py-5">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-[16px] font-medium">
                {f.q}
                <span className="text-white/50 transition-transform group-open:rotate-45">+</span>
              </summary>
              <p className="mt-3 text-[14.5px] leading-6 text-white/65">{f.a}</p>
            </details>
          ))}
        </div>
      </section>

      {/* Closing call to action + footer */}
      <section className="border-t border-white/10 px-5 py-20 text-center sm:px-8">
        <h2 className="text-[28px] font-bold tracking-tight sm:text-[34px]">Ready to run your dispatch office from one place?</h2>
        <p className="mt-3 text-white/60">Set up in minutes. 30 days free, no credit card.</p>
        <Link href="/signup" className="mt-8 inline-flex h-12 items-center gap-2 rounded-md bg-[#1c54b8] px-7 text-[15.5px] font-semibold hover:bg-[#164291]">
          Start your free trial <ArrowRight className="size-4" />
        </Link>
      </section>
      <footer className="border-t border-white/10 px-5 py-8 sm:px-8">
        <div className="mx-auto flex max-w-[1240px] flex-wrap items-center justify-between gap-4 text-[13.5px] text-white/50">
          <span>© {new Date().getFullYear()} Truck Dispatch Pro</span>
          <div className="flex gap-5">
            <Link href="/login" className="hover:text-white">
              Sign in
            </Link>
            <Link href="/driver-portal/login" className="hover:text-white">
              Driver sign in
            </Link>
            <Link href="/signup" className="hover:text-white">
              Create account
            </Link>
          </div>
        </div>
      </footer>
    </div>
  );
}
