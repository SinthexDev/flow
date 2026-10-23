"""Spracherkennung lokal: Whisper, Whistle, Parakeet oder Qwen3-ASR, ohne ffmpeg."""

from __future__ import annotations

import io
import os
import re
import zlib
import wave
from pathlib import Path

import numpy as np

_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)

# YouTube/subtitle leftovers Whisper often invents on silence or after the last word.
_HARD_HALLUCINATIONS = (
    r"untertitel(?:ung)?(?:\s+der)?\s+amara(?:\.org)?(?:[-\s]?community)?",
    r"untertitel(?:ung)?(?:\s+im\s+auftrag)?(?:\s+des)?\s+zdf(?:\s+f(?:ü|ue)r\s+funk)?(?:[,\s]+\d{4})?",
    r"untertitel von [^\n.!?]+",
    r"untertitelung des zdf[^\n.!?]*",
    r"mit untertiteln von swiss\s*txt",
    r"copyright\s+wdr",
    r"thanks for watching\.?",
    r"thank you for watching\.?",
    r"vielen dank f(?:ü|ue)rs?\s+zuschauen\.?",
    r"danke f(?:ü|ue)rs?\s+zuschauen\.?",
)
_HARD_HALLUCINATION_RE = re.compile(
    r"(?:^|\s+)(?:" + "|".join(f"(?:{_})" for _ in _HARD_HALLUCINATIONS) + r")\.?\s*",
    re.IGNORECASE,
)

# Short closers Whisper appends after real speech. Kept when they are the whole text.
_TRAILING_HALLUCINATIONS = (
    r"vielen dank",
    r"danke sch(?:ö|oe)n",
    r"danke",
    r"thank you",
    r"thanks",
)
_TRAILING_HALLUCINATION_RE = re.compile(
    r"(?:(?<=[.!?…])|[\"'”’)\]])\s*(?:"
    + "|".join(_TRAILING_HALLUCINATIONS)
    + r")\.?\s*$"
    r"|"
    r"(?<=\w)\s+(?:"
    + "|".join(_TRAILING_HALLUCINATIONS)
    + r")\.?\s*$",
    re.IGNORECASE,
)


def wav_to_audio(wav: bytes) -> np.ndarray:
    with wave.open(io.BytesIO(wav), "rb") as handle:
        channels = handle.getnchannels()
        sample_width = handle.getsampwidth()
        rate = handle.getframerate()
        frames = handle.readframes(handle.getnframes())
    if sample_width != 2:
        raise ValueError("Audio muss 16-bit PCM sein")
    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    if rate != 16000 and len(audio) > 1:
        target = max(1, int(len(audio) * 16000 / rate))
        source_x = np.linspace(0.0, 1.0, num=len(audio), endpoint=False)
        target_x = np.linspace(0.0, 1.0, num=target, endpoint=False)
        audio = np.interp(target_x, source_x, audio).astype(np.float32)
    return np.ascontiguousarray(audio)


def write_silence(seconds: float = 0.4, sample_rate: int = 16000) -> bytes:
    frames = int(seconds * sample_rate)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"\x00\x00" * frames)
    return buffer.getvalue()


def looks_repetitive(text: str) -> bool:
    """Whisper often loops short phrases on silence, e.g. 'Das, mein, das, mein…'."""
    normalized = text.strip().lower()
    if len(normalized) < 12:
        return False
    words = _WORD_RE.findall(normalized)
    if len(words) >= 6:
        unique = len(set(words))
        if unique <= 2 and len(words) >= 6:
            return True
        if unique <= 3 and len(words) >= 12:
            return True
        for size in (1, 2, 3, 4):
            if len(words) < size * 3:
                continue
            pattern = words[:size]
            index = 0
            matched = 0
            while index + size <= len(words) and words[index : index + size] == pattern:
                matched += 1
                index += size
            if matched >= 3 and index / len(words) >= 0.7:
                return True
    raw = normalized.encode("utf-8")
    if len(raw) >= 40:
        ratio = len(raw) / max(1, len(zlib.compress(raw, 9)))
        if ratio >= 3.0:
            return True
    return False


