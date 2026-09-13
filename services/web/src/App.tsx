import { useCallback, useEffect, useState } from "react";

import { ApiError, api } from "./api/client";
import { CoverageMeter } from "./components/CoverageMeter";
import { ShiftRow } from "./components/ShiftRow";
import { dayHeading, dayKey } from "./format";
import type { Coverage, Shift, Site } from "./types";

/** Demo identity. Real deployments read the worker id from the Entra token. */
const DEMO_WORKER_ID = import.meta.env.VITE_DEMO_WORKER_ID ?? "";

function groupByDay(shifts: Shift[], timeZone: string): [string, Shift[]][] {
  const groups = new Map<string, Shift[]>();
  for (const shift of shifts) {
    const key = dayKey(shift.starts_at, timeZone);
    const bucket = groups.get(key);
    if (bucket) bucket.push(shift);
    else groups.set(key, [shift]);
  }
  return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));
}

export default function App() {
  const [sites, setSites] = useState<Site[]>([]);
  const [activeSiteId, setActiveSiteId] = useState<string>("");
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [coverage, setCoverage] = useState<Coverage | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>("");
  const [claiming, setClaiming] = useState<string>("");

  const activeSite = sites.find((s) => s.id === activeSiteId);
  const timeZone = activeSite?.timezone ?? "UTC";

  useEffect(() => {
    api
      .listSites()
      .then((result) => {
        setSites(result);
        if (result.length > 0) setActiveSiteId(result[0].id);
        else setLoading(false);
      })
      .catch((err: Error) => {
        setError(err.message);
        setLoading(false);
      });
  }, []);

  const load = useCallback(async (siteId: string) => {
    setLoading(true);
    setError("");
    try {
      const [nextShifts, nextCoverage] = await Promise.all([
        api.listShifts(siteId),
        api.coverage(siteId, 7),
      ]);
      setShifts(nextShifts);
      setCoverage(nextCoverage);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not load the schedule.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (activeSiteId) void load(activeSiteId);
  }, [activeSiteId, load]);

  const handleClaim = useCallback(
    async (shift: Shift) => {
      if (!DEMO_WORKER_ID) {
        setError("No worker identity configured, so shifts cannot be claimed here.");
        return;
      }
      setClaiming(shift.id);
      setError("");
      try {
        await api.claim(shift.id, DEMO_WORKER_ID, shift.version);
        await load(shift.site_id);
      } catch (err) {
        if (err instanceof ApiError && err.status === 409) {
          // Someone else won the race. Reload so the row shows the truth.
          setError("Someone else claimed that shift first. The schedule has been refreshed.");
          await load(shift.site_id);
        } else {
          setError(err instanceof Error ? err.message : "The claim did not go through.");
        }
      } finally {
        setClaiming("");
      }
    },
    [load],
  );

  const grouped = groupByDay(shifts, timeZone);

  return (
    <div className="shell">
      <aside className="rail">
        <h1>ShiftBoard</h1>
        <nav aria-label="Sites">
          {sites.map((site) => (
            <button
              key={site.id}
              type="button"
              className="site-button"
              aria-current={site.id === activeSiteId}
              onClick={() => setActiveSiteId(site.id)}
            >
              {site.name}
            </button>
          ))}
        </nav>
      </aside>

      <main className="main">
        {error && (
          <p className="notice" data-tone="error" role="alert">
            {error}
          </p>
        )}

        {coverage && <CoverageMeter coverage={coverage} />}

        {loading && <p className="notice">Loading the schedule.</p>}

        {!loading && sites.length === 0 && (
          <div className="empty">
            <h2>No sites yet</h2>
            <p>Create a site through the API to start scheduling shifts against it.</p>
          </div>
        )}

        {!loading && sites.length > 0 && shifts.length === 0 && (
          <div className="empty">
            <h2>Nothing scheduled</h2>
            <p>Add shifts for {activeSite?.name} and they will appear here by day.</p>
          </div>
        )}

        {grouped.map(([key, dayShifts]) => (
          <section key={key}>
            <h2 className="day-heading">{dayHeading(dayShifts[0].starts_at, timeZone)}</h2>
            <ul className="shift-list">
              {dayShifts.map((shift) => (
                <ShiftRow
                  key={shift.id}
                  shift={shift}
                  timeZone={timeZone}
                  busy={claiming === shift.id}
                  onClaim={handleClaim}
                />
              ))}
            </ul>
          </section>
        ))}
      </main>
    </div>
  );
}
