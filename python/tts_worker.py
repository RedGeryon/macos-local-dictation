#!/usr/bin/env python3
"""Local-only Qwen TTS HTTP worker for Local Dictation.

The worker intentionally has no model-download path.  Models are downloaded by
scripts/download-tts-models.sh, then this process loads only those local,
pinned snapshots with Hugging Face offline mode enabled.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import signal
import sys
import threading
import time
import uuid
from array import array
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator


PROTOCOL_VERSION = 1
DEFAULT_MODEL_ID = "qwen-1.7b-bf16"
DEFAULT_MODEL_DIR = Path.home() / "Library/Application Support/LocalDictation/TTSModels"
MAX_LIVE_CHARS = 40_000
MAX_JOB_ID_LENGTH = 80
MAX_UNACKED_SECONDS = 10.0
ACK_HEARTBEAT_SECONDS = 5.0
STREAMING_INTERVAL_SECONDS = 0.32
DEFAULT_CHUNK_MAX_CHARS = 500
REFERENCE_TEXT = "This short sample establishes the voice for the following reading."
DESIGNED_NARRATOR_ID = "designed-narrator"
DESIGNED_NARRATOR_PROMPT = (
    "An articulate English female narrator in her thirties, warm, thoughtful, "
    "and clear with a steady documentary delivery."
)
DESIGNED_NARRATOR_SEED = 42


@dataclass(frozen=True)
class ModelSpec:
    key: str
    repository: str
    revision: str
    directory: str
    mode: str
    supports_instruction: bool


@dataclass(frozen=True)
class ModelChoice:
    """One precision family used to select CustomVoice, Design, and Base weights."""

    identifier: str
    custom_key: str
    design_key: str
    base_key: str


MODEL_CATALOG = {
    "custom": ModelSpec(
        "custom",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16",
        "52f4770fd9726457eae3d3b6aa92047a25a10776",
        "qwen3-tts-1.7b-customvoice-bf16",
        "custom",
        True,
    ),
    "custom8": ModelSpec(
        "custom8",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        "41d3337e8b7f2843a75841595fc14e4b9a7a4b96",
        "qwen3-tts-1.7b-customvoice-8bit",
        "custom",
        True,
    ),
    "design": ModelSpec(
        "design",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16",
        "7d3824abff87e49756bb0f83fb5411de75d160c4",
        "qwen3-tts-1.7b-voicedesign-bf16",
        "design",
        True,
    ),
    "design8": ModelSpec(
        "design8",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee",
        "qwen3-tts-1.7b-voicedesign-8bit",
        "design",
        True,
    ),
    "base": ModelSpec(
        "base",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
        "a6eb4f68e4b056f1215157bb696209bc82a6db48",
        "qwen3-tts-1.7b-base-bf16",
        "base",
        False,
    ),
    "base8": ModelSpec(
        "base8",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
        "e7dd0585652209fa0d7783659aad4e8a324de11c",
        "qwen3-tts-1.7b-base-8bit",
        "base",
        False,
    ),
}

MODEL_CHOICES = {
    "qwen-1.7b-bf16": ModelChoice("qwen-1.7b-bf16", "custom", "design", "base"),
    "qwen-1.7b-8bit": ModelChoice("qwen-1.7b-8bit", "custom8", "design8", "base8"),
}

# The Qwen CustomVoice speaker identifiers are case-sensitive model inputs.
PRESET_SPEAKERS = (
    ("vivian", "Vivian", "Warm, clear female voice"),
    ("serena", "Serena", "Bright female voice"),
    ("uncle-fu", "Uncle_Fu", "Mature male voice"),
    ("dylan", "Dylan", "Young male voice"),
    ("eric", "Eric", "Calm male voice"),
    ("ryan", "Ryan", "Confident male voice"),
    ("aiden", "Aiden", "Youthful male voice"),
    ("ono-anna", "Ono_Anna", "Japanese female voice"),
    ("sohee", "Sohee", "Korean female voice"),
)
SPEAKER_BY_ID = {identifier: name for identifier, name, _ in PRESET_SPEAKERS}


class RequestError(ValueError):
    """A client input error that is safe to return to the local caller."""


class Cancelled(RuntimeError):
    pass


def local_error_detail(error: Exception) -> str:
    """Bound an authenticated local diagnostic without a traceback or request body."""
    message = " ".join(str(error).split())[:600]
    return f"{type(error).__name__}: {message}" if message else type(error).__name__


def default_model_dir() -> Path:
    return Path(os.environ.get("LOCAL_DICTATION_TTS_MODEL_DIR", DEFAULT_MODEL_DIR))


def configured_parent_pid() -> int | None:
    """Return the app parent the worker must outlive, when app-managed.

    Standalone CLI use leaves the variable unset. App launch passes its own PID;
    macOS re-parents a child when that process crashes or is force-quit.
    """
    value = os.environ.get("LOCAL_DICTATION_TTS_PARENT_PID")
    if value is None:
        return None
    if not value.isdigit() or int(value) <= 1:
        raise SystemExit("LOCAL_DICTATION_TTS_PARENT_PID must be a positive process ID")
    return int(value)


def parent_is_current(expected_parent_pid: int) -> bool:
    return os.getppid() == expected_parent_pid


def model_choice(model_id: str) -> ModelChoice:
    try:
        return MODEL_CHOICES[model_id]
    except KeyError as error:
        raise RequestError("model_id must be qwen-1.7b-bf16 or qwen-1.7b-8bit") from error


def choice_specs(choice: ModelChoice) -> tuple[ModelSpec, ModelSpec, ModelSpec]:
    return (
        MODEL_CATALOG[choice.custom_key],
        MODEL_CATALOG[choice.design_key],
        MODEL_CATALOG[choice.base_key],
    )


def designed_narrator_reference_key() -> str:
    """Stable key for the built-in voice users hear in the review sample."""
    design = MODEL_CATALOG["design"]
    value = (
        design.revision + "\0English\0" + DESIGNED_NARRATOR_PROMPT
        + "\0" + str(DESIGNED_NARRATOR_SEED)
    )
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def voice_design_reference_key(design_revision: str, language: str, prompt: str, seed: Any) -> str:
    value = design_revision + "\0" + language + "\0" + prompt + "\0" + str(seed)
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def compatible_voice_design_reference_keys(language: str, prompt: str, seed: Any) -> list[str]:
    """Find references made by either pinned VoiceDesign precision.

    A saved reference is WAV plus its transcript, which Base consumes as audio
    conditioning. It is not a model-weight cache, so an existing reference can
    be reused when the caller changes Base precision.
    """
    return [
        voice_design_reference_key(spec.revision, language, prompt, seed)
        for spec in MODEL_CATALOG.values()
        if spec.mode == "design"
    ]


def apply_pronunciation_overrides(text: str, overrides: Any) -> str:
    """Apply literal, longest-first substitutions supplied by the user.

    The replacements only affect this synthesis request. They do not mutate the
    selected text, a document, or a global pronunciation dictionary.
    """
    if overrides is None:
        return text
    if not isinstance(overrides, list) or len(overrides) > 200:
        raise RequestError("pronunciation_overrides must contain at most 200 entries")
    if not overrides:
        return text
    entries: list[tuple[str, str]] = []
    for item in overrides:
        if not isinstance(item, dict):
            raise RequestError("each pronunciation override must be an object")
        source, replacement = item.get("from"), item.get("to")
        if not isinstance(source, str) or not isinstance(replacement, str):
            raise RequestError("pronunciation overrides require string 'from' and 'to'")
        if not source or len(source) > 200 or len(replacement) > 500:
            raise RequestError("pronunciation override text has an invalid length")
        entries.append((source, replacement))
    # One pass prevents a replacement from becoming input to a later rule.
    # Longest-first resolves overlapping literal keys deterministically.
    ordered = sorted(entries, key=lambda pair: len(pair[0]), reverse=True)
    replacements = {source: replacement for source, replacement in ordered}
    return re.sub("|".join(re.escape(source) for source, _ in ordered), lambda match: replacements[match.group(0)], text)


def split_text(text: str, maximum: int) -> list[str]:
    """Split only at readable boundaries, with a hard bound for model safety."""
    if maximum < 80:
        raise RequestError("chunk_max_chars must be at least 80")
    normalized = re.sub(r"\s+", " ", text).strip()
    if not normalized:
        raise RequestError("text must not be empty")
    result: list[str] = []
    remaining = normalized
    while len(remaining) > maximum:
        window = remaining[: maximum + 1]
        cut = max(window.rfind(mark) for mark in (". ", "! ", "? "))
        if cut < 0:
            cut = max(window.rfind(mark) for mark in ("; ", ": ", ", "))
        if cut < 0:
            cut = window.rfind(" ")
        if cut < 0:
            # A pathological unbroken token is still bounded.  Keep each byte
            # of its text rather than silently dropping or truncating content.
            cut = maximum
        else:
            cut += 1
        piece = remaining[:cut].strip()
        if piece:
            result.append(piece)
        remaining = remaining[cut:].strip()
    if remaining:
        result.append(remaining)
    return result


def pop_text_piece(text: str, maximum: int) -> tuple[str, str]:
    """Take one bounded raw-text piece and return its unconsumed tail."""
    window = text[: maximum + 1]
    cut = max(window.rfind(mark) for mark in (". ", "! ", "? "))
    if cut < 0:
        cut = max(window.rfind(mark) for mark in ("; ", ": ", ", ", " "))
    if cut < 0:
        cut = maximum
    else:
        cut += 1
    return text[:cut].strip(), text[cut:].lstrip()


def request_text_parts(request: dict[str, Any]) -> Iterator[str]:
    """Yield bounded readable pieces without an audio-duration limit.

    A text string is convenient for read-back. For an arbitrarily long export,
    `text_path` lets the app hand over a UTF-8 staging file and this iterator
    reads it in bounded blocks rather than placing the whole book in memory.
    """
    if request["text"] is not None:
        for piece in split_text(apply_pronunciation_overrides(request["text"], request["pronunciation_overrides"]), request["chunk_max_chars"]):
            yield piece
        return
    assert request["text_path"] is not None
    saw_text = False
    buffer = ""
    try:
        with request["text_path"].open("r", encoding="utf-8") as source:
            while block := source.read(16_384):
                buffer += block
                while len(buffer) > request["chunk_max_chars"]:
                    piece, buffer = pop_text_piece(buffer, request["chunk_max_chars"])
                    if piece:
                        saw_text = True
                        yield apply_pronunciation_overrides(piece, request["pronunciation_overrides"])
            if buffer.strip():
                saw_text = True
                for piece in split_text(buffer, request["chunk_max_chars"]):
                    yield apply_pronunciation_overrides(piece, request["pronunciation_overrides"])
    except UnicodeDecodeError as error:
        raise RequestError("text_path must be a UTF-8 text file") from error
    if not saw_text:
        raise RequestError("text_path contains no readable text")


def pcm16_bytes(audio: Any) -> bytes:
    """Convert an MLX/NumPy-like mono float array to little-endian PCM16."""
    values = audio.tolist() if hasattr(audio, "tolist") else list(audio)
    # Some backends expose shape (samples, 1). Qwen exposes mono 1-D, but keep
    # this defensive conversion at the process boundary.
    pcm = array("h")
    for value in values:
        if isinstance(value, (list, tuple)):
            value = value[0]
        clipped = max(-1.0, min(1.0, float(value)))
        pcm.append(int(round(clipped * 32767.0)))
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm.tobytes()


def rf64_staging_path(destination: Path, job_id: str) -> Path:
    """Return the only partial file a canceled job is permitted to remove."""
    return destination.with_name(f".{destination.name}.{job_id}.partial")


class AtomicWavWriter:
    """Small independent WAV chunk; each finished chunk appears atomically."""

    def __init__(self, path: Path, sample_rate: int) -> None:
        self.path = path
        self.partial_path = path.with_name(path.name + ".partial")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.partial_path.open("wb+")
        self.sample_rate = sample_rate
        self.data_bytes = 0
        self.file.write(b"RIFF\x00\x00\x00\x00WAVEfmt ")
        self.file.write((16).to_bytes(4, "little"))
        self.file.write((1).to_bytes(2, "little"))
        self.file.write((1).to_bytes(2, "little"))
        self.file.write(sample_rate.to_bytes(4, "little"))
        self.file.write((sample_rate * 2).to_bytes(4, "little"))
        self.file.write((2).to_bytes(2, "little"))
        self.file.write((16).to_bytes(2, "little"))
        self.file.write(b"data\x00\x00\x00\x00")

    def write(self, pcm: bytes) -> None:
        self.file.write(pcm)
        self.data_bytes += len(pcm)

    def finish(self) -> dict[str, int]:
        if self.data_bytes > 0xFFFFFFFF - 36:
            raise RequestError("a live WAV chunk exceeded the RIFF size limit")
        self.file.seek(4)
        self.file.write((36 + self.data_bytes).to_bytes(4, "little"))
        self.file.seek(40)
        self.file.write(self.data_bytes.to_bytes(4, "little"))
        self.file.flush()
        os.fsync(self.file.fileno())
        self.file.close()
        os.replace(self.partial_path, self.path)
        return {"bytes": self.data_bytes, "frames": self.data_bytes // 2}

    def abort(self) -> None:
        if not self.file.closed:
            self.file.close()
        self.partial_path.unlink(missing_ok=True)


class AtomicRF64Writer:
    """Incremental RF64 PCM writer for arbitrarily long files.

    RF64 reserves 64-bit size fields up front, so it remains valid beyond WAV's
    4 GiB data limit without retaining previous audio in memory.
    """

    def __init__(self, path: Path, sample_rate: int, staging_path: Path | None = None) -> None:
        self.path = path
        self.partial_path = staging_path or path.with_name(path.name + ".partial")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.partial_path.open("wb+")
        self.sample_rate = sample_rate
        self.data_bytes = 0
        self.file.write(b"RF64\xff\xff\xff\xffWAVE")
        self.file.write(b"ds64")
        self.file.write((28).to_bytes(4, "little"))
        self.ds64_values_offset = self.file.tell()
        self.file.write(b"\x00" * 24)  # riff size, data size, sample count
        self.file.write((0).to_bytes(4, "little"))  # no additional chunk table
        self.file.write(b"fmt ")
        self.file.write((16).to_bytes(4, "little"))
        self.file.write((1).to_bytes(2, "little"))
        self.file.write((1).to_bytes(2, "little"))
        self.file.write(sample_rate.to_bytes(4, "little"))
        self.file.write((sample_rate * 2).to_bytes(4, "little"))
        self.file.write((2).to_bytes(2, "little"))
        self.file.write((16).to_bytes(2, "little"))
        self.file.write(b"data\xff\xff\xff\xff")

    def write(self, pcm: bytes) -> None:
        self.file.write(pcm)
        self.data_bytes += len(pcm)

    def finish(self) -> dict[str, int]:
        if self.data_bytes % 2:
            raise RuntimeError("PCM16 data must end on a sample boundary")
        if self.data_bytes % 2:
            self.file.write(b"\x00")
        self.file.seek(0, os.SEEK_END)
        file_size = self.file.tell()
        self.file.seek(self.ds64_values_offset)
        self.file.write((file_size - 8).to_bytes(8, "little"))
        self.file.write(self.data_bytes.to_bytes(8, "little"))
        self.file.write((self.data_bytes // 2).to_bytes(8, "little"))
        self.file.flush()
        os.fsync(self.file.fileno())
        self.file.close()
        os.replace(self.partial_path, self.path)
        return {"bytes": self.data_bytes, "frames": self.data_bytes // 2}

    def abort(self) -> None:
        if not self.file.closed:
            self.file.close()
        self.partial_path.unlink(missing_ok=True)


@dataclass
class Job:
    identifier: str
    cancelled: threading.Event = field(default_factory=threading.Event)
    acknowledgements: set[int] = field(default_factory=set)
    sent: list[tuple[int, float, float]] = field(default_factory=list)
    condition: threading.Condition = field(default_factory=threading.Condition)

    def acknowledge(self, index: int) -> None:
        with self.condition:
            self.acknowledgements.add(index)
            self.sent = [(sent_index, at, duration) for sent_index, at, duration in self.sent if sent_index > index]
            self.acknowledgements = {ack for ack in self.acknowledgements if ack > index}
            self.condition.notify_all()

    def wait_for_capacity(self, heartbeat: Callable[[], None] | None = None, heartbeat_interval: float = ACK_HEARTBEAT_SECONDS) -> None:
        """Wait until no more than ten seconds of audio is unplayed."""
        next_heartbeat = time.monotonic() + heartbeat_interval
        with self.condition:
            while True:
                pending = [(i, at, duration) for i, at, duration in self.sent if i not in self.acknowledgements]
                pending_seconds = sum(duration for _, _, duration in pending)
                if pending_seconds <= MAX_UNACKED_SECONDS:
                    return
                if self.cancelled.is_set():
                    raise Cancelled()
                now = time.monotonic()
                if heartbeat is not None and now >= next_heartbeat:
                    heartbeat()
                    next_heartbeat = now + heartbeat_interval
                self.condition.wait(timeout=min(0.2, max(0.01, next_heartbeat - now)))


class QwenRuntime:
    """Loads exactly one pinned MLX model at a time and never accesses network."""

    def __init__(self, model_dir: Path) -> None:
        self.model_dir = model_dir
        self.model: Any | None = None
        self.loaded_spec: ModelSpec | None = None
        self.lock = threading.Lock()

    def installed(self, spec: ModelSpec) -> bool:
        directory = self.model_dir / spec.directory
        marker = directory / ".local-dictation-complete.json"
        try:
            marker_value = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        return (
            marker_value == {"repository": spec.repository, "revision": spec.revision}
            and (directory / "config.json").is_file()
            and any(directory.glob("*.safetensors"))
            and (directory / "speech_tokenizer").is_dir()
            and (directory / "tokenizer_config.json").is_file()
            and (directory / "vocab.json").is_file()
            and (directory / "merges.txt").is_file()
        )

    def detail(self) -> str:
        installed = [key for key, spec in MODEL_CATALOG.items() if self.installed(spec)]
        return "Installed models: " + (", ".join(installed) if installed else "none")

    def choices_status(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for choice in MODEL_CHOICES.values():
            custom, design, base = choice_specs(choice)
            result.append({
                "id": choice.identifier,
                "custom_voice_installed": self.installed(custom),
                "voice_design_installed": self.installed(design),
                "base_installed": self.installed(base),
                "designed_voice_ready": self.installed(design) and self.installed(base),
            })
        return result

    def warmed_model_id(self) -> str | None:
        if self.loaded_spec is None:
            return None
        for choice in MODEL_CHOICES.values():
            if self.loaded_spec in choice_specs(choice):
                return choice.identifier
        return None

    def warmed_component(self) -> str | None:
        if self.loaded_spec is None:
            return None
        return {"custom": "custom_voice", "design": "voice_design", "base": "base"}[self.loaded_spec.mode]

    def preload(self, model_id: str, voice_id: str = "ryan") -> None:
        choice = model_choice(model_id)
        custom, design, base = choice_specs(choice)
        normalized_voice_id = voice_id.lower()
        if normalized_voice_id in SPEAKER_BY_ID:
            spec = custom
        elif normalized_voice_id == "voice-design":
            spec = design
        elif normalized_voice_id in {"voice-design-consistent", DESIGNED_NARRATOR_ID}:
            # Loading Base is harmless when the saved reference is absent. The
            # later synthesis request reports that missing prerequisite; preload
            # must never create or replace a user's reference.
            spec = base
        else:
            raise RequestError("unknown voice_id; use a preset voice or voice-design")
        self._load(spec)

    def unload(self) -> None:
        if self.model is None:
            return
        self.model = None
        self.loaded_spec = None
        import gc
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except ImportError:
            pass

    def _load(self, spec: ModelSpec) -> Any:
        if self.loaded_spec == spec and self.model is not None:
            return self.model
        path = self.model_dir / spec.directory
        if not self.installed(spec):
            raise RequestError(f"The '{spec.key}' model is not installed. Run scripts/download-tts-models.sh --model {spec.key}.")
        try:
            from mlx_audio.tts.utils import load
        except ImportError as error:
            raise RuntimeError("MLX Audio is unavailable. Run scripts/setup-tts-runtime.sh first.") from error
        if self.model is not None:
            # Keep only one model's weights resident. This matters when a
            # VoiceDesign reference switches into the Base model for a long job.
            self.unload()
        # Passing a local absolute path prevents a repository ID from triggering
        # a download. The process also sets HF_HUB_OFFLINE before import.
        self.model = load(path, lazy=False, strict=True)
        self.loaded_spec = spec
        return self.model

    @staticmethod
    def _seed(seed: Any) -> None:
        if seed is None:
            return
        if not isinstance(seed, int) or seed < 0 or seed > 2**32 - 1:
            raise RequestError("seed must be an unsigned 32-bit integer")
        try:
            import mlx.core as mx
            mx.random.seed(seed)
        except ImportError as error:
            raise RuntimeError("MLX is unavailable") from error

    def generate(self, spec: ModelSpec, text: str, speaker: str | None, prompt: str | None,
                 language: str, seed: Any, stream: bool, reference: tuple[Path, str] | None = None) -> Iterator[Any]:
        model = self._load(spec)
        self._seed(seed)
        kwargs: dict[str, Any] = {
            "text": text,
            "lang_code": language,
            "temperature": 0.9,
            "max_tokens": 4096,
            "top_k": 50,
            "top_p": 1.0,
            "repetition_penalty": 1.05,
            "stream": stream,
            "streaming_interval": STREAMING_INTERVAL_SECONDS if stream else 2.0,
            "verbose": False,
        }
        if spec.mode == "custom":
            if not speaker:
                raise RequestError("a CustomVoice request requires a preset voice")
            kwargs["voice"] = speaker
            if prompt:
                if not spec.supports_instruction:
                    raise RequestError("voice_prompt requires the 1.7B CustomVoice model")
                kwargs["instruct"] = prompt
        elif spec.mode == "design":
            if not prompt:
                raise RequestError("VoiceDesign requires a non-empty voice_prompt")
            kwargs["instruct"] = prompt
        elif reference:
            kwargs["ref_audio"], kwargs["ref_text"] = str(reference[0]), reference[1]
        else:
            raise RequestError("Base generation requires a voice reference")
        return model.generate(**kwargs)


def parse_request(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise RequestError("request body must be a JSON object")
    text = payload.get("text")
    text_path_value = payload.get("text_path")
    if text is not None and text_path_value is not None:
        raise RequestError("send either text or text_path, not both")
    text_path: Path | None = None
    if text_path_value is not None:
        if not isinstance(text_path_value, str) or not Path(text_path_value).is_absolute():
            raise RequestError("text_path must be an absolute path")
        text_path = Path(text_path_value)
        if not text_path.is_file():
            raise RequestError("text_path must name a readable file")
    elif not isinstance(text, str) or not text.strip():
        raise RequestError("text must be a non-empty string")
    voice_id = payload.get("voice_id", "ryan")
    if not isinstance(voice_id, str):
        raise RequestError("voice_id must be a string")
    selected_model_id = payload.get("model_id", os.environ.get("LOCAL_DICTATION_TTS_MODEL_ID", DEFAULT_MODEL_ID))
    if not isinstance(selected_model_id, str):
        raise RequestError("model_id must be a string")
    model_choice(selected_model_id)
    language = payload.get("language", "English")
    if language not in {"English", "Spanish"}:
        raise RequestError("language must be English or Spanish")
    prompt = payload.get("voice_prompt")
    if prompt is not None and (not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 1_000):
        raise RequestError("voice_prompt must be a non-empty string up to 1,000 characters")
    if voice_id.lower() == DESIGNED_NARRATOR_ID:
        if prompt:
            raise RequestError("the designed narrator has a fixed voice; use voice-design to provide a custom voice_prompt")
        if language != "English":
            raise RequestError("the designed narrator is an English preset")
        prompt = DESIGNED_NARRATOR_PROMPT
    stream = payload.get("stream", False)
    if not isinstance(stream, bool):
        raise RequestError("stream must be a boolean")
    if stream and (text_path is not None or len(text) > MAX_LIVE_CHARS):
        raise RequestError("live text is limited to 40,000 characters")
    speed = payload.get("speed", 1.0)
    if speed != 1.0:
        raise RequestError("Qwen speed control is unsupported by the pinned MLX runtime; only 1.0 is available")
    max_chars = payload.get("chunk_max_chars", DEFAULT_CHUNK_MAX_CHARS)
    if not isinstance(max_chars, int) or not 80 <= max_chars <= 2_000:
        raise RequestError("chunk_max_chars must be an integer from 80 through 2,000")
    output_path = payload.get("output_path")
    if output_path is not None and (not isinstance(output_path, str) or not Path(output_path).is_absolute()):
        raise RequestError("output_path must be an absolute path")
    job_id = payload.get("job_id") or str(uuid.uuid4())
    if not isinstance(job_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1," + str(MAX_JOB_ID_LENGTH) + r"}", job_id):
        raise RequestError("job_id may contain only letters, numbers, underscores, and hyphens")
    return {
        "text": text,
        "text_path": text_path,
        "pronunciation_overrides": payload.get("pronunciation_overrides"),
        "voice_id": voice_id,
        "model_id": selected_model_id,
        "voice_prompt": prompt.strip() if prompt else None,
        "language": language,
        "stream": stream,
        "format": payload.get("format", "wav"),
        "output_path": Path(output_path) if output_path else None,
        "seed": DESIGNED_NARRATOR_SEED if voice_id.lower() == DESIGNED_NARRATOR_ID else payload.get("seed"),
        "chunk_max_chars": max_chars,
        "job_id": job_id,
        "design_consistent": payload.get("design_consistent", True),
    }


def voice_selection(request: dict[str, Any]) -> tuple[ModelSpec, str | None]:
    voice_id = request["voice_id"].lower()
    custom, design, _ = choice_specs(model_choice(request["model_id"]))
    if voice_id in SPEAKER_BY_ID:
        return custom, SPEAKER_BY_ID[voice_id]
    if voice_id == "voice-design":
        return design, None
    if voice_id == "voice-design-consistent":
        return design, None
    if voice_id == DESIGNED_NARRATOR_ID:
        return design, None
    raise RequestError("unknown voice_id; use a preset voice or voice-design")


class Worker:
    def __init__(self, runtime: QwenRuntime) -> None:
        self.runtime = runtime
        self.active_job: Job | None = None
        self.active_lock = threading.Lock()

    def start(self, job_id: str) -> Job:
        with self.active_lock:
            if self.active_job is not None:
                raise RequestError("another TTS request is already running")
            self.active_job = Job(job_id)
            return self.active_job

    def finish(self, job: Job) -> None:
        with self.active_lock:
            if self.active_job is job:
                self.active_job = None

    def cancel(self, job_id: str | None) -> bool:
        with self.active_lock:
            if self.active_job is None or (job_id and self.active_job.identifier != job_id):
                return False
            self.active_job.cancelled.set()
            with self.active_job.condition:
                self.active_job.condition.notify_all()
            return True

    def ack(self, job_id: str, index: int) -> bool:
        with self.active_lock:
            if self.active_job is None or self.active_job.identifier != job_id:
                return False
            self.active_job.acknowledge(index)
            return True

    def preload(self, model_id: str, voice_id: str = "ryan") -> None:
        with self.active_lock:
            if self.active_job is not None:
                raise RequestError("cannot preload while a TTS request is running")
            with self.runtime.lock:
                self.runtime.preload(model_id, voice_id)

    def unload(self) -> None:
        with self.active_lock:
            if self.active_job is not None:
                raise RequestError("cannot unload while a TTS request is running")
            with self.runtime.lock:
                self.runtime.unload()


class TTSHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: "TTSServer"

    def log_message(self, _format: str, *args: Any) -> None:
        # Avoid logging selected text, prompts, tokens, or output paths.
        return

    def _authorized(self) -> bool:
        provided = self.headers.get("Authorization", "")
        return hmac.compare_digest(provided, "Bearer " + self.server.token)

    def _json_body(self) -> Any:
        length = self.headers.get("Content-Length")
        if not length or not length.isdigit() or int(length) > 4_000_000:
            raise RequestError("invalid request body length")
        try:
            return json.loads(self.rfile.read(int(length)))
        except json.JSONDecodeError as error:
            raise RequestError("request body is not valid JSON") from error

    def _respond(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def _error(self, status: int, detail: str) -> None:
        self._respond(status, {"error": detail})

    def _model_status(self) -> dict[str, Any]:
        runtime = self.server.worker.runtime
        designed_reference_exists = (self.server.saved_voice_dir / designed_narrator_reference_key() / "reference.wav").is_file()
        models = runtime.choices_status()
        for status in models:
            choice = model_choice(status["id"])
            _, design, base = choice_specs(choice)
            status["designed_narrator_reference_available"] = designed_reference_exists
            status["designed_voice_ready"] = runtime.installed(base) and (
                runtime.installed(design) or designed_reference_exists
            )
        return {
            "models": models,
            "warmed_model_id": runtime.warmed_model_id(),
            "warmed_component": runtime.warmed_component(),
        }

    def do_GET(self) -> None:
        if not self._authorized():
            self._error(HTTPStatus.UNAUTHORIZED, "unauthorized")
            return
        if self.path == "/ready":
            payload = {
                "ready": True, "protocol": PROTOCOL_VERSION, "detail": self.server.worker.runtime.detail(),
                "supported_speed": [1.0],
            }
            payload.update(self._model_status())
            self._respond(HTTPStatus.OK, payload)
            return
        if self.path == "/v1/voices":
            presets = [
                {"id": identifier, "name": name, "description": description, "prompt_supported": True}
                for identifier, name, description in PRESET_SPEAKERS
            ]
            ryan = next(voice for voice in presets if voice["id"] == "ryan")
            remaining_presets = [voice for voice in presets if voice["id"] != "ryan"]
            voices = [
                ryan,
                {"id": DESIGNED_NARRATOR_ID, "name": "Designed narrator", "description": "Warm, thoughtful English female narrator from the reviewed saved voice profile.", "prompt_supported": False},
                *remaining_presets,
                {"id": "voice-design", "name": "Voice design", "description": "Create a voice from a natural-language prompt.", "prompt_supported": True},
                {"id": "voice-design-consistent", "name": "Voice design (long form)", "description": "Creates a short voice reference, then uses it for the full reading.", "prompt_supported": True},
            ]
            payload = {"voices": voices, "detail": self.server.worker.runtime.detail(), "supported_speed": [1.0]}
            payload.update(self._model_status())
            self._respond(HTTPStatus.OK, payload)
            return
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:
        if not self._authorized():
            self._error(HTTPStatus.UNAUTHORIZED, "unauthorized")
            return
        try:
            payload = self._json_body()
            if self.path == "/v1/tts/ack":
                if not isinstance(payload, dict) or not isinstance(payload.get("job_id"), str) or not isinstance(payload.get("index"), int):
                    raise RequestError("ack requires job_id and index")
                self._respond(HTTPStatus.OK, {"acknowledged": self.server.worker.ack(payload["job_id"], payload["index"])})
                return
            if self.path == "/v1/tts/cancel":
                job_id = payload.get("job_id") if isinstance(payload, dict) else None
                if job_id is not None and not isinstance(job_id, str):
                    raise RequestError("job_id must be a string")
                self._respond(HTTPStatus.OK, {"cancelled": self.server.worker.cancel(job_id)})
                return
            if self.path == "/v1/models/preload":
                if not isinstance(payload, dict) or not isinstance(payload.get("model_id"), str):
                    raise RequestError("preload requires model_id")
                voice_id = payload.get("voice_id", "ryan")
                if not isinstance(voice_id, str):
                    raise RequestError("voice_id must be a string")
                choice = model_choice(payload["model_id"])
                self.server.worker.preload(choice.identifier, voice_id)
                response = {"model_id": choice.identifier, "voice_id": voice_id}
                response.update(self._model_status())
                self._respond(HTTPStatus.OK, response)
                return
            if self.path == "/v1/models/unload":
                if not isinstance(payload, dict):
                    raise RequestError("unload requires a JSON object")
                self.server.worker.unload()
                self._respond(HTTPStatus.OK, self._model_status())
                return
            if self.path != "/v1/tts":
                self._error(HTTPStatus.NOT_FOUND, "not found")
                return
            request = parse_request(payload)
            if request["stream"]:
                self._stream_tts(request)
            else:
                self._render_file(request)
        except RequestError as error:
            self._error(HTTPStatus.UNPROCESSABLE_ENTITY, str(error))
        except BrokenPipeError:
            return
        except Exception as error:
            # The authenticated loopback client receives a bounded diagnostic;
            # request text and a traceback are never included.
            detail = local_error_detail(error)
            print(f"TTS worker request failed: {detail}", file=sys.stderr, flush=True)
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, f"TTS request failed: {detail}")

    def _event(self, payload: dict[str, Any]) -> None:
        self.wfile.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
        self.wfile.flush()

    def _stream_tts(self, request: dict[str, Any]) -> None:
        job = self.server.worker.start(request["job_id"])
        if request["output_path"] is None:
            self.server.worker.finish(job)
            raise RequestError("output_path is required for live playback and must name its job directory")
        output_directory = request["output_path"]
        if not output_directory.is_dir():
            self.server.worker.finish(job)
            raise RequestError("for stream:true, output_path must be an existing job directory")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        started = time.monotonic()
        total_frames = 0
        sample_rate = 24_000
        index = 0
        try:
            self._event({"type": "started", "job_id": job.identifier})
            for pcm, rate in self._synthesize(request, job):
                if job.cancelled.is_set():
                    raise Cancelled()
                chunk_path = output_directory / f"{job.identifier}-{index:06d}.wav"
                writer = AtomicWavWriter(chunk_path, rate)
                writer.write(pcm)
                metadata = writer.finish()
                duration = metadata["frames"] / rate
                self._event({"type": "audio_chunk", "job_id": job.identifier, "index": index,
                             "path": str(chunk_path), "sample_rate": rate, "frames": metadata["frames"],
                             "duration_ms": round(duration * 1000)})
                with job.condition:
                    job.sent.append((index, time.monotonic(), duration))
                total_frames += metadata["frames"]
                sample_rate = rate
                index += 1
                job.wait_for_capacity(lambda: self._event({
                    "type": "progress", "job_id": job.identifier, "waiting_for_playback": True
                }))
            self._event({"type": "completed", "job_id": job.identifier, "sample_rate": sample_rate,
                         "frames": total_frames, "duration_seconds": total_frames / sample_rate,
                         "generation_seconds": round(time.monotonic() - started, 3)})
        except Cancelled:
            for chunk in output_directory.glob(f"{job.identifier}-*.wav"):
                chunk.unlink(missing_ok=True)
            self._event({"type": "cancelled", "job_id": job.identifier})
        except RequestError as error:
            for chunk in output_directory.glob(f"{job.identifier}-*.wav"):
                chunk.unlink(missing_ok=True)
            print(f"TTS stream request failed: {error}", file=sys.stderr, flush=True)
            self._event({"type": "error", "job_id": job.identifier, "error": str(error)})
        except Exception as error:
            for chunk in output_directory.glob(f"{job.identifier}-*.wav"):
                chunk.unlink(missing_ok=True)
            detail = local_error_detail(error)
            print(f"TTS stream failed: {detail}", file=sys.stderr, flush=True)
            self._event({"type": "error", "job_id": job.identifier, "error": f"TTS generation failed: {detail}"})
        finally:
            self.server.worker.finish(job)

    def _render_file(self, request: dict[str, Any]) -> None:
        if request["format"] not in {"rf64", "wav"}:
            raise RequestError("format must be rf64 or wav")
        if request["output_path"] is None:
            raise RequestError("output_path is required for a file render")
        # Always emit RF64, even for a small current file, so a render has no
        # later duration limit. The accepted `wav` input remains an API alias.
        job = self.server.worker.start(request["job_id"])
        writer: AtomicRF64Writer | None = None
        started = time.monotonic()
        staging_path = rf64_staging_path(request["output_path"], job.identifier)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self._event({"type": "started", "job_id": job.identifier, "staging_path": str(staging_path)})
            chunk_count = 0
            for pcm, rate in self._synthesize(request, job):
                if job.cancelled.is_set():
                    raise Cancelled()
                if writer is None:
                    writer = AtomicRF64Writer(request["output_path"], rate, staging_path=staging_path)
                elif writer.sample_rate != rate:
                    raise RuntimeError("the model changed sample rate during one render")
                writer.write(pcm)
                chunk_count += 1
                self._event({"type": "progress", "job_id": job.identifier, "audio_chunks": chunk_count,
                             "frames": writer.data_bytes // 2, "sample_rate": writer.sample_rate})
            if writer is None:
                raise RuntimeError("model returned no audio")
            metadata = writer.finish()
            self._event({"type": "completed", "job_id": job.identifier, "path": str(request["output_path"]),
                         "container": "RF64", "sample_rate": writer.sample_rate, **metadata,
                         "duration_seconds": metadata["frames"] / writer.sample_rate,
                         "generation_seconds": round(time.monotonic() - started, 3), "speed": 1.0})
        except Cancelled:
            if writer:
                writer.abort()
            self._event({"type": "cancelled", "job_id": job.identifier})
        except RequestError as error:
            if writer:
                writer.abort()
            print(f"TTS render request failed: {error}", file=sys.stderr, flush=True)
            self._event({"type": "error", "job_id": job.identifier, "error": str(error)})
        except Exception as error:
            if writer:
                writer.abort()
            detail = local_error_detail(error)
            print(f"TTS render failed: {detail}", file=sys.stderr, flush=True)
            self._event({"type": "error", "job_id": job.identifier, "error": f"TTS generation failed: {detail}"})
        finally:
            self.server.worker.finish(job)

    def _synthesize(self, request: dict[str, Any], job: Job) -> Iterator[tuple[bytes, int]]:
        spec, speaker = voice_selection(request)
        parts = request_text_parts(request)
        reference: tuple[Path, str] | None = None
        # VoiceDesign is expressive but independently generated passages can
        # drift. For the explicit long-form option, create one small reference
        # once, then run the Base model with that same reference across every
        # content chunk. The reference itself is never returned to the user.
        if request["voice_id"].lower() in {"voice-design-consistent", DESIGNED_NARRATOR_ID}:
            designed_narrator = request["voice_id"].lower() == DESIGNED_NARRATOR_ID
            if designed_narrator:
                # Keep the original built-in profile key: changing Base
                # precision must not silently replace a saved reference WAV.
                reference_keys = [designed_narrator_reference_key()]
            else:
                selected_key = voice_design_reference_key(
                    spec.revision, request["language"], request["voice_prompt"], request["seed"]
                )
                reference_keys = [selected_key] + [
                    key for key in compatible_voice_design_reference_keys(
                        request["language"], request["voice_prompt"], request["seed"]
                    ) if key != selected_key
                ]
            voice_dir = next(
                (self.server.saved_voice_dir / key for key in reference_keys
                 if (self.server.saved_voice_dir / key / "reference.wav").is_file()),
                self.server.saved_voice_dir / reference_keys[0],
            )
            reference_path = voice_dir / "reference.wav"
            if not reference_path.is_file():
                voice_dir.mkdir(parents=True, exist_ok=True)
                reference_audio: list[bytes] = []
                reference_rate = 24_000
                with self.server.worker.runtime.lock:
                    for result in self.server.worker.runtime.generate(spec, REFERENCE_TEXT, None, request["voice_prompt"], request["language"], request["seed"], False):
                        if job.cancelled.is_set():
                            raise Cancelled()
                        reference_rate = int(result.sample_rate)
                        reference_audio.append(pcm16_bytes(result.audio))
                reference_writer = AtomicWavWriter(reference_path, reference_rate)
                for pcm in reference_audio:
                    reference_writer.write(pcm)
                reference_writer.finish()
                metadata_path = voice_dir / "metadata.json"
                metadata_path.write_text(json.dumps({"model_revision": spec.revision, "language": request["language"], "seed": request["seed"], "reference_text": REFERENCE_TEXT}), encoding="utf-8")
            _, _, base = choice_specs(model_choice(request["model_id"]))
            spec, speaker, reference = base, None, (reference_path, REFERENCE_TEXT)
        for part in parts:
            with self.server.worker.runtime.lock:
                generator = self.server.worker.runtime.generate(spec, part, speaker, request["voice_prompt"], request["language"], request["seed"], True, reference)
                for result in generator:
                    if job.cancelled.is_set():
                        raise Cancelled()
                    pcm = pcm16_bytes(result.audio)
                    if pcm:
                        yield pcm, int(result.sample_rate)


class TTSServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: tuple[str, int], worker: Worker, token: str, temp_dir: Path) -> None:
        super().__init__(address, TTSHandler)
        self.worker = worker
        self.token = token
        self.temp_dir = temp_dir
        self.saved_voice_dir = worker.runtime.model_dir.parent / "SavedVoices"
        self.saved_voice_dir.mkdir(parents=True, exist_ok=True)


def run_server(port: int) -> None:
    token = os.environ.get("LOCAL_DICTATION_TTS_BEARER_TOKEN", "")
    if len(token) < 24:
        raise SystemExit("LOCAL_DICTATION_TTS_BEARER_TOKEN must contain at least 24 characters")
    parent_pid = configured_parent_pid()
    # Ensure neither model loading nor inference can fetch an unpinned revision.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    temp_dir = Path(os.environ.get("LOCAL_DICTATION_TTS_TEMP_DIR", default_model_dir().parent / "TTSJobs"))
    temp_dir.mkdir(parents=True, exist_ok=True)
    server = TTSServer(("127.0.0.1", port), Worker(QwenRuntime(default_model_dir())), token, temp_dir)
    print(json.dumps({"ready": True, "port": server.server_port, "protocol": PROTOCOL_VERSION}), flush=True)
    stop = threading.Event()

    if parent_pid is not None:
        def watch_parent() -> None:
            while not stop.wait(0.5):
                if not parent_is_current(parent_pid):
                    print("TTS worker parent exited; shutting down.", file=sys.stderr, flush=True)
                    server.worker.cancel(None)
                    threading.Thread(target=server.shutdown, daemon=True).start()
                    return
        threading.Thread(target=watch_parent, name="tts-parent-watchdog", daemon=True).start()

    def shutdown(_signal: int, _frame: Any) -> None:
        stop.set()
        server.worker.cancel(None)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Local Dictation MLX Qwen TTS worker")
    parser.add_argument("--port", type=int, default=int(os.environ.get("LOCAL_DICTATION_TTS_PORT", "0")))
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        raise SystemExit("port must be between 0 and 65535")
    run_server(args.port)


if __name__ == "__main__":
    main()
