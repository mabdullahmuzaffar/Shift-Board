"""Consumer settlement tests.

These use fake receiver/message objects instead of a broker, so the whole
complete / abandon / dead-letter matrix and the graceful-drain path are
covered in CI without Azure credentials.
"""

import json
from datetime import datetime, timezone

from tests.conftest import make_shift
from worker import main as consumer
from worker.config import get_settings
from worker.main import (
    ABANDONED,
    COMPLETED,
    DEAD_LETTERED,
    dispatch_message,
    drain_loop,
)


class FakeMessage:
    def __init__(self, body: str, delivery_count: int = 1) -> None:
        self.body = [body.encode("utf-8")]
        self.delivery_count = delivery_count


class FakeReceiver:
    def __init__(self, batches=None) -> None:
        self.completed: list[FakeMessage] = []
        self.abandoned: list[FakeMessage] = []
        self.dead_lettered: list[tuple[FakeMessage, str]] = []
        self._batches = list(batches or [])
        self.receive_calls = 0

    def complete_message(self, message):
        self.completed.append(message)

    def abandon_message(self, message):
        self.abandoned.append(message)

    def dead_letter_message(self, message, reason="", error_description=""):
        self.dead_lettered.append((message, error_description))

    def receive_messages(self, max_message_count=10, max_wait_time=10):
        self.receive_calls += 1
        if self._batches:
            return self._batches.pop(0)
        consumer._shutdown.set()   # nothing left: end the loop
        return []


def envelope(event_type="shift.claimed", shift_id="s1", event_id="evt-1") -> str:
    return json.dumps(
        {
            "event_id": event_id,
            "event_type": event_type,
            "occurred_at": datetime.now(timezone.utc).isoformat(),
            "schema_version": 1,
            "data": {"shift_id": shift_id},
        }
    )


def setup_function() -> None:
    consumer._shutdown.clear()


# ------------------------------------------------------------------- dispatch
def test_successful_message_is_completed(session_factory, session, seeded):
    make_shift(session, "s1", offset_hours=0)
    receiver = FakeReceiver()
    result = dispatch_message(receiver, FakeMessage(envelope()), session_factory)

    assert result == COMPLETED
    assert len(receiver.completed) == 1
    assert not receiver.abandoned and not receiver.dead_lettered


def test_malformed_message_is_dead_lettered(session_factory, seeded):
    receiver = FakeReceiver()
    result = dispatch_message(receiver, FakeMessage("}{not json"), session_factory)

    assert result == DEAD_LETTERED
    assert len(receiver.dead_lettered) == 1
    assert "not valid JSON" in receiver.dead_lettered[0][1]
    assert not receiver.completed


def test_unknown_worker_reference_is_dead_lettered(session_factory, session, seeded):
    make_shift(session, "s1", offset_hours=0, worker_id="ghost")
    receiver = FakeReceiver()
    result = dispatch_message(receiver, FakeMessage(envelope()), session_factory)

    assert result == DEAD_LETTERED
    assert "unknown worker" in receiver.dead_lettered[0][1]


def test_transient_failure_is_abandoned(session_factory, seeded, monkeypatch):
    def boom(*_args, **_kwargs):
        raise RuntimeError("database connection reset")

    monkeypatch.setattr("worker.main.handle_event", boom)
    receiver = FakeReceiver()
    result = dispatch_message(receiver, FakeMessage(envelope()), session_factory)

    assert result == ABANDONED
    assert len(receiver.abandoned) == 1
    assert not receiver.dead_lettered


def test_duplicate_redelivery_is_still_completed(session_factory, session, seeded):
    """At-least-once delivery: the second copy must be settled, not retried forever."""
    make_shift(session, "s1", offset_hours=0)
    receiver = FakeReceiver()

    dispatch_message(receiver, FakeMessage(envelope()), session_factory)
    dispatch_message(receiver, FakeMessage(envelope(), delivery_count=2), session_factory)

    assert len(receiver.completed) == 2
    assert not receiver.dead_lettered


# ----------------------------------------------------------------- drain loop
def test_drain_loop_processes_a_batch_then_exits(session_factory, session, seeded):
    make_shift(session, "s1", offset_hours=0)
    receiver = FakeReceiver(batches=[[FakeMessage(envelope())]])

    drain_loop(receiver, get_settings(), session_factory)

    assert len(receiver.completed) == 1
    assert receiver.receive_calls >= 1


def test_drain_loop_abandons_in_flight_messages_on_sigterm(
    session_factory, session, seeded
):
    make_shift(session, "s1", offset_hours=0)
    batch = [FakeMessage(envelope(event_id="a")), FakeMessage(envelope(event_id="b"))]
    receiver = FakeReceiver(batches=[batch])

    original = consumer.dispatch_message

    def dispatch_then_shutdown(rcv, msg, factory):
        result = original(rcv, msg, factory)
        consumer._shutdown.set()   # simulate SIGTERM mid-batch
        return result

    consumer.dispatch_message = dispatch_then_shutdown
    try:
        drain_loop(receiver, get_settings(), session_factory)
    finally:
        consumer.dispatch_message = original

    assert len(receiver.completed) == 1     # first one finished
    assert len(receiver.abandoned) == 1     # second handed back for another replica


def test_drain_loop_survives_receive_errors(session_factory, seeded):
    class FlakyReceiver(FakeReceiver):
        def receive_messages(self, max_message_count=10, max_wait_time=10):
            self.receive_calls += 1
            consumer._shutdown.set()
            raise RuntimeError("transient AMQP link failure")

    receiver = FlakyReceiver()
    drain_loop(receiver, get_settings(), session_factory)   # must not raise
    assert receiver.receive_calls == 1
