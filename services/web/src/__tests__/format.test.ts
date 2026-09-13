import { describe, expect, it } from "vitest";

import { conflictLabel, dayKey, durationHours, statusLabel, timeRange } from "../format";

describe("formatters", () => {
  it("renders times in the site timezone, not the browser's", () => {
    const range = timeRange(
      "2026-10-05T03:00:00+00:00",
      "2026-10-05T11:00:00+00:00",
      "Asia/Karachi",
    );
    expect(range).toBe("08:00–16:00");
  });

  it("buckets a shift into the site's local day", () => {
    // 22:00 UTC is already the next day in Karachi (+05:00)
    expect(dayKey("2026-10-05T22:00:00+00:00", "Asia/Karachi")).toBe("2026-10-06");
    expect(dayKey("2026-10-05T22:00:00+00:00", "UTC")).toBe("2026-10-05");
  });

  it("computes duration in hours to one decimal", () => {
    expect(durationHours("2026-10-05T08:00:00Z", "2026-10-05T16:30:00Z")).toBe(8.5);
  });

  it("uses operator language rather than system enums", () => {
    expect(statusLabel("open")).toBe("Unfilled");
    expect(conflictLabel("insufficient_rest")).toBe("Not enough rest");
  });

  it("falls back to the raw value for unknown codes", () => {
    expect(conflictLabel("something_new")).toBe("something_new");
    expect(statusLabel("archived")).toBe("archived");
  });
});
