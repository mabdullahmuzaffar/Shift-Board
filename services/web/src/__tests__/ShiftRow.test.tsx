import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { ShiftRow } from "../components/ShiftRow";
import type { Shift } from "../types";

const openShift: Shift = {
  id: "shift-1",
  site_id: "site-1",
  role: "Nurse",
  starts_at: "2026-10-05T03:00:00+00:00",
  ends_at: "2026-10-05T11:00:00+00:00",
  status: "open",
  assigned_worker_id: null,
  version: 1,
  conflicts: [],
};

describe("ShiftRow", () => {
  it("offers a claim action for unfilled shifts", async () => {
    const onClaim = vi.fn();
    render(
      <ShiftRow shift={openShift} timeZone="Asia/Karachi" busy={false} onClaim={onClaim} />,
    );
    await userEvent.click(screen.getByRole("button", { name: "Claim" }));
    expect(onClaim).toHaveBeenCalledWith(openShift);
  });

  it("hides the claim action once a shift is taken", () => {
    render(
      <ShiftRow
        shift={{ ...openShift, status: "claimed", assigned_worker_id: "w1" }}
        timeZone="UTC"
        busy={false}
        onClaim={vi.fn()}
      />,
    );
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(screen.getByText("Claimed")).toBeInTheDocument();
  });

  it("disables the button while a claim is in flight", () => {
    render(<ShiftRow shift={openShift} timeZone="UTC" busy onClaim={vi.fn()} />);
    expect(screen.getByRole("button", { name: "Claiming" })).toBeDisabled();
  });

  it("surfaces conflicts in operator language", () => {
    render(
      <ShiftRow
        shift={{
          ...openShift,
          status: "claimed",
          conflicts: [
            {
              id: "c1",
              kind: "insufficient_rest",
              detail: "only 4.0h rest before shift shift-9",
              detected_at: "2026-10-01T00:00:00Z",
            },
          ],
        }}
        timeZone="UTC"
        busy={false}
        onClaim={vi.fn()}
      />,
    );
    expect(screen.getByText("Not enough rest")).toBeInTheDocument();
    expect(screen.getByLabelText("Scheduling conflicts")).toBeInTheDocument();
  });
});
