import { ConflictStrip } from "./ConflictStrip";
import { durationHours, statusLabel, timeRange } from "../format";
import type { Shift } from "../types";

interface Props {
  shift: Shift;
  timeZone: string;
  busy: boolean;
  onClaim: (shift: Shift) => void;
}

export function ShiftRow({ shift, timeZone, busy, onClaim }: Props) {
  const claimable = shift.status === "open";

  return (
    <li>
      <div className="shift-row">
        <span className="shift-time">{timeRange(shift.starts_at, shift.ends_at, timeZone)}</span>
        <span className="shift-role">{shift.role}</span>
        <span className="shift-meta">{durationHours(shift.starts_at, shift.ends_at)}h</span>
        <span className="status" data-status={shift.status}>
          {statusLabel(shift.status)}
        </span>
        {claimable ? (
          <button
            type="button"
            className="claim-button"
            disabled={busy}
            onClick={() => onClaim(shift)}
          >
            {busy ? "Claiming" : "Claim"}
          </button>
        ) : (
          <span className="shift-meta">{shift.assigned_worker_id ? "Assigned" : "—"}</span>
        )}
      </div>
      <ConflictStrip conflicts={shift.conflicts} />
    </li>
  );
}
