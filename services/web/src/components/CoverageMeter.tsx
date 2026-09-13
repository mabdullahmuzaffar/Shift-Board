import type { Coverage } from "../types";

interface Props {
  coverage: Coverage;
}

/**
 * The hero. A scheduler's first question is never "what is my fill rate" --
 * it is "how many shifts next week still have nobody in them". So the big
 * number is the unfilled count, and the rate is supporting detail.
 */
export function CoverageMeter({ coverage }: Props) {
  const unfilled = coverage.by_status.open ?? 0;
  const percent = Math.round(coverage.fill_rate * 100);
  const clear = unfilled === 0;

  return (
    <section className="meter" aria-label="Coverage summary">
      <div className="meter-figure">
        <span className="meter-count" data-clear={clear}>
          {unfilled}
        </span>
        <span className="meter-caption">
          {unfilled === 1 ? "shift still unfilled" : "shifts still unfilled"} over the next{" "}
          {coverage.window_days} days
        </span>
      </div>

      <div
        className="meter-track"
        role="meter"
        aria-valuenow={percent}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label={`${percent} percent of shifts filled`}
      >
        <div className="meter-fill" style={{ width: `${percent}%` }} />
      </div>

      <p className="meter-legend">
        {percent}% filled · {coverage.total_shifts}{" "}
        {coverage.total_shifts === 1 ? "shift" : "shifts"} scheduled
      </p>
    </section>
  );
}
