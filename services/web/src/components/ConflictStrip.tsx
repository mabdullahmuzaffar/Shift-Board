import { conflictLabel } from "../format";
import type { Conflict } from "../types";

interface Props {
  conflicts: Conflict[];
}

export function ConflictStrip({ conflicts }: Props) {
  if (conflicts.length === 0) return null;

  return (
    <ul className="conflict-strip" aria-label="Scheduling conflicts">
      {conflicts.map((conflict) => (
        <li key={conflict.id}>
          <span className="conflict-kind">{conflictLabel(conflict.kind)}</span>: {conflict.detail}
        </li>
      ))}
    </ul>
  );
}
