"""Downscale and repack every texture image currently loaded in Blender.

Phase 11 brings PLATEAU facade JPGs through the pipeline. A single LOD2
texture is often 2 048×2 048 px (some up to 4 K) because PLATEAU ships
photogrammetric wall captures at full resolution. Multiplying that by
~1 065 images across the 5-tile corridor would balloon bundle size
from ~6 MB to ~300 MB and blow through GPU texture memory budgets
on-device.

This module walks `bpy.data.images`, scales each in-place to
`TARGET_SIDE`×`TARGET_SIDE`, and repacks the result as JPEG at
`JPEG_QUALITY` inside the .blend file. When Blender later exports
the USD, it writes those packed JPEGs into the USDZ archive, so the
shipped asset stays small.

It's deliberately a standalone helper (not an inner function of the
split script) so:
  - the split script stays focused on geometry + snap logic;
  - other pipelines (glb_to_usdz.py, future terrain texture paths)
    can import and reuse it;
  - it's trivially testable by running it against any .blend file.

Idempotency: each processed image is tagged in
`image["sdg_lab_downscaled"]` so a rerun is a no-op. This matters
because the split script may call us after multiple GLB imports
share state in pathological edge cases.

Usage (from another Blender Python script):

    from pathlib import Path
    import sys
    sys.path.insert(0, str(Path(__file__).parent))
    import downscale_textures_inline as dsti
    stats = dsti.downscale_all_images()
    print(stats)
"""
from __future__ import annotations

import sys
from dataclasses import dataclass

import bpy


# Tunables --------------------------------------------------------------

# 512 px is the empirical sweet spot for PLATEAU LOD2 facades at the
# corridor viewing distances (typical spawn + nearby buildings).
# - At 1 024 px the per-face aniso budget is wasted at > 20 m eye distance.
# - At 256 px text on the facades starts to alias visibly.
# Bump if future playtest shows texel shimmer on close-read buildings.
TARGET_SIDE: int = 512

# JPEG quality 80 is a PLATEAU / street-view convention — file size
# drops ~4× vs q=95 while the perceptible degradation on 512-px
# textures is below the human discrimination threshold at typical
# in-game distances.
JPEG_QUALITY: int = 80

# Marker key on `image` that signals "already processed in this session",
# used for idempotency when downscale_all_images runs twice.
_MARKER = "sdg_lab_downscaled"


@dataclass
class DownscaleStats:
    """Return type for `downscale_all_images`."""

    processed: int = 0
    skipped_already_done: int = 0
    skipped_no_pixels: int = 0
    skipped_procedural: int = 0
    bytes_before: int = 0
    bytes_after: int = 0

    def summary_line(self) -> str:
        mb_before = self.bytes_before / 1024 / 1024
        mb_after = self.bytes_after / 1024 / 1024
        ratio = (
            (mb_after / mb_before) if mb_before > 0 else 0.0
        )
        return (
            f"textures: processed={self.processed} "
            f"skipped(done={self.skipped_already_done}, "
            f"empty={self.skipped_no_pixels}, "
            f"procedural={self.skipped_procedural}) "
            f"bytes {mb_before:.2f} MiB → {mb_after:.2f} MiB "
            f"({ratio:.0%})"
        )


def _packed_byte_count(image: bpy.types.Image) -> int:
    """Sum of `packed_file.size` over every packed variant of `image`.

    Blender images can hold multiple packed files (one per UDIM tile);
    for our PLATEAU textures there's always exactly one, but we handle
    the general case so we don't mis-count bytes when re-runs leave
    stragglers.
    """
    total = 0
    for pf in getattr(image, "packed_files", []) or []:
        size = getattr(pf, "size", 0) or 0
        total += size
    # `packed_file` is the canonical "only packed file" property — on
    # older Blenders `packed_files` is empty but `packed_file` is set.
    if total == 0:
        pf = getattr(image, "packed_file", None)
        if pf is not None:
            total = getattr(pf, "size", 0) or 0
    return total


def _image_has_real_pixels(image: bpy.types.Image) -> bool:
    """True if the image has pixel data we can meaningfully scale.

    Procedurally generated images (type='GENERATED') with no backing
    file still report `has_data=True` in some Blender builds — safer
    to also check `size` != (0, 0).
    """
    if image.size[0] == 0 or image.size[1] == 0:
        return False
    # 'UV_TEST' / 'GENERATED' ramps have no semantic meaning in a
    # photogrammetry export — skip them.
    if image.source == "GENERATED":
        return False
    return True


def downscale_image(image: bpy.types.Image) -> tuple[bool, int, int]:
    """Downscale + repack a single image in-place.

    Returns `(processed, bytes_before, bytes_after)`. If the image
    can't be processed, returns `(False, 0, 0)`; caller should bucket
    the reason.
    """
    if image.get(_MARKER, False):
        return (False, 0, 0)
    if not _image_has_real_pixels(image):
        return (False, 0, 0)

    bytes_before = _packed_byte_count(image)

    # If already ≤ TARGET_SIDE in both dimensions, don't scale up —
    # that would waste bytes with no visual gain. Still repack as
    # JPEG so export consistency holds.
    needs_scale = (
        image.size[0] > TARGET_SIDE or image.size[1] > TARGET_SIDE
    )
    if needs_scale:
        # Square-squash to TARGET_SIDE × TARGET_SIDE. PLATEAU facades
        # are near-square or already decimated by nusamai, so an
        # aspect-preserving rescale would save only a handful of KB
        # and complicate UV behaviour downstream. Square keeps it
        # boring and predictable.
        image.scale(TARGET_SIDE, TARGET_SIDE)

    # Force JPEG container so the repacked bytes are compact.
    image.file_format = "JPEG"
    # `bpy.context.scene.render.image_settings.quality` is what the
    # image.pack() path honours on current Blender (4.x). Push it up
    # once per call — cheap and side-effect-free for our purposes.
    prev_quality = bpy.context.scene.render.image_settings.quality
    bpy.context.scene.render.image_settings.quality = JPEG_QUALITY
    try:
        image.pack()
    finally:
        bpy.context.scene.render.image_settings.quality = prev_quality

    bytes_after = _packed_byte_count(image)
    image[_MARKER] = True
    return (True, bytes_before, bytes_after)


def downscale_all_images() -> DownscaleStats:
    """Walk every image in the current Blender session.

    Silent on stdout except for a single summary line at the end;
    that keeps the caller's log readable when there are 1 000+
    textures. Callers that want per-image logging can iterate
    `bpy.data.images` themselves and call `downscale_image` directly.
    """
    stats = DownscaleStats()
    for img in list(bpy.data.images):
        if img.get(_MARKER, False):
            stats.skipped_already_done += 1
            continue
        if not _image_has_real_pixels(img):
            if img.source == "GENERATED":
                stats.skipped_procedural += 1
            else:
                stats.skipped_no_pixels += 1
            continue
        ok, before, after = downscale_image(img)
        if ok:
            stats.processed += 1
            stats.bytes_before += before
            stats.bytes_after += after
        else:
            # Should not normally reach here given the checks above;
            # bucket as "no pixels" for safety.
            stats.skipped_no_pixels += 1

    print(f"[downscale] {stats.summary_line()}", file=sys.stderr)
    return stats
