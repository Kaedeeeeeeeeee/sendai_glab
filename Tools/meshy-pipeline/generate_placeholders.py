#!/usr/bin/env python3
"""One-off Phase 2 starter: generate 5 placeholder characters via Meshy.

Called by:   python Tools/meshy-pipeline/generate_placeholders.py
Outputs:     Tools/meshy-pipeline/output/{name}.glb
             Tools/meshy-pipeline/output/{name}.usdz  (if Meshy returns one)

Key source:  Tools/meshy-pipeline/.meshy-api-key  (gitignored, never echoed)

Design notes
------------
- Uses text-to-3d v2 ``preview`` mode — the cheap/fast tier. ``refine`` is
  not used because this batch is placeholder quality.
- Requests ``target_formats=["glb", "usdz"]`` so Meshy can hand us USDZ
  directly and skip the local GLB → USDZ conversion (``usdzconvert`` is
  not available on this machine and ``pxr``/``usd-core`` is not installed).
- Serial (not concurrent) to respect Meshy rate limits and make logs
  readable. ~5-10 minutes wall-clock for 5 characters.
- Idempotent: skips a character if its GLB already exists on disk.
- Writes a per-character JSON record alongside each GLB for the log.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

from meshy_client import MeshyClient, MeshyError, MeshyTaskFailed, MeshyTimeout  # noqa: E402

# ---------------------------------------------------------------------------
# Character prompts (Phase 2 placeholder batch).
# ---------------------------------------------------------------------------

PROMPTS: dict[str, str] = {
    "player_male": (
        "A cheerful middle-school boy in a Japanese school uniform, "
        "chibi anime style, 3-head proportion, casual backpack, cute, clean topology"
    ),
    "player_female": (
        "A cheerful middle-school girl in a Japanese school uniform with sailor-style collar, "
        "chibi anime style, 3-head proportion, cute, clean topology"
    ),
    "kaede": (
        "A young female scientist named Kaede in a lab coat, "
        "chibi anime style, 3-head proportion, short brown hair, intellectual, game-ready"
    ),
    "teacher": (
        "A friendly male science teacher in casual jacket, "
        "chibi anime style, 3-head proportion, glasses, holding a clipboard, game-ready"
    ),
    "researcher_a": (
        "A female researcher in lab coat with a headset, "
        "chibi anime style, 3-head proportion, focused expression, game-ready"
    ),
}

# Meshy text-to-3d kwargs forwarded verbatim. Keep conservative — this is
# placeholder-tier, we want speed, not polish.
#
# NOTE: v2 text-to-3d (preview mode) only accepts ``art_style="realistic"``
# as of 2026-04-22 (confirmed empirically; Meshy returns 400 otherwise).
# The chibi / anime look is therefore driven entirely by the prompt. Refined
# style control would need a refine-mode pass or image-to-3d with a ref.
MESHY_OPTIONS: dict[str, object] = {
    "art_style": "realistic",
    "target_formats": ["glb", "usdz"],
}

POLL_INTERVAL_S = 10
TASK_TIMEOUT_S = 600   # 10 minutes per task — generous for preview tier.


# ---------------------------------------------------------------------------
# Record model
# ---------------------------------------------------------------------------

def record_path(out_dir: Path, name: str) -> Path:
    return out_dir / f"{name}.json"


def write_record(out_dir: Path, name: str, payload: dict) -> None:
    record_path(out_dir, name).write_text(json.dumps(payload, indent=2, sort_keys=True))


def format_size(path: Path) -> str:
    if not path.exists():
        return "-"
    size = path.stat().st_size
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.2f} MB"
    return f"{size / 1024:.1f} KB"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    key_path = HERE / ".meshy-api-key"
    if not key_path.is_file():
        print(f"[fatal] missing {key_path}", file=sys.stderr)
        return 2
    api_key = key_path.read_text().strip()
    if not api_key:
        print(f"[fatal] {key_path} is empty", file=sys.stderr)
        return 2

    client = MeshyClient(api_key=api_key)
    out_dir = HERE / "output"
    out_dir.mkdir(exist_ok=True)

    results: list[dict] = []
    t_start = time.monotonic()

    for name, prompt in PROMPTS.items():
        glb_path = out_dir / f"{name}.glb"
        usdz_path = out_dir / f"{name}.usdz"

        if glb_path.exists():
            print(f"[skip] {name}: GLB already at {glb_path.name} ({format_size(glb_path)})")
            results.append({
                "name": name,
                "status": "skipped-existing",
                "glb": str(glb_path),
                "glb_size": format_size(glb_path),
                "usdz": str(usdz_path) if usdz_path.exists() else None,
                "usdz_size": format_size(usdz_path) if usdz_path.exists() else None,
            })
            continue

        print(f"[start] {name}: submitting preview task...")
        task_started = time.monotonic()
        try:
            task_id = client.text_to_3d(prompt=prompt, mode="preview", **MESHY_OPTIONS)
        except MeshyError as exc:
            print(f"[fail] {name}: submit error: {exc}")
            results.append({"name": name, "status": "submit-error", "error": str(exc)})
            continue

        print(f"[start] {name}: task_id={task_id}, polling...")
        try:
            result = client.wait_for(
                task_id,
                kind="text-to-3d",
                poll_interval=POLL_INTERVAL_S,
                timeout=TASK_TIMEOUT_S,
            )
        except MeshyTaskFailed as exc:
            print(f"[fail] {name}: task failed: {exc}")
            results.append({"name": name, "status": "task-failed", "task_id": task_id, "error": str(exc)})
            continue
        except MeshyTimeout as exc:
            print(f"[fail] {name}: task timed out: {exc}")
            results.append({"name": name, "status": "timeout", "task_id": task_id, "error": str(exc)})
            continue

        elapsed = time.monotonic() - task_started
        model_urls = result.get("model_urls") or {}
        glb_url = model_urls.get("glb")
        usdz_url = model_urls.get("usdz")

        if not glb_url:
            print(f"[fail] {name}: no GLB url in result (keys={list(model_urls)})")
            results.append({
                "name": name,
                "status": "no-model-url",
                "task_id": task_id,
                "model_urls_keys": list(model_urls),
            })
            continue

        try:
            client.download(glb_url, str(glb_path))
        except MeshyError as exc:
            print(f"[fail] {name}: GLB download error: {exc}")
            results.append({
                "name": name,
                "status": "download-error",
                "task_id": task_id,
                "error": str(exc),
            })
            continue

        usdz_ok = False
        usdz_err: str | None = None
        if usdz_url:
            try:
                client.download(usdz_url, str(usdz_path))
                usdz_ok = True
            except MeshyError as exc:
                usdz_err = str(exc)
                print(f"[warn] {name}: USDZ download failed (GLB ok): {exc}")
        else:
            print(f"[warn] {name}: Meshy returned no USDZ url (keys={list(model_urls)})")

        record = {
            "name": name,
            "status": "ok",
            "task_id": task_id,
            "elapsed_s": round(elapsed, 1),
            "glb": str(glb_path),
            "glb_size": format_size(glb_path),
            "usdz": str(usdz_path) if usdz_ok else None,
            "usdz_size": format_size(usdz_path) if usdz_ok else None,
            "usdz_error": usdz_err,
            "model_urls_keys": list(model_urls),
        }
        results.append(record)
        write_record(out_dir, name, record)
        print(
            f"[done] {name}: GLB={format_size(glb_path)}"
            + (f", USDZ={format_size(usdz_path)}" if usdz_ok else ", USDZ=missing")
            + f", {elapsed:.1f}s"
        )

    total = time.monotonic() - t_start
    print()
    print("=" * 60)
    print(f"Batch complete: {len(results)} characters processed in {total:.1f}s")
    print("=" * 60)
    for r in results:
        glb = r.get("glb_size", "-")
        usdz = r.get("usdz_size") or "-"
        print(f"  {r['name']:15s} status={r['status']:18s} glb={glb:10s} usdz={usdz}")

    summary_path = out_dir / "_batch_summary.json"
    summary_path.write_text(json.dumps(results, indent=2, sort_keys=True))
    print(f"\nSummary: {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
