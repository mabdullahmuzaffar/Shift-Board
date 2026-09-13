export type ShiftStatus = "open" | "claimed" | "confirmed" | "cancelled";

export type ConflictKind = "overlap" | "insufficient_rest" | "weekly_hours_exceeded";

export interface Conflict {
  id: string;
  kind: ConflictKind;
  detail: string;
  detected_at: string;
}

export interface Shift {
  id: string;
  site_id: string;
  role: string;
  starts_at: string;
  ends_at: string;
  status: ShiftStatus;
  assigned_worker_id: string | null;
  version: number;
  conflicts: Conflict[];
}

export interface Site {
  id: string;
  name: string;
  timezone: string;
}

export interface Coverage {
  site_id: string;
  window_days: number;
  total_shifts: number;
  by_status: Partial<Record<ShiftStatus, number>>;
  fill_rate: number;
}
