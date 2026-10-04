#!/usr/bin/env python3
"""Behaviour cloning on recorded Bedwars play.

Trains one network with four heads to predict what a player did from what they could see:
where they moved, how they turned, whether they jumped, and whether they attacked. No
reinforcement learning - this is supervised learning on demonstrations, which is the only
thing that fits in hours rather than weeks when there is no simulator to explore in.

    python3 train.py data/*.jsonl                 train and save model.pt
    python3 train.py data/*.jsonl --epochs 40

Two decisions worth knowing about, because they are what make the reported numbers mean
anything:

Chronological split. Frames ten times a second are almost copies of their neighbours, so a
random train/test split puts near-duplicates on both sides and reports a score that has
nothing to do with generalisation. The last fifth of the recording is held out instead, in
time order.

Baselines printed next to every head. A model that predicts the average movement, or
always says 'not attacking', will score well on its own terms - 77% accuracy on attack
sounds good until you notice that never attacking scores 77%. Each head is therefore
reported against the trivial predictor it has to beat, and a head that does not beat it
has learned nothing whatever its loss curve looks like.

Attacking is supervised on your own rows only: another player's swing is an animation
rather than a physical fact, so those rows carry no label and are masked out of that head.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from torch import nn

# Held items are a category, and the long tail of them is noise, so the common ones get a
# slot each and everything else shares one.
HELD_SLOTS = 16

def number(value, default: float = 0.0) -> float:
    """A finite float, whatever the recording put there.

    Roblox's JSON encoder writes a NaN as {'t': 'numeric', 'v': 'nan'} rather than failing,
    so a value that should be a float arrives as a dict. One such field in a row would
    otherwise take the whole array with it.
    """
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) else default
    return default


NUMERIC = [
    "health_frac",
    "grounded",
    "speed",
    "vel_y",
    "pitch",
    "enemy_present",
    "enemy_x",
    "enemy_y",
    "enemy_z",
    "enemy_dist",
    "enemy_health",
    "enemy_visible",
    "enemy_closing",
    # How far off the enemy your crosshair is, horizontally and vertically. Turning is
    # almost a function of exactly this - you turn to cancel it - but from x, y and z the
    # network has to discover atan2 before it can use it. The first run's look head was
    # worse than predicting the average, and this is the feature it was missing.
    "aim_yaw_error",
    "aim_pitch_error",
]

# How many frames of the past go into each example. Half a second at 10 Hz: enough for
# 'already turning' and 'mid swing' to be visible, which a single frame cannot show.
HISTORY = 5


def load_csv(path: Path) -> list[dict]:
    """Rows from the in-game TrainingData module.

    Shaped into the same dicts the JSONL receiver produces, so both sources train together
    and contributed recordings need no separate path. An empty column is a value that was
    not knowable - an observed player's swing - and stays None rather than becoming a zero
    that would read as 'did not attack'.
    """
    rows: list[dict] = []
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            def get(key):
                value = raw.get(key, "")
                return None if value == "" else float(value)

            enemy = None
            if get("enemy"):
                enemy = {
                    "x": get("ex"), "y": get("ey"), "z": get("ez"),
                    "dist": get("edist"), "health": get("ehealth"),
                    "visible": bool(get("evisible")), "closing": get("eclosing"),
                }
            attack, sprint = get("attack"), get("sprint")
            rows.append({
                "t": get("t"), "dt": get("dt"),
                "player": raw.get("actor"), "session": path.name,
                "isSelf": bool(get("is_self")),
                "health": get("health"), "maxHealth": get("max_health"),
                "grounded": bool(get("grounded")), "speed": get("speed"),
                "velY": get("vel_y"), "pitch": get("pitch"),
                "held": raw.get("held") or None, "enemy": enemy,
                "action": {
                    "forward": get("forward"), "right": get("right"),
                    "dYaw": get("dyaw"), "dPitch": get("dpitch"),
                    "jump": bool(get("jump")),
                    "attack": None if attack is None else bool(attack),
                    "sprint": None if sprint is None else bool(sprint),
                },
            })
    return rows


def load(paths: list[Path]) -> tuple[list[dict], Counter]:
    rows: list[dict] = []
    held: Counter = Counter()
    for path in paths:
        # Detected by what the file starts with rather than by its extension: the in-game
        # module writes data.txt, and a contributor renaming it should not change how it
        # is read.
        with path.open(encoding="utf-8") as probe:
            header = probe.readline()
        if header.startswith("t,dt,actor"):
            for row in load_csv(path):
                rows.append(row)
                if row.get("held"):
                    held[row["held"]] += 1
            continue
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not row.get("action"):
                    continue
                rows.append(row)
                if row.get("held"):
                    held[row["held"]] += 1
    rows.sort(key=lambda r: r.get("t", 0.0))
    return rows, held


def featurise(rows: list[dict], vocab: dict[str, int]) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    n = len(rows)
    x = np.zeros((n, len(NUMERIC) + HELD_SLOTS + 1), dtype=np.float32)
    y_move = np.zeros((n, 2), dtype=np.float32)
    y_look = np.zeros((n, 2), dtype=np.float32)
    y_jump = np.zeros(n, dtype=np.float32)
    y_attack = np.zeros(n, dtype=np.float32)
    mask_attack = np.zeros(n, dtype=np.float32)

    for i, row in enumerate(rows):
        enemy = row.get("enemy") or {}
        max_health = row.get("maxHealth") or 100.0
        values = [
            number(row.get("health")) / max(number(max_health, 100.0), 1.0),
            1.0 if row.get("grounded") else 0.0,
            number(row.get("speed")),
            number(row.get("velY")),
            number(row.get("pitch")),
            1.0 if enemy else 0.0,
            number(enemy.get("x")),
            number(enemy.get("y")),
            number(enemy.get("z")),
            number(enemy.get("dist")),
            number(enemy.get("health")) / 100.0,
            1.0 if enemy.get("visible") else 0.0,
            number(enemy.get("closing")),
            math.atan2(number(enemy.get("x")), max(number(enemy.get("z")), 1e-3)) if enemy else 0.0,
            math.atan2(
                number(enemy.get("y")),
                max(math.hypot(number(enemy.get("x")), number(enemy.get("z"))), 1e-3),
            )
            if enemy
            else 0.0,
        ]
        x[i, : len(NUMERIC)] = values

        slot = vocab.get(row.get("held") or "", HELD_SLOTS - 1)
        x[i, len(NUMERIC) + slot] = 1.0
        # Whether the row is your own is a feature as well as a mask: your rows carry a
        # hand the others do not, and the network should be allowed to know which it is
        # looking at rather than inferring it from a missing one-hot.
        x[i, -1] = 1.0 if row.get("isSelf") else 0.0

        action = row["action"]
        y_move[i] = (number(action.get("forward")), number(action.get("right")))

        # Turning is divided by the frame time, so the target is a rate rather than a
        # quantity that changes meaning whenever the sampler runs late.
        dt = max(number(row.get("dt"), 0.1), 1e-3)
        y_look[i] = (number(action.get("dYaw")) / dt, number(action.get("dPitch")) / dt)

        y_jump[i] = 1.0 if action.get("jump") else 0.0

        #[[ Attacking is labelled on your own rows and only yours.
        #
        # Keyed on isSelf rather than on the field being present, which also recovers the
        # first recording: the logger wrote the key only when the mouse was down, so a
        # missing one on a row of yours is a frame you were not attacking. Testing for
        # presence would have thrown every negative away and trained a head that has never
        # seen anyone decline to swing.
        if row.get("isSelf"):
            y_attack[i] = 1.0 if action.get("attack") else 0.0
            mask_attack[i] = 1.0

    return x, {
        "move": y_move,
        "look": y_look,
        "jump": y_jump,
        "attack": y_attack,
        "attack_mask": mask_attack,
    }


def stack_history(rows: list[dict], x: np.ndarray) -> np.ndarray:
    """Widen each example to include the frames before it, per actor.

    A single frame cannot express 'already turning', 'mid swing' or 'running away', and the
    first run's look and attack heads both failed for want of exactly that. Each row is
    extended with its own actor's previous frames, oldest first.

    Grouped by session and player so that one actor's past is never spliced onto another's,
    and a frame with no history repeats its own - padding with zeros would say 'was
    standing still a moment ago', which is a different claim and a false one.
    """
    width = x.shape[1]
    out = np.zeros((len(rows), width * HISTORY), dtype=np.float32)
    seen: dict[tuple, list[int]] = {}

    for i, row in enumerate(rows):
        key = (row.get("session"), row.get("player"))
        past = seen.setdefault(key, [])
        for step in range(HISTORY):
            # step 0 is now, step 1 is the frame before, and so on back.
            source = past[-step] if step and len(past) >= step else i
            out[i, (HISTORY - 1 - step) * width : (HISTORY - step) * width] = x[source]
        past.append(i)
        if len(past) > HISTORY:
            past.pop(0)

    return out


class Policy(nn.Module):
    def __init__(self, n_features: int, width: int = 256):
        super().__init__()
        self.trunk = nn.Sequential(
            nn.Linear(n_features, width),
            nn.ReLU(),
            nn.Linear(width, width),
            nn.ReLU(),
        )
        # Movement is bounded by construction, so the head is too - a tanh cannot predict
        # a run speed that does not exist.
        self.move = nn.Sequential(nn.Linear(width, 2), nn.Tanh())
        self.look = nn.Linear(width, 2)
        self.jump = nn.Linear(width, 1)
        self.attack = nn.Linear(width, 1)

    def forward(self, x):
        h = self.trunk(x)
        return self.move(h), self.look(h), self.jump(h).squeeze(-1), self.attack(h).squeeze(-1)


def report(name: str, pred: np.ndarray, truth: np.ndarray, baseline: np.ndarray, kind: str) -> None:
    if kind == "regression":
        mse = float(np.mean((pred - truth) ** 2))
        base = float(np.mean((baseline - truth) ** 2))
        gain = (1 - mse / base) * 100 if base > 0 else 0.0
        verdict = "learned something" if gain > 5 else "NO BETTER THAN THE BASELINE"
        print(f"  {name:8s} mse {mse:9.4f} | predicting the mean {base:9.4f} | {gain:+5.1f}%  {verdict}")
    else:
        acc = float(np.mean((pred > 0.5) == (truth > 0.5)))
        base = float(max(np.mean(truth > 0.5), 1 - np.mean(truth > 0.5)))
        gain = (acc - base) * 100
        verdict = "learned something" if gain > 1 else "NO BETTER THAN ALWAYS GUESSING THE COMMON CASE"
        print(f"  {name:8s} acc {acc:9.3f} | always the common case {base:9.3f} | {gain:+5.1f}pp  {verdict}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch", type=int, default=512)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "model.pt")
    args = parser.parse_args()

    rows, held_counts = load(args.paths)
    if len(rows) < 1000:
        print(f"only {len(rows)} usable rows - record more before training")
        return 1

    vocab = {name: i for i, (name, _) in enumerate(held_counts.most_common(HELD_SLOTS - 1))}
    x, y = featurise(rows, vocab)
    x = stack_history(rows, x)

    # Held out in time order, not at random: neighbouring frames are near-duplicates and a
    # random split would score the model on rows it has effectively already seen.
    split = int(len(x) * 0.8)
    x_train, x_val = x[:split], x[split:]
    print(f"{len(rows)} rows | {len(x_train)} train, {len(x_val)} validation (chronological)")
    print(f"held vocabulary: {', '.join(list(vocab)[:8])}{'...' if len(vocab) > 8 else ''}")

    mean = x_train.mean(axis=0)
    std = x_train.std(axis=0)
    std[std < 1e-6] = 1.0
    x_train = (x_train - mean) / std
    x_val = (x_val - mean) / std

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = Policy(x.shape[1]).to(device)
    optimiser = torch.optim.Adam(model.parameters(), lr=args.lr)

    tensors = {k: torch.tensor(v[:split], device=device) for k, v in y.items()}
    xt = torch.tensor(x_train, device=device)
    val_x = torch.tensor(x_val, device=device)

    # Look targets are standardised for training only. Turn rates have a heavy tail, and a
    # raw-scale regression lets the rare fast flick dominate every gradient.
    look_mean = tensors["look"].mean(dim=0)
    look_std = tensors["look"].std(dim=0).clamp(min=1e-6)

    mse = nn.MSELoss()
    huber = nn.SmoothL1Loss()
    bce = nn.BCEWithLogitsLoss()
    n = len(xt)

    for epoch in range(1, args.epochs + 1):
        model.train()
        order = torch.randperm(n, device=device)
        total = 0.0

        for start in range(0, n, args.batch):
            idx = order[start : start + args.batch]
            move, look, jump, attack = model(xt[idx])

            loss = mse(move, tensors["move"][idx])
            # Huber rather than squared error: a flick is ten times a normal turn and
            # squared error spends the whole gradient on the rare ones.
            loss = loss + huber(look, (tensors["look"][idx] - look_mean) / look_std)
            loss = loss + bce(jump, tensors["jump"][idx])

            # Only rows with a real label contribute to the attack head; the rest would
            # otherwise teach it that nobody ever swings.
            m = tensors["attack_mask"][idx]
            if m.sum() > 0:
                per_row = nn.functional.binary_cross_entropy_with_logits(
                    attack, tensors["attack"][idx], reduction="none"
                )
                loss = loss + (per_row * m).sum() / m.sum()

            optimiser.zero_grad()
            loss.backward()
            optimiser.step()
            total += float(loss.detach()) * len(idx)

        if epoch % 5 == 0 or epoch == args.epochs:
            print(f"epoch {epoch:3d}  train loss {total / n:.4f}")

    model.eval()
    with torch.no_grad():
        move, look, jump, attack = model(val_x)
        move = move.cpu().numpy()
        look = (look * look_std + look_mean).cpu().numpy()
        jump = torch.sigmoid(jump).cpu().numpy()
        attack = torch.sigmoid(attack).cpu().numpy()

    print("\nvalidation, against the trivial predictor each head has to beat:")
    truth_move = y["move"][split:]
    truth_look = y["look"][split:]
    report("move", move, truth_move, np.tile(y["move"][:split].mean(axis=0), (len(truth_move), 1)), "regression")
    report("look", look, truth_look, np.tile(y["look"][:split].mean(axis=0), (len(truth_look), 1)), "regression")
    report("jump", jump, y["jump"][split:], np.zeros(len(jump)), "binary")

    val_mask = y["attack_mask"][split:] > 0
    if val_mask.sum() > 50:
        report("attack", attack[val_mask], y["attack"][split:][val_mask], np.zeros(int(val_mask.sum())), "binary")
    else:
        print(f"  attack   only {int(val_mask.sum())} labelled rows held out - record more of your own play")

    # Combat is the subtask being cloned, and a score averaged over a walk across the map
    # hides whether any of it was learned.
    fighting = (y["move"][split:] is not None) & (x[split:, NUMERIC.index("enemy_visible")] != 0)
    if fighting.sum() > 50:
        print(f"\nwith an enemy visible ({int(fighting.sum())} rows):")
        report("move", move[fighting], truth_move[fighting], np.tile(y["move"][:split].mean(axis=0), (int(fighting.sum()), 1)), "regression")
        report("look", look[fighting], truth_look[fighting], np.tile(y["look"][:split].mean(axis=0), (int(fighting.sum()), 1)), "regression")

    torch.save(
        {
            "state": model.state_dict(),
            "mean": mean,
            "std": std,
            "vocab": vocab,
            "look_mean": look_mean.cpu().numpy(),
            "look_std": look_std.cpu().numpy(),
            "numeric": NUMERIC,
            "held_slots": HELD_SLOTS,
        },
        args.out,
    )
    print(f"\nsaved {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
