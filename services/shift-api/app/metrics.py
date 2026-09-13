"""Application-level Prometheus metrics.

These are the series the SLO and alert rules in observability/alerts are
built on. HTTP latency/error metrics come free from
prometheus-fastapi-instrumentator; the ones here are domain signals that
generic HTTP metrics cannot express.
"""

from prometheus_client import Counter, Gauge, Histogram

SHIFTS_CREATED = Counter(
    "shiftboard_shifts_created_total",
    "Shifts created, by site.",
    ["site_id"],
)

SHIFT_CLAIMS = Counter(
    "shiftboard_shift_claims_total",
    "Shift claim attempts by outcome (accepted, conflict, not_found, forbidden).",
    ["outcome"],
)

EVENT_PUBLISH_FAILURES = Counter(
    "shiftboard_event_publish_failures_total",
    "Domain events that could not be published to Service Bus.",
    ["event_type"],
)

OPEN_SHIFTS = Gauge(
    "shiftboard_open_shifts",
    "Currently open (unclaimed) shifts, refreshed on read.",
    ["site_id"],
)

DB_QUERY_SECONDS = Histogram(
    "shiftboard_db_query_seconds",
    "Duration of hand-written domain queries.",
    ["query"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