def is_near_silence(audio: np.ndarray, peak_threshold: float = 0.012) -> bool:
    if audio.size == 0:
        return True
    return float(np.max(np.abs(audio))) < peak_threshold


def strip_hallucinations(text: str) -> str:
    """Drop subtitle junk and trailing closers Whisper invents after real speech."""
    cleaned = text.strip()
    if not cleaned:
        return ""
    cleaned = _HARD_HALLUCINATION_RE.sub(" ", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip(" \t\r\n,;:-")
    # Only strip closers when other words remain – solo "Vielen Dank" stays.
    while True:
        next_text = _TRAILING_HALLUCINATION_RE.sub("", cleaned).strip(" \t\r\n,;:-")
        if next_text == cleaned:
            break
        if not next_text:
            break
        cleaned = next_text
    return cleaned.strip()


_WRAP_QUOTE_PAIRS = (
    ('"', '"'),
    ("'", "'"),
    ("„", "“"),
    ("«", "»"),
    ("‚", "‘"),
    ("“", "”"),
    ("‘", "’"),
)
# Quotes Whisper glues onto a single word: "Rechnung", „Hallo“, Rechnung"
_WORD_QUOTE_RE = re.compile(
    r"(?<!\w)[\"'„«‚“‘]\s*([^\s\"'„“»‚‘’]+)\s*[\"'“»‘’]",
)
_ORPHAN_LEADING_QUOTE_RE = re.compile(r"^[\"'„«‚“‘]\s*")
_ORPHAN_TRAILING_QUOTE_RE = re.compile(r"\s*[\"'“»‘’]$")


def strip_spurious_quotes(text: str) -> str:
    """Remove quotes Whisper invents around short dictation, keep real pairs in longer text."""
    cleaned = text.strip()
    if not cleaned:
        return ""
    changed = True
    while changed:
        changed = False
        for left, right in _WRAP_QUOTE_PAIRS:
            if (
                len(cleaned) >= len(left) + len(right)
                and cleaned.startswith(left)
                and cleaned.endswith(right)
            ):
                inner = cleaned[len(left) : len(cleaned) - len(right)].strip()
                if inner and left not in inner and right not in inner:
                    cleaned = inner
                    changed = True
                    break
        next_text = _WORD_QUOTE_RE.sub(r"\1", cleaned)
        if next_text != cleaned:
            cleaned = next_text
            changed = True
    cleaned = _ORPHAN_LEADING_QUOTE_RE.sub("", cleaned)
    cleaned = _ORPHAN_TRAILING_QUOTE_RE.sub("", cleaned)
    return cleaned.strip()


def strip_short_utterance_period(text: str) -> str:
    """A lone spoken word should not become 'Wort.' – Whisper often adds that period."""
    cleaned = text.strip()
    words = _WORD_RE.findall(cleaned)
    if len(words) != 1:
        return cleaned
    # Keep abbreviations like "z.B." / "usw."
    if re.search(r"[A-Za-zÄÖÜäöüß]\.[A-Za-zÄÖÜäöüß]", cleaned):
        return cleaned
    return re.sub(r"^(.+?)\s*[.。]\s*$", r"\1", cleaned).strip()


def normalize_dictation_text(text: str) -> str:
    cleaned = strip_hallucinations(text)
    cleaned = strip_spurious_quotes(cleaned)
    cleaned = strip_short_utterance_period(cleaned)
    return cleaned.strip()


def discard_transcript(segments: list, text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    if looks_repetitive(stripped):
        return True
    if segments and all(float(segment.get("no_speech_prob", 0)) >= 0.6 for segment in segments):
        return True
    if (
        segments
        and any(float(segment.get("compression_ratio", 0)) >= 2.4 for segment in segments)
        and looks_repetitive(stripped)
    ):
        return True
    return False


WHISTLE_LANGUAGES = ("en", "de", "fr", "es", "it", "nl", "pl")
PARAKEET_LANGUAGES = (
    "bg",
    "hr",
    "cs",
    "da",
    "nl",
    "en",
    "et",
    "fi",
    "fr",
    "de",
    "el",
    "hu",
    "it",
    "lv",
    "lt",
    "mt",
    "pl",
    "pt",
    "ro",
    "ru",
    "sk",
    "sl",
    "es",
    "sv",
    "uk",
)
QWEN3_LANGUAGES = (
    "zh",
    "en",
    "yue",
    "ar",
    "de",
    "fr",
    "es",
    "pt",
    "id",
    "it",
    "ko",
    "ru",
    "th",
    "vi",
    "ja",
    "tr",
    "hi",
    "ms",
    "nl",
    "sv",
    "da",
    "fi",
    "pl",
    "cs",
    "fil",
    "fa",
    "el",
    "hu",
    "mk",
    "ro",
)
WHISTLE_MAX_SECONDS = 30
WHISTLE_SAMPLE_RATE = 16_000
WHISTLE_CHUNK_SAMPLES = WHISTLE_SAMPLE_RATE  # ~1 s for the streaming path
ASR_QUALITY_MAX = 4
ASR_ENGINES = ("whisper", "whistle", "parakeet", "qwen3")
PARAKEET_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
QWEN3_MODEL = "Qwen/Qwen3-ASR-0.6B"
# Low → High. Whistle depth is selected at load via the native CLI (--audio-depth).
WHISTLE_DEPTHS = (2, 3, 4, 6, 8)
WHISPER_MODELS = (
    "mlx-community/whisper-tiny",
    "mlx-community/whisper-base-mlx",
    "mlx-community/whisper-small-mlx",
    "mlx-community/whisper-medium-mlx",
    "mlx-community/whisper-large-v3-turbo",
)

_parakeet_model = None
_parakeet_model_id = ""
_qwen3_session = None
_qwen3_model_id = ""


def resolve_asr_engine(value: str | None) -> str:
    engine = (value or "whisper").strip().lower()
    return engine if engine in ASR_ENGINES else "whisper"


def resolve_asr_quality(value: object | None) -> int:
    try:
        quality = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        quality = ASR_QUALITY_MAX
    return max(0, min(ASR_QUALITY_MAX, quality))


def whistle_depth_for_quality(quality: object | None) -> int:
    return WHISTLE_DEPTHS[resolve_asr_quality(quality)]


def whisper_model_for_quality(quality: object | None) -> str:
    return WHISPER_MODELS[resolve_asr_quality(quality)]


def whistle_language(language: str | None) -> str | None:
    code = (language or "").strip().lower()
    if not code or code == "auto":
        return None
    return code if code in WHISTLE_LANGUAGES else None


def default_models_dir() -> str:
    override = os.environ.get("FLOW_MODELS")
    if override:
        return override
    support = os.environ.get("FLOW_SUPPORT")
    if support:
        return str(Path(support) / "models")
    return str(Path.home() / "Library" / "Application Support" / "Sinthex Flow" / "models")


def ensure_whistle_weights(models_dir: str | None = None) -> str:
    """Download whistle.cact once into the Sinthex-Flow models folder."""
    os.environ.setdefault("NEEDLE_TELEMETRY", "0")
    from needle.agent import fetch

    dest = Path(models_dir or default_models_dir())
    dest.mkdir(parents=True, exist_ok=True)
    weights = dest / "whistle.cact"
    if weights.exists() and weights.stat().st_size > 0:
        return str(weights)
    return fetch.fetch_weights(fetch.WHISTLE, dest_dir=str(dest))


def ensure_needle_binary(models_dir: str | None = None) -> str:
    """Native needle CLI: only this exposes Whistle --audio-depth."""
    os.environ.setdefault("NEEDLE_TELEMETRY", "0")
    dest = Path(models_dir or default_models_dir()) / "needle"
    dest.mkdir(parents=True, exist_ok=True)
    binary = dest / "needle"
    if binary.exists() and os.access(binary, os.X_OK) and binary.stat().st_size > 0:
        return str(binary)
    from huggingface_hub import hf_hub_download
    from needle.agent import fetch
    import shutil
    import stat

    cached = hf_hub_download(
        repo_id=fetch.engine_repo(3),
        filename="macos-arm64/needle",
        repo_type="model",
    )
    shutil.copyfile(cached, binary)
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(binary)


def _join_whistle_stream(steps: list[dict]) -> tuple[str, str]:
    parts: list[str] = []
    language_out = ""
    pending = ""
    for step in steps:
        language_out = step.get("language") or language_out
        text = (step.get("text") or "").strip()
        if text:
            parts.append(text)
        pending = (step.get("pending") or "").strip()
    if pending:
        parts.append(pending)
    return " ".join(parts).strip(), language_out


def _run_whistle_cli(
    wav_path: str,
    *,
    weights: str,
    binary: str,
    depth: int,
    language: str | None,
    keywords_path: str | None,
    stream: bool,
) -> dict:
    import json
    import subprocess

    command = [
        binary,
        "--model",
        weights,
        "--audio",
        wav_path,
        "--audio-depth",
        str(depth),
    ]
    if language:
        command.extend(["--audio-language", language])
    if keywords_path:
        command.extend(["--audio-keywords", keywords_path])
    if stream:
        command.append("--audio-stream")
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() or f"exit {result.returncode}"
        raise RuntimeError(f"Whistle CLI fehlgeschlagen: {detail}")
    lines = [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]
    if not lines:
        return {"text": "", "language": ""}
    if not stream:
        return json.loads(lines[-1])
    steps = [json.loads(line) for line in lines]
    text, language_out = _join_whistle_stream(steps)
    return {"text": text, "language": language_out}


def transcribe_whistle(
    wav: bytes,
    language: str,
    keywords: list[str] | None = None,
    models_dir: str | None = None,
    quality: object | None = None,
) -> tuple[str, str]:
    """Whistle STT via the native CLI so --audio-depth (quality) is available."""
    import tempfile

    audio = wav_to_audio(wav)
    if is_near_silence(audio):
        return "", ""

    root = models_dir or default_models_dir()
    weights = ensure_whistle_weights(root)
    binary = ensure_needle_binary(root)
    depth = whistle_depth_for_quality(quality)
    lang = whistle_language(language)
    kw = [term for term in (keywords or []) if term]
    max_samples = WHISTLE_MAX_SECONDS * WHISTLE_SAMPLE_RATE
    stream = len(audio) > max_samples

    with tempfile.TemporaryDirectory(prefix="flow-whistle-") as tmp:
        tmp_dir = Path(tmp)
        wav_path = tmp_dir / "clip.wav"
        with wave.open(str(wav_path), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(WHISTLE_SAMPLE_RATE)
            pcm = np.clip(audio * 32767.0, -32768, 32767).astype("<i2")
            handle.writeframes(pcm.tobytes())
        keywords_path = None
        if kw:
            keywords_file = tmp_dir / "keywords.txt"
            keywords_file.write_text("\n".join(kw), encoding="utf-8")
            keywords_path = str(keywords_file)
        result = _run_whistle_cli(
            str(wav_path),
            weights=weights,
            binary=binary,
            depth=depth,
            language=lang,
            keywords_path=keywords_path,
            stream=stream,
        )

    language_out = result.get("language") or ""
    text = normalize_dictation_text((result.get("text") or "").strip())
    if discard_transcript([], text):
        return "", language_out
    return text, language_out


def _impulse_audio(seconds: float = 1.0) -> np.ndarray:
    samples = max(1, int(seconds * WHISTLE_SAMPLE_RATE))
    audio = np.zeros(samples, dtype=np.float32)
    audio[80:160] = 0.04
    return audio


def _get_parakeet(model_id: str = PARAKEET_MODEL):
    global _parakeet_model, _parakeet_model_id
    if _parakeet_model is None or _parakeet_model_id != model_id:
        from parakeet_mlx import from_pretrained

        _parakeet_model = from_pretrained(model_id)
        _parakeet_model_id = model_id
    return _parakeet_model


def _get_qwen3(model_id: str = QWEN3_MODEL):
    global _qwen3_session, _qwen3_model_id
    if _qwen3_session is None or _qwen3_model_id != model_id:
        from mlx_qwen3_asr import Session

        _qwen3_session = Session(model=model_id)
        _qwen3_model_id = model_id
    return _qwen3_session


def parakeet_language(language: str | None) -> str | None:
    code = (language or "").strip().lower()
    if not code or code == "auto":
        return None
    return code if code in PARAKEET_LANGUAGES else None


def qwen3_language(language: str | None) -> str | None:
    code = (language or "").strip().lower()
    if not code or code == "auto":
        return None
    return code if code in QWEN3_LANGUAGES else None


def _parakeet_from_audio(audio: np.ndarray, model_id: str = PARAKEET_MODEL):
    """Decode PCM without ffmpeg (parakeet-mlx's file loader always shells out)."""
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    model = _get_parakeet(model_id)
    minimum = int(getattr(model.preprocessor_config, "hop_length", 1) or 1)
    if len(audio) < minimum:
        padded = np.zeros(minimum, dtype=np.float32)
        padded[: len(audio)] = audio
        audio = padded
    mel = get_logmel(mx.array(audio), model.preprocessor_config)
    return model.generate(mel)[0]


def transcribe_parakeet(
    wav: bytes,
    language: str = "auto",
    model_id: str = PARAKEET_MODEL,
) -> tuple[str, str]:
    """Parakeet TDT 0.6B v3 via MLX. Language is auto-detected; `language` is unused."""
    del language  # Parakeet v3 detects language; kept for a stable call shape.
    audio = wav_to_audio(wav)
    if is_near_silence(audio):
        return "", ""

    result = _parakeet_from_audio(audio, model_id)
    text = normalize_dictation_text((getattr(result, "text", None) or str(result) or "").strip())
    if discard_transcript([], text):
        return "", ""
    return text, ""


def transcribe_qwen3(
    wav: bytes,
    language: str = "auto",
    model_id: str = QWEN3_MODEL,
) -> tuple[str, str]:
    """Qwen3-ASR 0.6B via MLX."""
    audio = wav_to_audio(wav)
    if is_near_silence(audio):
        return "", ""

    session = _get_qwen3(model_id)
    forced = qwen3_language(language)
    result = session.transcribe(
        (audio, WHISTLE_SAMPLE_RATE),
        language=forced,
    )
    language_out = (getattr(result, "language", None) or "").strip()
    text = normalize_dictation_text((getattr(result, "text", None) or "").strip())
    if discard_transcript([], text):
        return "", language_out
    return text, language_out


def warmup_parakeet(model_id: str = PARAKEET_MODEL) -> None:
    _parakeet_from_audio(_impulse_audio(), model_id)


def warmup_qwen3(model_id: str = QWEN3_MODEL) -> None:
    session = _get_qwen3(model_id)
    session.transcribe((_impulse_audio(), WHISTLE_SAMPLE_RATE), language="de")


def _whisper_options(
    model_id: str,
    language: str,
    initial_prompt: str,
    word_timestamps: bool = False,
) -> dict:
    options: dict = {
        "path_or_hf_repo": model_id,
        "verbose": False,
        "condition_on_previous_text": False,
        # One greedy pass. A temperature ladder decodes the clip again when the
        # first pass looks uncertain, which is the pause after the words are known.
        # mlx-whisper has no beam search: any beam_size, including 1, raises
        # NotImplementedError. Leaving it unset keeps the greedy decoder.
        "temperature": 0.0,
        "without_timestamps": True,
        "word_timestamps": word_timestamps,
        "no_speech_threshold": 0.6,
        "compression_ratio_threshold": 2.4,
    }
    if language and language != "auto":
        options["language"] = language
    prompt = initial_prompt.strip()
    if len(prompt) > 800:
        cut = prompt.rfind(", ", 0, 801)
        prompt = prompt[:cut] if cut > 0 else prompt[:800]
    if prompt:
        options["initial_prompt"] = prompt
    return options


def transcribe_wav(
    wav: bytes,
    model_id: str,
    language: str,
    initial_prompt: str,
) -> tuple[str, str]:
    import mlx_whisper

    audio = wav_to_audio(wav)
    if is_near_silence(audio):
        return "", ""

    result = mlx_whisper.transcribe(audio, **_whisper_options(model_id, language, initial_prompt))

    segments = result.get("segments") or []
    language_out = result.get("language") or ""
    text = normalize_dictation_text((result.get("text") or "").strip())
    if discard_transcript(segments, text):
        return "", language_out
    return text, language_out


def word_end_times(segments: list, text: str) -> list[float] | None:
    """Ende jedes Wortes in Sekunden. Nur wenn die Wortzahl exakt zum Text passt."""
    ends: list[float] = []
    for segment in segments or []:
        for word in segment.get("words") or []:
            if not str(word.get("word", "")).strip():
                continue
            end = word.get("end")
            if end is None:
                return None
            ends.append(round(float(end), 3))
    if not ends or len(ends) != len(text.split()):
        return None
    return ends


def transcribe_wav_timed(
    wav: bytes,
    model_id: str,
    language: str,
    initial_prompt: str,
) -> tuple[str, str, list[float] | None]:
    """Wie transcribe_wav, dazu das Ende jedes Wortes. Für Flow Stream."""
    import mlx_whisper

    audio = wav_to_audio(wav)
    if is_near_silence(audio):
        return "", "", None

    try:
        result = mlx_whisper.transcribe(
            audio, **_whisper_options(model_id, language, initial_prompt, word_timestamps=True)
        )
    except Exception:  # noqa: BLE001
        # Wortzeiten sind nur Beigabe. Ohne sie läuft die Erkennung wie bisher.
        text, language_out = transcribe_wav(wav, model_id, language, initial_prompt)
        return text, language_out, None

    segments = result.get("segments") or []
    language_out = result.get("language") or ""
    text = normalize_dictation_text((result.get("text") or "").strip())
    if discard_transcript(segments, text):
        return "", language_out, None
    return text, language_out, word_end_times(segments, text)


# After a short idle macOS pages Whisper weights out of fast memory.
# Warm sooner than before so a brief pause does not force a cold decode.
WARM_INTERVAL = 20.0


def needs_warmup(last_touch: float, now: float, interval: float = WARM_INTERVAL) -> bool:
    return last_touch <= 0 or (now - last_touch) >= interval


def warmup(model_id: str) -> None:
    """Run a real decode. Silence must not short-circuit this via is_near_silence."""
    import mlx_whisper

    # Brief impulse: loud enough to pass silence filters, too short for speech.
    audio = np.zeros(16_000, dtype=np.float32)
    audio[80:160] = 0.04
    mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=model_id,
        verbose=False,
        language="de",
        temperature=0.0,
        without_timestamps=True,
        word_timestamps=False,
        condition_on_previous_text=False,
        no_speech_threshold=0.6,
        compression_ratio_threshold=2.4,
    )


def warmup_whistle(models_dir: str | None = None, quality: object | None = None) -> None:
    """Run one short CLI decode so Whistle and the chosen depth are warm."""
    import tempfile

    root = models_dir or default_models_dir()
    weights = ensure_whistle_weights(root)
    binary = ensure_needle_binary(root)
    depth = whistle_depth_for_quality(quality)
    audio = np.zeros(WHISTLE_SAMPLE_RATE, dtype=np.float32)
    audio[80:160] = 0.04
    with tempfile.TemporaryDirectory(prefix="flow-whistle-warm-") as tmp:
        wav_path = Path(tmp) / "warm.wav"
        with wave.open(str(wav_path), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(WHISTLE_SAMPLE_RATE)
            pcm = np.clip(audio * 32767.0, -32768, 32767).astype("<i2")
            handle.writeframes(pcm.tobytes())
        _run_whistle_cli(
            str(wav_path),
            weights=weights,
            binary=binary,
            depth=depth,
            language="de",
            keywords_path=None,
            stream=False,
        )