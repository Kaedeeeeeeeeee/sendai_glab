"""Thin HTTP wrapper around the Meshy.ai REST API.

Only the endpoints SDG-Lab actually drives are implemented:
    image-to-3d, text-to-3d, rigging, animation, remesh, retexture.

Endpoint paths and payload schemas match the official docs at
https://docs.meshy.ai/en (verified April 2026). See the Meshy docs
for the full optional parameter list; this client forwards unknown
keyword arguments as request body fields so new options can be
passed through without touching this file.

All task-creation calls return a task-id string. Use ``get_status``
or ``wait_for`` to poll. Status values per Meshy:
PENDING / IN_PROGRESS / SUCCEEDED / FAILED / CANCELED.

Logging goes to stderr so stdout stays clean for piping.
"""

from __future__ import annotations

import base64
import json
import logging
import mimetypes
import os
import pathlib
import sys
import time
from typing import Any, Iterable, Optional
from urllib.parse import urlparse

import requests

__all__ = ["MeshyClient", "MeshyError", "MeshyTaskFailed", "MeshyTimeout"]

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log = logging.getLogger("meshy_client")
if not _log.handlers:
    _handler = logging.StreamHandler(stream=sys.stderr)
    _handler.setFormatter(
        logging.Formatter("[%(asctime)s] %(levelname)s meshy_client: %(message)s")
    )
    _log.addHandler(_handler)
    _log.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class MeshyError(RuntimeError):
    """Base class for all Meshy client errors."""


class MeshyTaskFailed(MeshyError):
    """Raised when a task reaches FAILED or CANCELED state."""


class MeshyTimeout(MeshyError):
    """Raised when wait_for exceeds its timeout budget."""


