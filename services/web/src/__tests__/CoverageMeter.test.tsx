import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { CoverageMeter } from "../components/CoverageMeter";
import type { Coverage } from "../types";

const base: Coverage = {
  site_id: "site-1",
  window_days: 7,
  total_shifts: 10,
  by_status: { open: 3, claimed: 7 },
  fill_rate: 0.7,
};

describe("CoverageMeter", () => {
  it("leads with the unfilled count", () => {
    render(<CoverageMeter coverage={base} />);
    expect(screen.getByText("3")).toBeInTheDocument();
    expect(screen.getByText(/shifts still unfilled/)).toBeInTheDocument();
  });

  it("uses the singular when one shift is unfilled", () => {
    render(<CoverageMeter coverage={{ ...base, by_status: { open: 1 } }} />);
    expect(screen.getByText(/shift still unfilled/)).toBeInTheDocument();
  });

  it("exposes the fill rate to assistive technology", () => {
    render(<CoverageMeter coverage={base} />);
    expect(screen.getByRole("meter")).toHaveAttribute("aria-valuenow", "70");
  });

  it("marks a fully covered week as clear", () => {
    render(
      <CoverageMeter coverage={{ ...base, by_status: { claimed: 10 }, fill_rate: 1 }} />,
    );
    expect(screen.getByText("0")).toHaveAttribute("data-clear", "true");
  });
});
