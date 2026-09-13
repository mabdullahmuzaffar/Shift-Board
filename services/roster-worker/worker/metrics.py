from prometheus_client import Counter, Gauge, Histogram

EVENTS_PROCESSED = Counter(
    "roster_worker_events_processed_total",
    "Events consumed from Service Bus by outcome.",
    ["event_type", "outcome"],
)

CONFLICTS_DETECTED = Counter(
    "roster_worker_conflicts_detected_total",
    "Scheduling conflicts written, by rule.",
    ["kind"],
)

PROCESSING_SECONDS = Histogram(
    "roster_worker_processing_seconds",
    "End-to-end handling time per event.",
    ["event_type"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

CONSUMER_UP = Gauge(
    "roster_worker_consumer_up",
    "1 when the Service Bus receiver loop is connected, 0 otherwise.",
)

EVENT_LAG_SECONDS = Histogram(
    "roster_worker_event_lag_seconds",
    "Delay between event occurrence and processing. Drives the freshness SLO.",
    buckets=(0.5, 1, 2, 5, 10, 30, 60, 300),
)
