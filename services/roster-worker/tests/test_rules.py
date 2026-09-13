"""Rule engine unit tests. No database, no queue -- pure functions."""

from datetime import datetime, timedelta, timezone

from worker.rules import (
    KIND_INSUFFICIENT_REST,
    KIND_OVERLAP,
    KIND_WEEKLY_HOURS_EXCEEDED,
    ShiftWindow,
    WorkerPolicy,
    evaluate,
    find_insufficient_rest,
    find_overlaps,
    find_weekly_hours_exceeded,
)

MON = datetime(2026, 10, 5, 8, 0, tzinfo=timezone.utc)
POLICY = WorkerPolicy(worker_id="w1", max_weekly_hours=40, min_rest_hours=11)


def win(sid: str, offset_h: float, len_h: float = 8) -> ShiftWindow:
    start = MON + timedelta(hours=offset_h)
    return ShiftWindow(sid, start, start + timedelta(hours=len_h))


# --------------------------------------------------------------------- overlap
def test_overlap_detected():
    subject = win("a", 0, 8)
    other = win("b", 4, 8)
    findings = find_overlaps(subject, [other])
    assert [f.kind for f in findings] == [KIND_OVERLAP]
    assert "b" in findings[0].detail


def test_touching_shifts_do_not_overlap():
    # ends exactly when the next begins
    assert find_overlaps(win("a", 0, 8), [win("b", 8, 8)]) == []


def test_self_is_never_an_overlap():
    subject = win("a", 0, 8)
    assert find_overlaps(subject, [subject]) == []


def test_fully_contained_shift_overlaps():
    assert len(find_overlaps(win("a", 0, 12), [win("b", 2, 2)])) == 1


# ------------------------------------------------------------------------ rest
def test_insufficient_rest_after_previous_shift():
    subject = win("a", 12, 8)       # Mon 20:00 -> Tue 04:00
    previous = win("b", 0, 8)       # Mon 08:00 -> Mon 16:00  (4h gap)
    findings = find_insufficient_rest(subject, [previous], POLICY)
    assert [f.kind for f in findings] == [KIND_INSUFFICIENT_REST]
    assert "4.0h rest before" in findings[0].detail


def test_sufficient_rest_produces_nothing():
    subject = win("a", 24, 8)       # next day 08:00, 16h after previous end
    previous = win("b", 0, 8)
    assert find_insufficient_rest(subject, [previous], POLICY) == []


def test_insufficient_rest_before_next_shift():
    subject = win("a", 0, 8)        # ends Mon 16:00
    following = win("b", 12, 8)     # starts Mon 20:00 -> 4h gap
    findings = find_insufficient_rest(subject, [following], POLICY)
    assert findings and "4.0h rest after" in findings[0].detail


def test_overlapping_shifts_skipped_by_rest_rule():
    # overlap is reported by its own rule; don't double-count
    assert find_insufficient_rest(win("a", 0, 8), [win("b", 4, 8)], POLICY) == []


def test_zero_rest_policy_disables_rule():
    policy = WorkerPolicy("w1", 40, 0)
    assert find_insufficient_rest(win("a", 12, 8), [win("b", 0, 8)], policy) == []


# ---------------------------------------------------------------- weekly hours
def test_weekly_hours_exceeded():
    subject = win("a", 0, 8)
    others = [win(f"s{i}", 24 * i, 9) for i in range(1, 5)]  # 36h + 8h = 44h
    findings = find_weekly_hours_exceeded(subject, others, POLICY)
    assert [f.kind for f in findings] == [KIND_WEEKLY_HOURS_EXCEEDED]
    assert "44.0h" in findings[0].detail


def test_weekly_hours_exactly_at_limit_is_allowed():
    subject = win("a", 0, 8)
    others = [win(f"s{i}", 24 * i, 8) for i in range(1, 5)]  # 32h + 8h = 40h
    assert find_weekly_hours_exceeded(subject, others, POLICY) == []


def test_shifts_in_other_weeks_are_excluded():
    subject = win("a", 0, 8)
    next_week = [win(f"n{i}", 24 * 7 + 24 * i, 12) for i in range(4)]
    assert find_weekly_hours_exceeded(subject, next_week, POLICY) == []


def test_week_boundary_uses_monday_start():
    # Sunday shift belongs to the previous ISO week
    sunday = win("sun", 24 * 6, 10)
    subject = win("mon-next", 24 * 7, 8)
    assert find_weekly_hours_exceeded(subject, [sunday], POLICY) == []


# ------------------------------------------------------------------- aggregate
def test_evaluate_runs_all_rules_in_stable_order():
    subject = win("a", 12, 8)
    others = [win("b", 10, 8), *[win(f"s{i}", 24 * i, 10) for i in range(1, 5)]]
    kinds = [f.kind for f in evaluate(subject, others, POLICY)]
    assert kinds[0] == KIND_OVERLAP
    assert KIND_WEEKLY_HOURS_EXCEEDED in kinds
    assert kinds == sorted(
        kinds,
        key=lambda k: [KIND_OVERLAP, KIND_INSUFFICIENT_REST, KIND_WEEKLY_HOURS_EXCEEDED].index(k),
    )


def test_clean_schedule_has_no_findings():
    subject = win("a", 0, 8)
    others = [win("b", 24, 8), win("c", 48, 8)]
    assert evaluate(subject, others, POLICY) == []
