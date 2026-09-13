import type { Coverage, Shift, Site } from "../types";

/**
 * All calls are relative. nginx in the same pod proxies /api to the
 * shift-api Service, so no backend hostname is ever baked into the bundle
 * and the same image runs unchanged in dev and prod.
 */
const BASE = "/api/v1";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });

  if (!response.ok) {
    let detail = `Request failed with status ${response.status}`;
    try {
      const body = await response.json();
      if (typeof body?.detail === "string") detail = body.detail;
    } catch {
      // Non-JSON error body; keep the status-based message.
    }
    throw new ApiError(detail, response.status);
  }

  return (await response.json()) as T;
}

export const api = {
  listSites: () => request<Site[]>("/sites"),

  listShifts: (siteId: string) =>
    request<Shift[]>(`/shifts?site_id=${encodeURIComponent(siteId)}&limit=200`),

  coverage: (siteId: string, days = 7) =>
    request<Coverage>(`/sites/${encodeURIComponent(siteId)}/coverage?days=${days}`),

  claim: (shiftId: string, workerId: string, expectedVersion: number) =>
    request<Shift>(`/shifts/${encodeURIComponent(shiftId)}/claim`, {
      method: "POST",
      body: JSON.stringify({ worker_id: workerId, expected_version: expectedVersion }),
    }),
};
