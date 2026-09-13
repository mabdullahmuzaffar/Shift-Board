const CONFLICT_LABELS: Record<string, string> = {
  overlap: "Double-booked",
  insufficient_rest: "Not enough rest",
  weekly_hours_exceeded: "Over weekly hours",
};

const STATUS_LABELS: Record<string, string> = {
  open: "Unfilled",
  claimed: "Claimed",
  confirmed: "Confirmed",
  cancelled: "Cancelled",
};

export function conflictLabel(kind: string): string {
  return CONFLICT_LABELS[kind] ?? kind;
}

export function statusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status;
}

export function timeRange(startsAt: string, endsAt: string, timeZone: string): string {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone,
  });
  return `${fmt.format(new Date(startsAt))}–${fmt.format(new Date(endsAt))}`;
}

export function dayKey(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone,
  }).format(new Date(iso));
}

export function dayHeading(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "long",
    day: "numeric",
    month: "long",
    timeZone,
  }).format(new Date(iso));
}

export function durationHours(startsAt: string, endsAt: string): number {
  const ms = new Date(endsAt).getTime() - new Date(startsAt).getTime();
  return Math.round((ms / 3_600_000) * 10) / 10;
}
