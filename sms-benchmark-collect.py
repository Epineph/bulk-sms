#!/usr/bin/env python3

"""
sms_benchmark_collect.py

Collect host-only benchmark timings for a simulated local SMS enqueue path.

What is measured
----------------
For each iteration, the timed block performs:

  1. phone-number validation
  2. payload construction
  3. one append to a simulated outbox CSV
  4. optional flush
  5. optional fsync

What is *not* measured
----------------------
The timing does not include:
  - writing the benchmark-results CSV
  - optional sleep between iterations

That separation is deliberate.

Input
-----
A text file with one recipient number per line, for example:

  +4512345678
  +4587654321

Blank lines and lines beginning with '#' are ignored.

Output
------
1. A simulated outbox CSV
2. A benchmark results CSV with one row per measured iteration

Examples
--------
  python sms_benchmark_collect.py \
    --numbers-file dk_numbers.txt

  python sms_benchmark_collect.py \
    --numbers-file dk_numbers.txt \
    --iterations 5000 \
    --message-size 160 \
    --flush \
    --results-csv bench.csv \
    --queue-csv outbox.csv

  python sms_benchmark_collect.py \
    --numbers-file dk_numbers.txt \
    --iterations 2000 \
    --fsync \
    --inter-iteration-sleep-ms 1.0
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import string
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_ITERATIONS = 1000
DEFAULT_MESSAGE_SIZE = 160


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class QueueRow:
    """One simulated outbox row."""

    queue_id: str
    created_utc: str
    recipient: str
    message_text: str
    message_length: int


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def utc_now_iso() -> str:
    """Return current UTC timestamp in ISO-8601 format."""

    return datetime.now(timezone.utc).isoformat()


def build_default_output_name(prefix: str, suffix: str) -> str:
    """Create a timestamped default output filename."""

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{prefix}_{timestamp}.{suffix}"


def validate_danish_number(value: str) -> str:
    """Validate a Danish-style E.164 number.

    Expected format:
      +45XXXXXXXX

    where X are digits and the national part has length 8.
    """

    value = value.strip()

    if not value.startswith("+45"):
        raise ValueError(f"Not a +45 number: {value!r}")

    if len(value) != 11:
        raise ValueError(f"Expected 11 characters including '+': {value!r}")

    national = value[3:]

    if not national.isdigit():
        raise ValueError(f"National part is not all digits: {value!r}")

    return value


def load_numbers(path: Path) -> list[str]:
    """Load, clean, and validate numbers from a text file."""

    if not path.is_file():
        raise FileNotFoundError(f"Numbers file not found: {path}")

    cleaned: list[str] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()

        if not line:
            continue

        if line.startswith("#"):
            continue

        cleaned.append(validate_danish_number(line))

    if not cleaned:
        raise ValueError("No valid numbers found in input file.")

    return cleaned


def generate_message_text(size: int, seed: int | None = None) -> str:
    """Generate deterministic-ish ASCII message text.

    The text is synthetic. This keeps the benchmark reproducible and avoids
    reading message bodies from disk during each iteration.
    """

    if size <= 0:
        raise ValueError("--message-size must be > 0")

    rng = random.Random(seed)
    alphabet = string.ascii_letters + string.digits + " "
    return "".join(rng.choice(alphabet) for _ in range(size))


def maybe_write_header(writer: csv.DictWriter, file_obj) -> None:
    """Write CSV header if the file is empty."""

    if file_obj.tell() == 0:
        writer.writeheader()


def build_queue_row(recipient: str, message_text: str) -> QueueRow:
    """Build one simulated outbox row."""

    return QueueRow(
        queue_id=str(uuid.uuid4()),
        created_utc=utc_now_iso(),
        recipient=recipient,
        message_text=message_text,
        message_length=len(message_text),
    )


def timed_enqueue(
    *,
    recipient: str,
    message_text: str,
    queue_writer: csv.DictWriter,
    queue_file,
    do_flush: bool,
    do_fsync: bool,
) -> tuple[int, int]:
    """Perform the timed local surrogate enqueue.

    Returns
    -------
    tuple[int, int]
      (start_ns, end_ns)
    """

    start_ns = time.perf_counter_ns()

    validated = validate_danish_number(recipient)
    row = build_queue_row(validated, message_text)

    queue_writer.writerow(
        {
            "queue_id": row.queue_id,
            "created_utc": row.created_utc,
            "recipient": row.recipient,
            "message_text": row.message_text,
            "message_length": row.message_length,
        }
    )

    if do_flush or do_fsync:
        queue_file.flush()

    if do_fsync:
        os.fsync(queue_file.fileno())

    end_ns = time.perf_counter_ns()

    return start_ns, end_ns


def choose_numbers(
    numbers: list[str],
    iterations: int,
    shuffle: bool,
    seed: int | None,
) -> list[str]:
    """Choose the effective recipient sequence."""

    effective = min(iterations, len(numbers))
    selected = numbers[:]

    if shuffle:
        rng = random.Random(seed)
        rng.shuffle(selected)

    return selected[:effective]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description=(
            "Collect raw host-only benchmark timings for a simulated local "
            "SMS enqueue path."
        )
    )

    parser.add_argument(
        "--numbers-file",
        required=True,
        type=Path,
        help="Text file with one +45XXXXXXXX number per line.",
    )

    parser.add_argument(
        "--iterations",
        type=int,
        default=DEFAULT_ITERATIONS,
        help=f"Measured iterations. Default: {DEFAULT_ITERATIONS}.",
    )

    parser.add_argument(
        "--message-size",
        type=int,
        default=DEFAULT_MESSAGE_SIZE,
        help=f"Synthetic message length in characters. "
             f"Default: {DEFAULT_MESSAGE_SIZE}.",
    )

    parser.add_argument(
        "--results-csv",
        type=Path,
        default=Path(build_default_output_name("benchmark_results", "csv")),
        help="Output CSV for per-iteration timings.",
    )

    parser.add_argument(
        "--queue-csv",
        type=Path,
        default=Path(build_default_output_name("simulated_outbox", "csv")),
        help="Output CSV for the simulated outbox workload.",
    )

    parser.add_argument(
        "--flush",
        action="store_true",
        help="Flush the simulated outbox file after each iteration.",
    )

    parser.add_argument(
        "--fsync",
        action="store_true",
        help="fsync() the simulated outbox file after each iteration.",
    )

    parser.add_argument(
        "--inter-iteration-sleep-ms",
        type=float,
        default=0.0,
        help=(
            "Sleep after each iteration, outside the timed block. "
            "Default: 0.0."
        ),
    )

    parser.add_argument(
        "--shuffle",
        action="store_true",
        help="Shuffle input numbers before selecting the effective subset.",
    )

    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for message generation and optional shuffling.",
    )

    return parser.parse_args()


def main() -> int:
    """Program entry point."""

    args = parse_args()

    if args.iterations <= 0:
        print("Error: --iterations must be > 0.", file=sys.stderr)
        return 1

    if args.inter_iteration_sleep_ms < 0:
        print(
            "Error: --inter-iteration-sleep-ms must be >= 0.",
            file=sys.stderr,
        )
        return 1

    try:
        numbers = load_numbers(args.numbers_file)
    except Exception as exc:
        print(f"Error while loading numbers: {exc}", file=sys.stderr)
        return 1

    selected_numbers = choose_numbers(
        numbers=numbers,
        iterations=args.iterations,
        shuffle=args.shuffle,
        seed=args.seed,
    )

    requested_iterations = args.iterations
    effective_iterations = len(selected_numbers)

    if effective_iterations == 0:
        print("Error: no usable iterations available.", file=sys.stderr)
        return 1

    if effective_iterations < requested_iterations:
        print(
            (
                "Requested iterations exceeded available numbers. "
                f"Falling back from {requested_iterations} to "
                f"{effective_iterations}."
            ),
            file=sys.stderr,
        )

    message_text = generate_message_text(
        size=args.message_size,
        seed=args.seed,
    )

    run_id = str(uuid.uuid4())
    started_utc = utc_now_iso()

    results_rows: list[dict[str, object]] = []

    queue_fieldnames = [
        "queue_id",
        "created_utc",
        "recipient",
        "message_text",
        "message_length",
    ]

    with args.queue_csv.open("w", encoding="utf-8", newline="") as queue_fh:
        queue_writer = csv.DictWriter(queue_fh, fieldnames=queue_fieldnames)
        maybe_write_header(queue_writer, queue_fh)

        for idx, recipient in enumerate(selected_numbers, start=1):
            error_text = ""
            status = "ok"
            start_ns = 0
            end_ns = 0
            elapsed_ns = 0
            elapsed_ms = 0.0

            try:
                start_ns, end_ns = timed_enqueue(
                    recipient=recipient,
                    message_text=message_text,
                    queue_writer=queue_writer,
                    queue_file=queue_fh,
                    do_flush=args.flush,
                    do_fsync=args.fsync,
                )
                elapsed_ns = end_ns - start_ns
                elapsed_ms = elapsed_ns / 1_000_000.0

            except Exception as exc:
                status = "error"
                end_ns = time.perf_counter_ns()

                if start_ns > 0:
                    elapsed_ns = end_ns - start_ns
                    elapsed_ms = elapsed_ns / 1_000_000.0

                error_text = repr(exc)

            results_rows.append(
                {
                    "run_id": run_id,
                    "started_utc": started_utc,
                    "iteration_index": idx,
                    "requested_iterations": requested_iterations,
                    "effective_iterations": effective_iterations,
                    "recipient": recipient,
                    "message_size": args.message_size,
                    "flush": int(args.flush),
                    "fsync": int(args.fsync),
                    "inter_iteration_sleep_ms":
                        args.inter_iteration_sleep_ms,
                    "shuffle": int(args.shuffle),
                    "seed": args.seed,
                    "start_ns": start_ns,
                    "end_ns": end_ns,
                    "elapsed_ns": elapsed_ns,
                    "elapsed_ms": f"{elapsed_ms:.6f}",
                    "status": status,
                    "error": error_text,
                }
            )

            if args.inter_iteration_sleep_ms > 0:
                time.sleep(args.inter_iteration_sleep_ms / 1000.0)

    results_fieldnames = [
        "run_id",
        "started_utc",
        "iteration_index",
        "requested_iterations",
        "effective_iterations",
        "recipient",
        "message_size",
        "flush",
        "fsync",
        "inter_iteration_sleep_ms",
        "shuffle",
        "seed",
        "start_ns",
        "end_ns",
        "elapsed_ns",
        "elapsed_ms",
        "status",
        "error",
    ]

    with args.results_csv.open("w", encoding="utf-8", newline="") as results_fh:
        results_writer = csv.DictWriter(
            results_fh,
            fieldnames=results_fieldnames,
        )
        results_writer.writeheader()
        results_writer.writerows(results_rows)

    ok_count = sum(row["status"] == "ok" for row in results_rows)
    err_count = sum(row["status"] == "error" for row in results_rows)

    print(f"Run ID              : {run_id}")
    print(f"Started UTC         : {started_utc}")
    print(f"Input numbers file  : {args.numbers_file}")
    print(f"Requested iterations: {requested_iterations}")
    print(f"Effective iterations: {effective_iterations}")
    print(f"Queue CSV           : {args.queue_csv}")
    print(f"Results CSV         : {args.results_csv}")
    print(f"Successful rows     : {ok_count}")
    print(f"Error rows          : {err_count}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