# Status constants returned by Meshy task objects.
STATUS_PENDING = "PENDING"
STATUS_IN_PROGRESS = "IN_PROGRESS"
STATUS_SUCCEEDED = "SUCCEEDED"
STATUS_FAILED = "FAILED"
STATUS_CANCELED = "CANCELED"
_TERMINAL_STATUSES = frozenset(
    {STATUS_SUCCEEDED, STATUS_FAILED, STATUS_CANCELED}
)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class MeshyClient:
    """Synchronous wrapper around the Meshy.ai REST API.

    Parameters
    ----------
    api_key:
        Bearer token from the Meshy dashboard.
    base_url:
        Override for tests / staging. Defaults to ``https://api.meshy.ai``.
    timeout:
        Per-request HTTP timeout in seconds.
    max_retries:
        Retries for *network* errors (not API 4xx). Exponential backoff.
    """

    DEFAULT_BASE_URL = "https://api.meshy.ai"

    # Endpoint paths (as of the Meshy docs verified April 2026).
    # Only kept as attributes so callers can introspect / patch in tests.
    PATH_IMAGE_TO_3D = "/openapi/v1/image-to-3d"
    PATH_TEXT_TO_3D = "/openapi/v2/text-to-3d"
    PATH_MULTI_IMAGE_TO_3D = "/openapi/v1/multi-image-to-3d"
    PATH_RIGGING = "/openapi/v1/rigging"
    PATH_ANIMATIONS = "/openapi/v1/animations"
    PATH_REMESH = "/openapi/v1/remesh"
    PATH_RETEXTURE = "/openapi/v1/retexture"

    def __init__(
        self,
        api_key: str,
        base_url: str = DEFAULT_BASE_URL,
        *,
        timeout: float = 30.0,
        max_retries: int = 3,
    ) -> None:
        if not api_key:
            raise MeshyError("api_key is required")
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.max_retries = max(1, int(max_retries))
        self._session = requests.Session()
        self._session.headers.update(
            {
                "Authorization": f"Bearer {self.api_key}",
                "User-Agent": "sdg-lab-meshy-pipeline/0.1",
            }
        )

    # ------------------------------------------------------------------
    # Core HTTP helpers
    # ------------------------------------------------------------------

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: Optional[dict[str, Any]] = None,
        stream: bool = False,
    ) -> requests.Response:
        """Send an HTTP request with retry on transient network failures."""
        url = path if path.startswith("http") else f"{self.base_url}{path}"
        last_exc: Optional[Exception] = None
        for attempt in range(1, self.max_retries + 1):
            try:
                _log.debug("%s %s (attempt %d)", method, url, attempt)
                resp = self._session.request(
                    method,
                    url,
                    json=json_body,
                    timeout=self.timeout,
                    stream=stream,
                )
            except requests.RequestException as exc:
                last_exc = exc
                backoff = min(2 ** (attempt - 1), 10)
                _log.warning(
                    "network error (%s) on %s %s, retry in %ds",
                    exc,
                    method,
                    url,
                    backoff,
                )
                time.sleep(backoff)
                continue

            if 200 <= resp.status_code < 300:
                return resp

            # 5xx: retry. 4xx: fail fast — it is a bad request.
            if 500 <= resp.status_code < 600 and attempt < self.max_retries:
                backoff = min(2 ** (attempt - 1), 10)
                _log.warning(
                    "server error %d on %s %s, retry in %ds",
                    resp.status_code,
                    method,
                    url,
                    backoff,
                )
                time.sleep(backoff)
                continue

            self._raise_for_response(resp)

        # Exhausted retries due to network errors.
        raise MeshyError(
            f"network failure on {method} {url} after {self.max_retries} retries: {last_exc}"
        )

    @staticmethod
    def _raise_for_response(resp: requests.Response) -> None:
        try:
            payload = resp.json()
        except ValueError:
            payload = resp.text
        raise MeshyError(
            f"Meshy API {resp.status_code} on {resp.request.method} "
            f"{resp.request.url}: {payload!r}"
        )

    @staticmethod
    def _extract_task_id(payload: dict[str, Any]) -> str:
        """Meshy returns ``{'result': '<task_id>'}``.

        Be defensive — fall back to common alternatives to avoid hard
        breakage if the API evolves.
        """
        for key in ("result", "id", "task_id"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
        raise MeshyError(f"no task id in response payload: {payload!r}")

    # ------------------------------------------------------------------
    # Image helpers (inline Data URI support)
    # ------------------------------------------------------------------

    @staticmethod
    def _coerce_image_reference(image_url_or_path: str) -> str:
        """Return a string Meshy will accept.

        Remote URLs pass through. Local paths are base64-encoded into a
        ``data:`` URI. Meshy accepts both.
        """
        parsed = urlparse(image_url_or_path)
        if parsed.scheme in ("http", "https", "data"):
            return image_url_or_path

        path = pathlib.Path(image_url_or_path)
        if not path.is_file():
            raise MeshyError(f"image path does not exist: {image_url_or_path}")
        mime, _ = mimetypes.guess_type(path.name)
        if mime is None:
            mime = "image/png"
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        return f"data:{mime};base64,{encoded}"

    # ------------------------------------------------------------------
    # Public endpoints
    # ------------------------------------------------------------------

    def image_to_3d(self, image_url_or_path: str, **options: Any) -> str:
        """Submit an image-to-3d task.

        See https://docs.meshy.ai/en/api/image-to-3d for the full parameter
        list. Common keys: ``ai_model``, ``model_type``, ``topology``,
        ``target_polycount``, ``symmetry_mode``, ``pose_mode``,
        ``enable_pbr``, ``hd_texture``, ``should_remesh``, ``texture_prompt``,
        ``target_formats``.
        """
        body: dict[str, Any] = {
            "image_url": self._coerce_image_reference(image_url_or_path),
        }
        body.update(options)
        _log.info("POST %s (image=%s)", self.PATH_IMAGE_TO_3D, image_url_or_path)
        resp = self._request("POST", self.PATH_IMAGE_TO_3D, json_body=body)
        return self._extract_task_id(resp.json())

    def text_to_3d(
        self,
        prompt: str,
        mode: str = "preview",
        **options: Any,
    ) -> str:
        """Submit a text-to-3d task (v2).

        Pass ``mode='refine'`` together with ``preview_task_id=<id>`` to
        escalate a preview task to a refined model.
        """
        body: dict[str, Any] = {"mode": mode}
        if mode == "preview":
            body["prompt"] = prompt
        body.update(options)
        _log.info("POST %s (mode=%s)", self.PATH_TEXT_TO_3D, mode)
        resp = self._request("POST", self.PATH_TEXT_TO_3D, json_body=body)
        return self._extract_task_id(resp.json())

    def multi_image_to_3d(
        self,
        image_urls_or_paths: Iterable[str],
        **options: Any,
    ) -> str:
        """Submit a multi-view image-to-3d task."""
        image_urls = [self._coerce_image_reference(p) for p in image_urls_or_paths]
        body: dict[str, Any] = {"image_urls": image_urls}
        body.update(options)
        _log.info(
            "POST %s (%d images)", self.PATH_MULTI_IMAGE_TO_3D, len(image_urls)
        )
        resp = self._request("POST", self.PATH_MULTI_IMAGE_TO_3D, json_body=body)
        return self._extract_task_id(resp.json())

    def rigging(
        self,
        model_url_or_task_id: str,
        *,
        is_task_id: bool = True,
        **options: Any,
    ) -> str:
        """Submit a rigging task.

        Pass a completed image-to-3d / text-to-3d task id
        (``is_task_id=True``, the default) or the public URL of a GLB
        (``is_task_id=False``).
        """
        body: dict[str, Any] = {}
        if is_task_id:
            body["input_task_id"] = model_url_or_task_id
        else:
            body["model_url"] = model_url_or_task_id
        body.update(options)
        _log.info("POST %s", self.PATH_RIGGING)
        resp = self._request("POST", self.PATH_RIGGING, json_body=body)
        return self._extract_task_id(resp.json())

    def animation(
        self,
        rig_task_id: str,
        action_id: int,
        **options: Any,
    ) -> str:
        """Submit an animation task.

        Meshy's animation API takes a single ``action_id`` per call — a
        numeric identifier from the official Animation Library. To
        generate N clips for one character, call this N times.
        """
        body: dict[str, Any] = {
            "rig_task_id": rig_task_id,
            "action_id": int(action_id),
        }
        body.update(options)
        _log.info(
            "POST %s (rig=%s, action=%d)",
            self.PATH_ANIMATIONS,
            rig_task_id,
            action_id,
        )
        resp = self._request("POST", self.PATH_ANIMATIONS, json_body=body)
        return self._extract_task_id(resp.json())

    def remesh(self, input_task_id: str, **options: Any) -> str:
        """Submit a remesh task against an existing model task."""
        body: dict[str, Any] = {"input_task_id": input_task_id}
        body.update(options)
        _log.info("POST %s", self.PATH_REMESH)
        resp = self._request("POST", self.PATH_REMESH, json_body=body)
        return self._extract_task_id(resp.json())

    def retexture(self, input_task_id: str, **options: Any) -> str:
        """Submit a retexture task against an existing model task."""
        body: dict[str, Any] = {"input_task_id": input_task_id}
        body.update(options)
        _log.info("POST %s", self.PATH_RETEXTURE)
        resp = self._request("POST", self.PATH_RETEXTURE, json_body=body)
        return self._extract_task_id(resp.json())

    # ------------------------------------------------------------------
    # Status + polling
    # ------------------------------------------------------------------

    # Maps task kind -> GET status path prefix. Callers usually do not
    # need to think about this — ``get_status`` tries them in order.
    _STATUS_PATHS = (
        PATH_IMAGE_TO_3D,
        PATH_TEXT_TO_3D,
        PATH_MULTI_IMAGE_TO_3D,
        PATH_RIGGING,
        PATH_ANIMATIONS,
        PATH_REMESH,
        PATH_RETEXTURE,
    )

    def get_status(
        self,
        task_id: str,
        *,
        kind: Optional[str] = None,
    ) -> dict[str, Any]:
        """Fetch the current task object.

        Meshy's status routes are scoped by endpoint family (for example
        ``/openapi/v1/image-to-3d/<id>`` vs ``/openapi/v1/rigging/<id>``).
        Callers that know the kind should pass ``kind`` (one of
        ``image-to-3d``, ``text-to-3d``, ``multi-image-to-3d``, ``rigging``,
        ``animations``, ``remesh``, ``retexture``) for a single request.
        Otherwise this probes each endpoint until one returns 2xx.
        """
        candidates: list[str]
        if kind is not None:
            candidates = [self._path_for_kind(kind)]
        else:
            candidates = list(self._STATUS_PATHS)

        last_err: Optional[MeshyError] = None
        for base in candidates:
            url = f"{base}/{task_id}"
            try:
                resp = self._request("GET", url)
            except MeshyError as exc:
                last_err = exc
                continue
            return resp.json()

        raise MeshyError(
            f"could not resolve status for task {task_id}: {last_err}"
        )

    @classmethod
    def _path_for_kind(cls, kind: str) -> str:
        mapping = {
            "image-to-3d": cls.PATH_IMAGE_TO_3D,
            "text-to-3d": cls.PATH_TEXT_TO_3D,
            "multi-image-to-3d": cls.PATH_MULTI_IMAGE_TO_3D,
            "rigging": cls.PATH_RIGGING,
            "animations": cls.PATH_ANIMATIONS,
            "animation": cls.PATH_ANIMATIONS,
            "remesh": cls.PATH_REMESH,
            "retexture": cls.PATH_RETEXTURE,
        }
        try:
            return mapping[kind]
        except KeyError as exc:
            raise MeshyError(f"unknown task kind: {kind!r}") from exc

    def wait_for(
        self,
        task_id: str,
        *,
        kind: Optional[str] = None,
        poll_interval: int = 10,
        timeout: int = 600,
    ) -> dict[str, Any]:
        """Block until the task reaches a terminal state, or raise.

        Returns the full task dict on SUCCEEDED. Raises ``MeshyTaskFailed``
        on FAILED/CANCELED and ``MeshyTimeout`` if the timeout expires.
        """
        deadline = time.monotonic() + timeout
        last_progress = -1
        while True:
            task = self.get_status(task_id, kind=kind)
            status = task.get("status", "UNKNOWN")
            progress = int(task.get("progress", 0) or 0)
            if progress != last_progress:
                _log.info(
                    "task %s status=%s progress=%d%%",
                    task_id,
                    status,
                    progress,
                )
                last_progress = progress

            if status == STATUS_SUCCEEDED:
                return task
            if status in _TERMINAL_STATUSES:
                err = ""
                task_error = task.get("task_error")
                if isinstance(task_error, dict):
                    err = task_error.get("message", "")
                raise MeshyTaskFailed(
                    f"task {task_id} ended with status {status}: {err}"
                )

            if time.monotonic() >= deadline:
                raise MeshyTimeout(
                    f"task {task_id} did not finish within {timeout}s "
                    f"(last status {status}, progress {progress}%)"
                )
            time.sleep(poll_interval)

    # ------------------------------------------------------------------
    # Download
    # ------------------------------------------------------------------

    def download(self, url: str, output_path: str) -> str:
        """Stream a signed asset URL to disk.

        Returns the absolute path on success. Parent directories are
        created as needed.
        """
        out = pathlib.Path(output_path).expanduser().resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        _log.info("GET %s -> %s", url, out)

        # Signed asset URLs do not need the Authorization header — and
        # sending it sometimes triggers S3 signature rejection. Use a
        # clean requests call for downloads.
        with requests.get(url, stream=True, timeout=self.timeout) as resp:
            if resp.status_code >= 400:
                raise MeshyError(
                    f"download failed {resp.status_code} for {url}: "
                    f"{resp.text[:200]!r}"
                )
            with open(out, "wb") as fh:
                for chunk in resp.iter_content(chunk_size=64 * 1024):
                    if chunk:
                        fh.write(chunk)
        return str(out)

    # ------------------------------------------------------------------
    # Convenience helpers
    # ------------------------------------------------------------------

    @staticmethod
    def pick_model_url(task: dict[str, Any], preferred: str = "glb") -> str:
        """Given a SUCCEEDED task dict, return the model download URL.

        Meshy exposes ``model_urls`` as an object keyed by format
        (``glb`` / ``fbx`` / ``obj`` / ``usdz`` / ...). Missing formats
        are simply absent from the object.
        """
        urls = task.get("model_urls") or {}
        if not isinstance(urls, dict):
            raise MeshyError(f"task has no model_urls: {task!r}")
        if preferred in urls and urls[preferred]:
            return urls[preferred]
        # Fall back to any available format.
        for fmt in ("glb", "fbx", "usdz", "obj", "stl"):
            if urls.get(fmt):
                return urls[fmt]
        raise MeshyError(f"no downloadable model url in task: {urls!r}")


# ---------------------------------------------------------------------------
# CLI smoke test
# ---------------------------------------------------------------------------


def _cli() -> int:
    """``python meshy_client.py <task_id>`` — quick status probe."""
    if len(sys.argv) != 2:
        print("usage: python meshy_client.py <task_id>", file=sys.stderr)
        return 2
    api_key = os.environ.get("MESHY_API_KEY", "")
    if not api_key:
        print("MESHY_API_KEY not set", file=sys.stderr)
        return 2
    client = MeshyClient(api_key)
    task = client.get_status(sys.argv[1])
    json.dump(task, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
