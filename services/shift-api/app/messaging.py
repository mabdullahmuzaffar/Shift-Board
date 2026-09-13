"""Service Bus publisher.

shift-api publishes a small domain event whenever a shift is created, claimed
or cancelled. roster-worker consumes the queue and runs the conflict rules.

Auth is workload identity -- DefaultAzureCredential picks up the projected
service account token, exchanges it for an Entra token, and the pod never
holds a Service Bus connection string. `publish` is fail-open by design:
losing an event degrades conflict detection but must not break the write
path. Every send failure increments a counter that an alert rule watches.
"""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any, Protocol

from app.config import Settings, get_settings
from app.telemetry import get_logger

log = get_logger(__name__)


class Publisher(Protocol):
    def publish(self, event_type: str, payload: dict[str, Any]) -> str | None: ...


def _envelope(event_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "event_id": str(uuid.uuid4()),
        "event_type": event_type,
        "occurred_at": datetime.now(UTC).isoformat(),
        "schema_version": 1,
        "data": payload,
    }


class NullPublisher:
    """Used locally and in unit tests. Records what would have been sent."""

    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []

    def publish(self, event_type: str, payload: dict[str, Any]) -> str | None:
        env = _envelope(event_type, payload)
        self.sent.append(env)
        log.info("event_published", sink="null", event_type=event_type, event_id=env["event_id"])
        return env["event_id"]


class ServiceBusPublisher:
    def __init__(self, settings: Settings) -> None:
        from azure.identity import DefaultAzureCredential
        from azure.servicebus import ServiceBusClient

        self._settings = settings
        self._credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        self._client = ServiceBusClient(
            fully_qualified_namespace=settings.servicebus_fqdn,
            credential=self._credential,
        )
        self._sender = self._client.get_queue_sender(queue_name=settings.servicebus_queue)
        log.info(
            "servicebus_publisher_ready",
            namespace=settings.servicebus_namespace,
            queue=settings.servicebus_queue,
        )

    def publish(self, event_type: str, payload: dict[str, Any]) -> str | None:
        from azure.servicebus import ServiceBusMessage

        env = _envelope(event_type, payload)
        try:
            msg = ServiceBusMessage(
                json.dumps(env),
                content_type="application/json",
                message_id=env["event_id"],          # Service Bus dedup window
                subject=event_type,
                application_properties={"schema_version": 1},
            )
            self._sender.send_messages(msg)
        except Exception as exc:
            # Fail open. The write already succeeded; a lost event means the
            # conflict scan for this shift is delayed, not that data is wrong.
            from app.metrics import EVENT_PUBLISH_FAILURES

            EVENT_PUBLISH_FAILURES.labels(event_type=event_type).inc()
            log.error("event_publish_failed", event_type=event_type, error=str(exc))
            return None

        log.info(
            "event_published",
            sink="servicebus",
            event_type=event_type,
            event_id=env["event_id"],
        )
        return env["event_id"]

    def close(self) -> None:
        try:
            self._sender.close()
            self._client.close()
        except Exception as exc:  # pragma: no cover
            log.warning("servicebus_close_failed", error=str(exc))


_publisher: Publisher | None = None


def get_publisher() -> Publisher:
    global _publisher
    if _publisher is None:
        settings = get_settings()
        if settings.servicebus_enabled and settings.servicebus_namespace:
            _publisher = ServiceBusPublisher(settings)
        else:
            _publisher = NullPublisher()
    return _publisher


def set_publisher(publisher: Publisher | None) -> None:
    """Test seam."""
    global _publisher
    _publisher = publisher
