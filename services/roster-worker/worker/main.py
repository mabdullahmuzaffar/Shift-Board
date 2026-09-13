"""Service Bus consumer loop.

Delivery semantics, spelled out because this is the part interviewers probe:

  * PEEK_LOCK receive mode. The message stays invisible while we work and is
    only removed after an explicit complete().
  * Success        -> complete()      : message gone.
  * TransientError -> abandon()       : lock released immediately, redelivered.
                                        delivery_count increments; after
                                        max_delivery_count (5) Service Bus
                                        dead-letters it automatically.
  * PermanentError -> dead_letter()   : moved straight to the DLQ with a
                                        reason, no retry storm.
  * Database commit and the idempotency ledger write happen in ONE
    transaction, and complete() happens only after that commit. If the pod
    dies between commit and complete, redelivery hits the ledger and returns
    'duplicate' instead of writing twice.

SIGTERM triggers a graceful drain so a rolling update or a Karpenter node
consolidation does not abandon in-flight work.
"""

from __future__ import annotations

import signal
import sys
import threading

from prometheus_client import start_http_server

from worker.config import Settings, get_settings
from worker.db import build_engine
from worker.handler import PermanentError, TransientError, handle_event, parse_event
from worker.metrics import CONSUMER_UP, EVENTS_PROCESSED, PROCESSING_SECONDS
from worker.telemetry import configure_logging, configure_tracing, get_logger

log = get_logger(__name__)
_shutdown = threading.Event()


def _install_signal_handlers() -> None:
    def _handle(signum, _frame):  # noqa: ANN001
        log.info("shutdown_signal", signal=signal.Signals(signum).name)
        _shutdown.set()

    signal.signal(signal.SIGTERM, _handle)
    signal.signal(signal.SIGINT, _handle)


def process_one(session_factory, raw_body: str) -> str:
    """Parse, handle and commit a single message. Raises on failure."""
    event = parse_event(raw_body)
    event_type = event.get("event_type", "unknown")

    with PROCESSING_SECONDS.labels(event_type=event_type).time():
        session = session_factory()
        try:
            outcome = handle_event(session, event)
            session.commit()
        except PermanentError:
            session.rollback()
            raise
        except Exception as exc:
            session.rollback()
            raise TransientError(str(exc)) from exc
        finally:
            session.close()

    EVENTS_PROCESSED.labels(event_type=event_type, outcome=outcome).inc()
    return outcome


class Disposition(str):
    """What the consumer did with a message. Returned so callers/tests can assert."""


COMPLETED = "completed"
ABANDONED = "abandoned"
DEAD_LETTERED = "dead_lettered"


def dispatch_message(receiver, message, session_factory) -> str:
    """Handle exactly one message and settle it.

    Deliberately duck-typed on `receiver` and `message` rather than importing
    the Service Bus SDK, so the full settlement matrix (complete / abandon /
    dead-letter) is unit-tested without a broker. `run_consumer` is then a
    thin loop around this function.
    """
    body = b"".join(message.body).decode("utf-8")
    try:
        outcome = process_one(session_factory, body)
    except PermanentError as exc:
        EVENTS_PROCESSED.labels(event_type="invalid", outcome=DEAD_LETTERED).inc()
        receiver.dead_letter_message(
            message, reason="PermanentError", error_description=str(exc)[:4000]
        )
        log.error("message_dead_lettered", error=str(exc))
        return DEAD_LETTERED
    except TransientError as exc:
        EVENTS_PROCESSED.labels(event_type="unknown", outcome=ABANDONED).inc()
        receiver.abandon_message(message)
        log.warning(
            "message_abandoned",
            error=str(exc),
            delivery_count=getattr(message, "delivery_count", None),
        )
        return ABANDONED

    # Settle only after the database transaction committed. A crash between
    # commit and complete causes redelivery, which the idempotency ledger
    # absorbs as a duplicate.
    receiver.complete_message(message)
    log.info(
        "message_completed",
        outcome=outcome,
        delivery_count=getattr(message, "delivery_count", None),
    )
    return COMPLETED


def run_consumer(settings: Settings, session_factory) -> None:
    from azure.identity import DefaultAzureCredential
    from azure.servicebus import ServiceBusClient, ServiceBusReceiveMode

    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    client = ServiceBusClient(
        fully_qualified_namespace=settings.servicebus_fqdn,
        credential=credential,
    )

    log.info(
        "consumer_starting",
        namespace=settings.servicebus_namespace,
        queue=settings.servicebus_queue,
    )

    with client:
        receiver = client.get_queue_receiver(
            queue_name=settings.servicebus_queue,
            receive_mode=ServiceBusReceiveMode.PEEK_LOCK,
            prefetch_count=settings.prefetch_count,
        )
        with receiver:
            drain_loop(receiver, settings, session_factory)


def drain_loop(receiver, settings: Settings, session_factory) -> None:
    """Receive/settle until SIGTERM. Separated from SDK construction for testing."""
    CONSUMER_UP.set(1)
    while not _shutdown.is_set():
        try:
            batch = receiver.receive_messages(
                max_message_count=settings.max_message_batch,
                max_wait_time=settings.max_wait_seconds,
            )
        except Exception as exc:
            CONSUMER_UP.set(0)
            log.error("receive_failed", error=str(exc))
            if _shutdown.wait(timeout=5):
                break
            continue

        CONSUMER_UP.set(1)
        for message in batch:
            if _shutdown.is_set():
                # Give the message straight back so another replica picks it up
                # instead of waiting for the lock to expire.
                receiver.abandon_message(message)
                continue
            dispatch_message(receiver, message, session_factory)

    CONSUMER_UP.set(0)
    log.info("consumer_drained")


def main() -> int:
    settings = get_settings()
    configure_logging(settings.service_name, settings.environment, settings.log_level)
    _install_signal_handlers()

    start_http_server(settings.metrics_port)
    log.info("metrics_server_started", port=settings.metrics_port)

    engine = build_engine(settings)
    configure_tracing(engine, settings)

    from sqlalchemy.orm import sessionmaker

    session_factory = sessionmaker(bind=engine, expire_on_commit=False, future=True)

    if not settings.servicebus_namespace:
        log.error("servicebus_namespace_not_configured")
        return 2

    try:
        run_consumer(settings, session_factory)
    except Exception as exc:
        log.error("consumer_crashed", error=str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
