#!/usr/bin/env python3
"""Receiver for the Bedwars state logger.

Listens for the batches state-logger.lua posts and appends them to a JSONL file, one
sample per line. Standard library only, so there is nothing to install before the first
recording session.

A sample arrives as nested JSON and is stored exactly as it arrived. Flattening and
vocabulary building happen at training time, not here: the recording is the expensive
thing to redo, so it keeps everything and decides nothing.

    python3 receiver.py                 listen on 127.0.0.1:8750, write to ./data
    python3 receiver.py --port 9000
    python3 receiver.py --stats run.jsonl    summarise a recording instead of listening

Bound to localhost because the only thing that should reach it is the game on this
machine.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Writer:
    """Appends samples to one file per session, and keeps counts for the console."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=True)
        self.handles: dict[str, object] = {}
        self.counts: Counter = Counter()
        self.started = time.time()
        self.last_report = time.time()

    def path_for(self, session: str) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(self.started))
        return self.directory / f"session-{stamp}-{session[:8]}.jsonl"

    def write(self, session: str, samples: list[dict]) -> None:
        handle = self.handles.get(session)
        if handle is None:
            path = self.path_for(session)
            handle = path.open("a", encoding="utf-8")
            self.handles[session] = handle
            print(f"[recv] new session {session[:8]} -> {path}")

        for sample in samples:
            # The session id travels with every row so that concatenated files can still be
            # split back apart, which matters once there are recordings from several days.
            sample["session"] = session
            handle.write(json.dumps(sample, separators=(",", ":")) + "\n")
        handle.flush()

        self.counts[session] += len(samples)
        self.report()

    def report(self) -> None:
        now = time.time()
        if now - self.last_report < 10:
            return
        self.last_report = now
        total = sum(self.counts.values())
        minutes = (now - self.started) / 60
        print(f"[recv] {total} samples over {minutes:.1f} min ({total / max(minutes, 0.01):.0f}/min)")

    def close(self) -> None:
        for handle in self.handles.values():
            handle.close()


class Handler(BaseHTTPRequestHandler):
    writer: Writer = None  # type: ignore[assignment]

    def _reply(self, code: int, body: str = "ok") -> None:
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:  # noqa: N802 - name fixed by the base class
        if self.path != "/ingest":
            return self._reply(404, "not found")

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"[recv] bad json: {exc}")
            return self._reply(400, "bad json")

        samples = body.get("samples") or []
        session = body.get("session") or "unknown"
        if samples:
            self.writer.write(session, samples)
        self._reply(200)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            return self._reply(200, "listening")
        self._reply(404, "not found")

    def log_message(self, *args) -> None:
        # The default handler prints a line per request, which at ten batches a minute is
        # noise that hides the summaries.
        pass


def summarise(path: Path) -> None:
    """Print what a recording actually contains, before anything is trained on it."""
    rows = 0
    with_enemy = 0
    attacking = 0
    moving = 0
    own = 0
    held: Counter = Counter()
    players: Counter = Counter()
    first = last = None

    with path.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            rows += 1
            first = first if first is not None else row.get("t")
            last = row.get("t", last)
            if row.get("enemy"):
                with_enemy += 1
            action = row.get("action") or {}
            if action.get("attack"):
                attacking += 1
            if abs(action.get("forward", 0)) > 0.1 or abs(action.get("right", 0)) > 0.1:
                moving += 1
            if row.get("held"):
                held[row["held"]] += 1
            if row.get("isSelf"):
                own += 1
            if row.get("player"):
                players[row["player"]] += 1

    if rows == 0:
        print("empty recording")
        return

    span = (last - first) if (first and last) else 0
    print(f"{path.name}: {rows} rows over {span / 60:.1f} min, {len(players)} players")
    print(f"  your own rows         : {own:6d} ({own / rows:.1%})")
    print(f"  with an enemy in view : {with_enemy:6d} ({with_enemy / rows:.1%})")
    # Attacking is only ever labelled on your own rows, so it is reported against those
    # rather than against the total - a swing rate of 2% reads as broken until you notice
    # the denominator included eleven other players whose swings are unknowable.
    print(f"  attacking (of yours)  : {attacking:6d} ({attacking / own:.1%})" if own else "  attacking             : no rows of your own")
    print(f"  moving                : {moving:6d} ({moving / rows:.1%})")
    print("  most held             : " + ", ".join(f"{k} {v}" for k, v in held.most_common(5)))
    print("  busiest players       : " + ", ".join(f"{k} {v}" for k, v in players.most_common(5)))
    # The number that decides whether this is worth training on. Combat is rare in a match,
    # and a policy cloned from mostly-walking data learns mostly to walk.
    if with_enemy / rows < 0.1:
        print("  NOTE: under 10% of rows have an enemy in view - record more fighting")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8750)
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "data")
    parser.add_argument("--stats", type=Path, help="summarise a recording and exit")
    args = parser.parse_args()

    if args.stats:
        summarise(args.stats)
        return 0

    writer = Writer(args.out)
    Handler.writer = writer
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[recv] listening on http://{args.host}:{args.port}/ingest -> {args.out}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[recv] stopping")
    finally:
        writer.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
