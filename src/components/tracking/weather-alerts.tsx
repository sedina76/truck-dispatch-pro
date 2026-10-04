import { CloudLightning } from "lucide-react";
import { cn } from "@/lib/utils";
import { alertLine, alertTone, type WeatherAlert } from "@/lib/weather/nws";

// Active National Weather Service warnings on a truck's route / at its stops.
export function WeatherAlerts({ alerts, timeZone, compact = false }: { alerts: WeatherAlert[] | null | undefined; timeZone?: string; compact?: boolean }) {
  if (!alerts || alerts.length === 0) return null;
  const shown = compact ? alerts.slice(0, 2) : alerts.slice(0, 5);
  const danger = alerts.some((a) => alertTone(a) === "danger");
  return (
    <div
      className={cn("rounded-sm border px-2.5 py-1.5 text-[12px]", danger ? "border-danger/40 bg-danger/5 text-danger" : "border-warning/40 bg-warning/10 text-warning")}
      data-testid="weather-alerts"
    >
      <p className="flex items-center gap-1.5 font-semibold">
        <CloudLightning className="size-3.5 shrink-0" /> Weather {alerts.length === 1 ? "alert" : `alerts (${alerts.length})`}
      </p>
      <ul className="mt-0.5 space-y-0.5">
        {shown.map((a) => (
          <li key={a.id}>{alertLine(a, timeZone)}</li>
        ))}
        {alerts.length > shown.length && <li className="opacity-80">+{alerts.length - shown.length} more</li>}
      </ul>
      {!compact && <p className="mt-0.5 text-[10.5px] opacity-70">Source: National Weather Service (updates every ~10 min).</p>}
    </div>
  );
}
