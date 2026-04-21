#!/usr/bin/env python3
"""SDG-Lab batch driver for the Meshy.ai pipeline.

Usage
-----
    python meshy_batch.py --config character_config.yaml --stage image-to-3d
    python meshy_batch.py --config character_config.yaml --stage rigging
    python meshy_batch.py --config character_config.yaml --stage animation
    python meshy_batch.py --config character_config.yaml --stage all
    python meshy_batch.py --config character_config.yaml --dry-run

Behavior
--------
* Reads ``character_config.yaml`` (schema: see the sample file).
* Loads the API key from ``$MESHY_API_KEY`` or ``./.meshy-api-key``
  (first non-empty, non-comment line).
* Walks ``characters`` + ``props``, running the selected stage(s).
* Writes output GLBs to ``output/{name}_{stage}.glb``.
* Persists intermediate task ids + download urls in
  ``output/.state.json`` so re-running resumes instead of re-billing.
* ``--dry-run`` skips *all* network calls and prints the plan only.

See also: GDD.md §6 (Meshy.ai 集成工作流).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Any, Optional

import yaml
from tqdm import tqdm

from meshy_client import MeshyClient, MeshyError

# ---------------------------------------------------------------------------
# Paths + logging
# ---------------------------------------------------------------------------

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR / "output"
STATE_PATH = OUTPUT_DIR / ".state.json"
API_KEY_FILE = SCRIPT_DIR / ".meshy-api-key"

STAGES = ("image-to-3d", "rigging", "animation")
STAGE_ALIASES = {
    "image": "image-to-3d",
    "image_to_3d": "image-to-3d",
    "rig": "rigging",
    "anim": "animation",
}

_log = logging.getLogger("meshy_batch")
if not _log.handlers:
    _handler = logging.StreamHandler(sys.stderr)
    _handler.setFormatter(
        logging.Formatter("[%(asctime)s] %(levelname)s meshy_batch: %(message)s")
    )
    _log.addHandler(_handler)
    _log.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Config types
# ---------------------------------------------------------------------------


@dataclass
class Entry:
    """A single character or prop from the config file."""

    name: str
    description: str
    kind: str  # "character" or "prop"
    priority: str = "P2"
    ref_image: Optional[str] = None
    animations: list[str] = field(default_factory=list)
    overrides: dict[str, Any] = field(default_factory=dict)

    @property
    def needs_rig(self) -> bool:
        return self.kind == "character"

    @property
    def needs_animation(self) -> bool:
        return self.kind == "character" and bool(self.animations)


@dataclass
class Config:
    defaults: dict[str, Any]
    entries: list[Entry]


def load_config(path: pathlib.Path) -> Config:
    with path.open("r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    defaults = dict(raw.get("defaults") or {})
    entries: list[Entry] = []
    for item in raw.get("characters") or []:
        entries.append(_entry_from(item, kind="character"))
    for item in raw.get("props") or []:
        entries.append(_entry_from(item, kind="prop"))
    return Config(defaults=defaults, entries=entries)


def _entry_from(item: dict[str, Any], *, kind: str) -> Entry:
    known = {"name", "description", "priority", "ref_image", "animations"}
    overrides = {k: v for k, v in item.items() if k not in known}
    return Entry(
        name=str(item["name"]),
        description=str(item.get("description", "")),
        kind=kind,
        priority=str(item.get("priority", "P2")),
        ref_image=item.get("ref_image"),
        animations=list(item.get("animations") or []),
        overrides=overrides,
    )


# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------


def load_api_key() -> Optional[str]:
    """Look up the Meshy API key, preferring the env var.

    Returns ``None`` if nothing is configured — callers should treat
    that as fatal unless ``--dry-run`` is set.
    """
    env = os.environ.get("MESHY_API_KEY", "").strip()
    if env:
        return env
    if API_KEY_FILE.is_file():
        for line in API_KEY_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                # Support both `msy-...` and `MESHY_API_KEY=msy-...` forms.
                if "=" in line and line.split("=", 1)[0].strip().upper() == "MESHY_API_KEY":
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
                return line
    return None


# ---------------------------------------------------------------------------
# State (resume support)
# ---------------------------------------------------------------------------


def load_state() -> dict[str, Any]:
    if STATE_PATH.is_file():
        try:
            return json.loads(STATE_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            _log.warning("state file corrupt, starting fresh: %s", exc)
    return {}


def save_state(state: dict[str, Any]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(
        json.dumps(state, indent=2, sort_keys=True), encoding="utf-8"
    )


def _entry_state(state: dict[str, Any], name: str) -> dict[str, Any]:
    return state.setdefault(name, {})


# ---------------------------------------------------------------------------
# Stage runners
# ---------------------------------------------------------------------------


def _merge_options(defaults: dict[str, Any], entry: Entry) -> dict[str, Any]:
    """Meshy-payload-only options for image-to-3d.

    Drops our own keys (``style_prompt``, ``rig_height_meters``) so they
    do not leak into the Meshy request body.
    """
    merged: dict[str, Any] = {}
    for key, value in defaults.items():
        if key in {"style_prompt", "rig_height_meters"}:
            continue
        merged[key] = value
    merged.update(entry.overrides)
    return merged


def _texture_prompt(defaults: dict[str, Any], entry: Entry) -> str:
    style = str(defaults.get("style_prompt") or "").strip()
    desc = entry.description.strip()
    if style and desc:
        return f"{desc}. {style}"
    return desc or style


def _output_path(name: str, stage: str) -> pathlib.Path:
    return OUTPUT_DIR / f"{name}_{stage}.glb"


def run_image_to_3d(
    client: Optional[MeshyClient],
    entry: Entry,
    defaults: dict[str, Any],
    state: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    entry_state = _entry_state(state, entry.name)
    if entry_state.get("image_to_3d", {}).get("status") == "done":
        _log.info("[%s] image-to-3d already done, skipping", entry.name)
        return

    ref_image = entry.ref_image
    if not ref_image:
        _log.warning("[%s] no ref_image, skipping image-to-3d", entry.name)
        return

    options = _merge_options(defaults, entry)
    options.setdefault("texture_prompt", _texture_prompt(defaults, entry))

    if dry_run:
        print(
            f"[dry-run] POST image-to-3d  name={entry.name}  "
            f"ref={ref_image}  options={options}"
        )
        return

    assert client is not None
    task_id = client.image_to_3d(ref_image, **options)
    entry_state["image_to_3d"] = {"task_id": task_id, "status": "submitted"}
    save_state(state)

    task = client.wait_for(task_id, kind="image-to-3d")
    url = client.pick_model_url(task, preferred="glb")
    out = _output_path(entry.name, "image-to-3d")
    client.download(url, str(out))

    entry_state["image_to_3d"] = {
        "task_id": task_id,
        "status": "done",
        "model_url": url,
        "output": str(out),
    }
    save_state(state)
    _log.info("[%s] image-to-3d -> %s", entry.name, out)


def run_rigging(
    client: Optional[MeshyClient],
    entry: Entry,
    defaults: dict[str, Any],
    state: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    if not entry.needs_rig:
        _log.info("[%s] prop, skipping rigging", entry.name)
        return

    entry_state = _entry_state(state, entry.name)
    if entry_state.get("rigging", {}).get("status") == "done":
        _log.info("[%s] rigging already done, skipping", entry.name)
        return

    i23_state = entry_state.get("image_to_3d") or {}
    input_task_id = i23_state.get("task_id")
    if not input_task_id:
        _log.warning(
            "[%s] no image_to_3d task in state; run --stage image-to-3d first",
            entry.name,
        )
        if not dry_run:
            return

    height = float(defaults.get("rig_height_meters", 1.7))

    if dry_run:
        print(
            f"[dry-run] POST rigging  name={entry.name}  "
            f"input_task_id={input_task_id}  height_meters={height}"
        )
        return

    assert client is not None
    task_id = client.rigging(input_task_id, is_task_id=True, height_meters=height)
    entry_state["rigging"] = {"task_id": task_id, "status": "submitted"}
    save_state(state)

    task = client.wait_for(task_id, kind="rigging")
    url = client.pick_model_url(task, preferred="glb")
    out = _output_path(entry.name, "rigging")
    client.download(url, str(out))

    entry_state["rigging"] = {
        "task_id": task_id,
        "status": "done",
        "model_url": url,
        "output": str(out),
    }
    save_state(state)
    _log.info("[%s] rigging -> %s", entry.name, out)


def run_animation(
    client: Optional[MeshyClient],
    entry: Entry,
    defaults: dict[str, Any],
    state: dict[str, Any],
    *,
    dry_run: bool,
) -> None:
    if not entry.needs_animation:
        _log.info("[%s] no animations requested, skipping", entry.name)
        return

    entry_state = _entry_state(state, entry.name)
    rig_state = entry_state.get("rigging") or {}
    rig_task_id = rig_state.get("task_id")
    if not rig_task_id:
        _log.warning(
            "[%s] no rigging task in state; run --stage rigging first",
            entry.name,
        )
        if not dry_run:
            return

    anim_state = entry_state.setdefault("animation", {})
    clips_state: dict[str, Any] = anim_state.setdefault("clips", {})

    for anim in entry.animations:
        if clips_state.get(anim, {}).get("status") == "done":
            continue
        action_id = _action_id_for(anim, defaults)

        if dry_run:
            print(
                f"[dry-run] POST animations  name={entry.name}  "
                f"rig_task_id={rig_task_id}  anim={anim}  "
                f"action_id={action_id}"
            )
            continue

        assert client is not None
        if action_id is None:
            _log.warning(
                "[%s] animation %r has no action_id mapping; skipping",
                entry.name,
                anim,
            )
            clips_state[anim] = {"status": "skipped", "reason": "no action_id"}
            save_state(state)
            continue

        task_id = client.animation(rig_task_id, action_id=action_id)
        clips_state[anim] = {
            "task_id": task_id,
            "action_id": action_id,
            "status": "submitted",
        }
        save_state(state)

        task = client.wait_for(task_id, kind="animations")
        url = client.pick_model_url(task, preferred="glb")
        out = _output_path(f"{entry.name}_{anim}", "animation")
        client.download(url, str(out))

        clips_state[anim] = {
            "task_id": task_id,
            "action_id": action_id,
            "status": "done",
            "model_url": url,
            "output": str(out),
        }
        save_state(state)
        _log.info("[%s] animation[%s] -> %s", entry.name, anim, out)


def _action_id_for(anim_name: str, defaults: dict[str, Any]) -> Optional[int]:
    """Resolve an animation name -> Meshy action_id.

    Meshy exposes animations via numeric IDs from its Animation Library.
    A ``animation_map`` key in ``defaults`` (or ``entry.overrides``) can
    supply the mapping; in Phase 0 we ship without it, so callers either
    fill the map later or pass ``action_id`` directly as an override.
    """
    mapping = defaults.get("animation_map") or {}
    value = mapping.get(anim_name)
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


_STAGE_RUNNERS = {
    "image-to-3d": run_image_to_3d,
    "rigging": run_rigging,
    "animation": run_animation,
}


def resolve_stages(requested: str) -> list[str]:
    requested = STAGE_ALIASES.get(requested, requested)
    if requested == "all":
        return list(STAGES)
    if requested not in STAGES:
        raise SystemExit(
            f"unknown stage {requested!r}; expected one of: "
            f"{', '.join(STAGES)} or 'all'"
        )
    return [requested]


def filter_entries(
    entries: list[Entry],
    *,
    only: Optional[list[str]],
    priority: Optional[list[str]],
) -> list[Entry]:
    result = entries
    if only:
        want = set(only)
        result = [e for e in result if e.name in want]
    if priority:
        want_p = {p.upper() for p in priority}
        result = [e for e in result if e.priority.upper() in want_p]
    return result


def run(args: argparse.Namespace) -> int:
    config_path = pathlib.Path(args.config).resolve()
    if not config_path.is_file():
        _log.error("config file not found: %s", config_path)
        return 2

    config = load_config(config_path)
    if not config.entries:
        _log.warning("config has no characters or props")
        return 0

    stages = resolve_stages(args.stage)
    entries = filter_entries(
        config.entries, only=args.only, priority=args.priority
    )
    if not entries:
        _log.warning("no entries matched filters")
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    state = load_state()

    client: Optional[MeshyClient] = None
    if not args.dry_run:
        api_key = load_api_key()
        if not api_key:
            _log.error(
                "MESHY_API_KEY not set and %s missing; "
                "see .meshy-api-key.example (or pass --dry-run)",
                API_KEY_FILE,
            )
            return 2
        client = MeshyClient(api_key)

    _log.info(
        "running stages=%s entries=%d dry_run=%s",
        stages,
        len(entries),
        args.dry_run,
    )

    failures: list[tuple[str, str, str]] = []  # (entry, stage, message)

    for stage in stages:
        runner = _STAGE_RUNNERS[stage]
        iterator = tqdm(
            entries,
            desc=f"stage={stage}",
            disable=args.dry_run or not sys.stderr.isatty(),
        )
        for entry in iterator:
            try:
                runner(
                    client,
                    entry,
                    config.defaults,
                    state,
                    dry_run=args.dry_run,
                )
            except MeshyError as exc:
                _log.error("[%s] %s failed: %s", entry.name, stage, exc)
                failures.append((entry.name, stage, str(exc)))
                if args.fail_fast:
                    break
        if failures and args.fail_fast:
            break

    if failures:
        _log.error("%d failure(s):", len(failures))
        for name, stage, msg in failures:
            _log.error("  - %s / %s: %s", name, stage, msg)
        return 1

    _log.info("done")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="meshy_batch",
        description=(
            "Batch-drive the Meshy.ai REST API for SDG-Lab characters "
            "and props. See GDD.md §6 for the full workflow."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python meshy_batch.py --config character_config.yaml --stage image-to-3d\n"
            "  python meshy_batch.py --config character_config.yaml --stage all --dry-run\n"
            "  python meshy_batch.py --config character_config.yaml --stage rigging --only kaede\n"
        ),
    )
    parser.add_argument(
        "--config",
        required=True,
        help="Path to character_config.yaml",
    )
    parser.add_argument(
        "--stage",
        default="all",
        help=(
            "Stage to run: image-to-3d | rigging | animation | all "
            "(default: all)"
        ),
    )
    parser.add_argument(
        "--only",
        nargs="*",
        default=None,
        help="Restrict to these entry names (space separated)",
    )
    parser.add_argument(
        "--priority",
        nargs="*",
        default=None,
        help="Restrict to these priority tiers (e.g. P0 P1)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the plan without calling the Meshy API",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop at the first failure instead of continuing",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable DEBUG logging",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.verbose:
        _log.setLevel(logging.DEBUG)
        logging.getLogger("meshy_client").setLevel(logging.DEBUG)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
