"""HTTP-Dienst: lokale ASR transkribiert, OpenAI oder Qwen formuliert."""

from __future__ import annotations

import contextlib
import json
import os
import queue
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote_plus

from flow_engine.openai_polish import complete_chain, model_catalog
from flow_engine.polish import (
    apply_dictionary,
    build_messages,
    clean_output,
    clip_glossary,
    token_budget,
    weighted_terms,
)
from flow_engine.transcribe import (
    needs_warmup,
    resolve_asr_engine,
    resolve_asr_quality,
    transcribe_parakeet,
    transcribe_qwen3,
    transcribe_wav,
    transcribe_wav_timed,
    transcribe_whistle,
    warmup,
    warmup_parakeet,
    warmup_qwen3,
    warmup_whistle,
    whisper_model_for_quality,
)

DEFAULT_MODEL = str(Path.home() / "Models" / "Qwen3.8-27B-Uncensored-MLX" / "4-bit")
DEFAULT_WHISPER = "mlx-community/whisper-large-v3-turbo"
DEFAULT_ASR_ENGINE = "whisper"
DEFAULT_POLISH_PROVIDER = "openai"
DEFAULT_PORT = 17321
MAX_AUDIO = 30_000_000


def support_dir() -> Path:
    override = os.environ.get("FLOW_SUPPORT")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "Sinthex Flow"


def configure_cache() -> None:
    """ASR-Gewichte liegen im Sinthex-Flow-Ordner, nicht im allgemeinen Hugging-Face-Cache."""
    root = support_dir() / "models"
    hub = root / "hub"
    hub.mkdir(parents=True, exist_ok=True)
    os.environ["HF_HOME"] = str(root)
    os.environ["HF_HUB_CACHE"] = str(hub)
    os.environ["HUGGINGFACE_HUB_CACHE"] = str(hub)
    os.environ["FLOW_MODELS"] = str(root)
    os.environ.setdefault("NEEDLE_TELEMETRY", "0")


def _query_value(path: str, key: str, default: str = "") -> str:
    if "?" not in path:
        return default
    prefix = key + "="
    for part in path.split("?", 1)[1].split("&"):
        if part.startswith(prefix):
            return unquote_plus(part.split("=", 1)[1])
    return default


def _live_prompt(glossary: str, hint: str) -> str:
    """Wörterbuch vorn, der schon eingefügte Rohtext hinten. Whisper behält den Anfang."""
    hint = " ".join((hint or "").split())
    if not hint:
        return glossary
    tail = hint[-600:]
    head = (glossary or "")[:180].strip()
    if not head:
        return tail
    return f"{head}\n{tail}"


def read_config() -> dict:
    path = support_dir() / "config.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def prepare_metal() -> None:
    import mlx.core as mx

    memory = int(mx.device_info().get("memory_size", 0))
    if memory:
        mx.set_wired_limit(max(memory - 12 * 1024**3, memory // 2))


class Engine:
    def __init__(self) -> None:
        self.ready = False
        self.error: str | None = None
        self.model_path = ""
        self.polish_provider = DEFAULT_POLISH_PROVIDER
        # The language model is optional: without it Flow still dictates with Whisper only.
        self.polish_ready = False
        self.polish_error: str | None = None
        self._model = None
        self._processor = None
        self._cache = None
        self._lock = threading.Lock()
        self._last_touch = 0.0

    def load(self) -> None:
        config = read_config()
        self.model_path = os.path.expanduser(config.get("modelPath") or DEFAULT_MODEL)
        self.polish_provider = (config.get("polishProvider") or DEFAULT_POLISH_PROVIDER).strip()
        asr = resolve_asr_engine(config.get("asrEngine") or DEFAULT_ASR_ENGINE)
        quality = resolve_asr_quality(config.get("asrQuality"))
        whisper_model = config.get("whisperModel") or whisper_model_for_quality(quality)
        # Die Korrektur blockiert den Start nicht. Die Spracherkennung wird immer zuerst bereit.
        if self.polish_provider == "openai":
            self.polish_ready = True
            self.polish_error = None
        else:
            self.polish_ready = False

        if asr == "whistle":
            print(f"Lade Whistle (Qualität {quality})", flush=True)
            warmup_whistle(quality=quality)
            print("Whistle bereit", flush=True)
        elif asr == "parakeet":
            print("Lade Parakeet TDT 0.6B v3", flush=True)
            warmup_parakeet()
            print("Parakeet bereit", flush=True)
        elif asr == "qwen3":
            print("Lade Qwen3-ASR 0.6B", flush=True)
            warmup_qwen3()
            print("Qwen3-ASR bereit", flush=True)
        else:
            print(f"Lade Whisper {whisper_model}", flush=True)
            warmup(whisper_model)
            print("Whisper bereit", flush=True)
        self._last_touch = time.perf_counter()
        self.ready = True

    def _load_language_model(self) -> None:
        if not Path(self.model_path).joinpath("config.json").exists():
            raise FileNotFoundError(f"Sprachmodell nicht gefunden: {self.model_path}")

        from mlx_vlm import load
        from mlx_vlm.generate.common import PromptCacheState

        started = time.perf_counter()
        print(f"Lade Qwen aus {self.model_path}", flush=True)
        self._model, self._processor = load(self.model_path)
        self._cache = PromptCacheState()
        self.polish_ready = True
        print(f"Qwen geladen in {time.perf_counter() - started:.1f}s", flush=True)

    def transcribe(self, wav: bytes, language: str, prompt: str = "", timed: bool = False) -> dict:
        with self._lock:
            if not self.ready:
                raise RuntimeError(self.error or "Modell wird noch geladen")
            config = read_config()
            terms = weighted_terms(config.get("dictionary") or "")
            glossary = clip_glossary(terms)
            lang = language or config.get("language") or "auto"
            asr = resolve_asr_engine(config.get("asrEngine") or DEFAULT_ASR_ENGINE)
            quality = resolve_asr_quality(config.get("asrQuality"))
            ends = None
            if asr == "whistle":
                text, detected = transcribe_whistle(
                    wav, lang, keywords=terms, quality=quality
                )
            elif asr == "parakeet":
                text, detected = transcribe_parakeet(wav, lang)
            elif asr == "qwen3":
                text, detected = transcribe_qwen3(wav, lang)
            elif timed:
                text, detected, ends = transcribe_wav_timed(
                    wav,
                    config.get("whisperModel") or whisper_model_for_quality(quality),
                    lang,
                    _live_prompt(glossary, prompt),
                )
            else:
                text, detected = transcribe_wav(
                    wav,
                    config.get("whisperModel") or whisper_model_for_quality(quality),
                    lang,
                    _live_prompt(glossary, prompt),
                )
            self._last_touch = time.perf_counter()
            reply = {"text": text, "language": detected}
            if ends:
                reply["ends"] = ends
            return reply

    def touch(self, _payload=None) -> dict:
        """Kurzer ASR-Durchlauf, damit die Gewichte vor dem Diktat wieder im Speicher sind."""
        with self._lock:
            if not self.ready:
                return {"ok": False}
            now = time.perf_counter()
            if not needs_warmup(self._last_touch, now):
                return {"ok": True, "skipped": True}
            config = read_config()
            asr = resolve_asr_engine(config.get("asrEngine") or DEFAULT_ASR_ENGINE)
            quality = resolve_asr_quality(config.get("asrQuality"))
            started = time.perf_counter()
            if asr == "whistle":
                warmup_whistle(quality=quality)
                label = "Whistle"
            elif asr == "parakeet":
                warmup_parakeet()
                label = "Parakeet"
            elif asr == "qwen3":
                warmup_qwen3()
                label = "Qwen3-ASR"
            else:
                warmup(config.get("whisperModel") or whisper_model_for_quality(quality))
                label = "Whisper"
            elapsed = time.perf_counter() - started
            self._last_touch = time.perf_counter()
            print(f"{label} aufgewärmt in {elapsed:.1f}s", flush=True)
            return {"ok": True, "ms": int(elapsed * 1000)}

    def uses_remote_polish(self, payload: dict) -> bool:
        provider = (payload.get("provider") or read_config().get("polishProvider") or self.polish_provider)
        return str(provider).strip() == "openai"

    def polish(self, payload: dict) -> dict:
        # Eine Online-Korrektur wartet nur auf das Netz. Sie darf weder die Erkennung
        # noch eine zweite Korrektur aufhalten, sonst stockt Flow Stream.
        remote = self.uses_remote_polish(payload)
        with (contextlib.nullcontext() if remote else self._lock):
            if not self.ready:
                raise RuntimeError(self.error or "Modell wird noch geladen")
            raw = (payload.get("raw") or "").strip()
            if not raw:
                return {"text": ""}
            selection = payload.get("selection") or None
            if isinstance(selection, str):
                selection = selection.strip() or None
            note_answer = bool(payload.get("noteAnswer"))
            if selection and len(selection) > 20000:
                selection = selection[:20000] if note_answer else None
            style = payload.get("style") or "auto"
            instructions = payload.get("instructions") or ""
            dictionary = payload.get("dictionary") or ""
            target = payload.get("targetLanguage") or None
            if isinstance(target, str):
                target = target.strip() or None
            # Feste Ersetzungen vor der Korrektur, damit das Modell den Namen nicht zurückschreibt.
            # Nahe Schreibweisen nur beim normalen Diktat, nicht in Markierung oder Übersetzung.
            fuzzy = not (selection or target or note_answer)
            raw = apply_dictionary(raw, dictionary, fuzzy=fuzzy)
            messages = build_messages(
                raw, selection, style, instructions, dictionary,
                target_language=target, note_answer=note_answer,
            )
            provider = (payload.get("provider") or read_config().get("polishProvider") or self.polish_provider).strip()
            budget_raw = selection if target else raw
            budget = token_budget(budget_raw or raw, None if target else selection)
            if note_answer:
                budget = min(budget, 500)
            started = time.perf_counter()
            if provider == "openai":
                endpoints = payload.get("endpoints")
                if not isinstance(endpoints, list) or not endpoints:
                    endpoints = [{
                        "model": str(payload.get("resolvedModel") or payload.get("openAIModel") or "auto"),
                        "apiKey": str(payload.get("apiKey") or ""),
                        "baseURL": str(payload.get("baseURL") or ""),
                    }]
                text, model = complete_chain(messages, endpoints, budget)
                elapsed = time.perf_counter() - started
                print(f"Korrektur {model} in {elapsed:.1f}s", flush=True)
            else:
                if not self.polish_ready or self._model is None or self._processor is None:
                    raise RuntimeError(self.polish_error or "Sprachmodell nicht verfügbar")
                text = self._generate_local(messages, budget)
                elapsed = time.perf_counter() - started
                print(f"Lokal formuliert in {elapsed:.1f}s", flush=True)
            text = apply_dictionary(clean_output(text), dictionary, fuzzy=fuzzy).strip()
            return {"text": text}

    def _generate_local(self, messages: list[dict[str, str]], max_tokens: int) -> str:
        prompt = self._format(messages)
        from mlx_vlm import generate

        result = generate(
            self._model,
            self._processor,
            prompt,
            max_tokens=max_tokens,
            temperature=0.2,
            top_p=0.9,
            top_k=20,
            verbose=False,
            enable_thinking=False,
            prompt_cache_state=self._cache,
        )
        print(
            f"{getattr(result, 'generation_tokens', '?')} Tokens, "
            f"{getattr(result, 'generation_tps', 0):.1f} tok/s",
            flush=True,
        )
        return result.text if hasattr(result, "text") else str(result)

    def _format(self, messages: list[dict[str, str]]) -> str:
        processor = self._processor
        tokenizer = processor.tokenizer if hasattr(processor, "tokenizer") else processor
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )


ENGINE = Engine()
JOBS: queue.Queue = queue.Queue()


def worker_loop() -> None:
    try:
        configure_cache()
        prepare_metal()
        ENGINE.load()
    except Exception as exc:  # noqa: BLE001
        ENGINE.error = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()
    while True:
        job = JOBS.get()
        if job is None:
            return
        function, payload, box = job
        try:
            box.put((True, function(payload)))
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            box.put((False, exc))


def keepwarm_loop() -> None:
    # Hält die Gewichte resident, solange der Mac wach ist. Nach dem Aufwachen
    # übernimmt das Aufwärmen beim Tastendruck, weil der Schlaf diesen Takt aussetzt.
    while True:
        time.sleep(120)
        if not ENGINE.ready:
            continue
        try:
            call_model(ENGINE.touch, None, timeout=180)
        except Exception:  # noqa: BLE001
            traceback.print_exc()


def call_model(function, payload, timeout: float = 240):
    box: queue.Queue = queue.Queue()
    JOBS.put((function, payload, box))
    ok, value = box.get(timeout=timeout)
    if not ok:
        raise value
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print("HTTP", fmt % args, flush=True)

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/health":
            self._send(404, {"error": "nicht gefunden"})
            return
        self._send(
            200,
            {
                "ready": ENGINE.ready,
                "error": ENGINE.error,
                "model": ENGINE.model_path,
                "polish": ENGINE.polish_ready,
                "polishError": ENGINE.polish_error,
            },
        )

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length", "0"))
        if length > MAX_AUDIO:
            self._send(413, {"error": "Audio ist zu groß"})
            return
        raw = self.rfile.read(length) if length else b""
        try:
            if path == "/shutdown":
                self._send(200, {"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if path == "/correction-model":
                payload = json.loads(raw.decode("utf-8") or "{}")
                recommended, models = model_catalog(
                    str(payload.get("apiKey") or ""),
                    base_url=str(payload.get("baseURL") or ""),
                )
                self._send(200, {"model": recommended, "models": models})
                return
            if not ENGINE.ready:
                self._send(503, {"error": ENGINE.error or "Modell wird noch geladen"})
                return
            if path == "/warmup":
                self._send(200, call_model(ENGINE.touch, None, timeout=180))
                return
            if path == "/transcribe":
                language = _query_value(self.path, "language", "auto") or "auto"
                prompt = _query_value(self.path, "prompt", "")
                timed = _query_value(self.path, "timed", "") == "1"
                self._send(
                    200,
                    call_model(
                        lambda body, lang=language, hint=prompt, t=timed: ENGINE.transcribe(body, lang, hint, t),
                        raw,
                    ),
                )
                return
            if path == "/polish":
                payload = json.loads(raw.decode("utf-8") or "{}")
                if ENGINE.uses_remote_polish(payload):
                    # Direkt im Anfrage-Thread: Netzwartezeit blockiert die Modell-Warteschlange nicht.
                    self._send(200, ENGINE.polish(payload))
                else:
                    self._send(200, call_model(ENGINE.polish, payload))
                return
            self._send(404, {"error": "nicht gefunden"})
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            code = 503 if not ENGINE.ready else 500
            self._send(code, {"error": str(exc)})


def serve() -> None:
    configure_cache()
    config = read_config()
    port = int(config.get("port") or DEFAULT_PORT)
    directory = support_dir()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "engine.pid").write_text(str(os.getpid()), encoding="utf-8")
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Flow-Engine auf 127.0.0.1:{port}", flush=True)
    threading.Thread(target=worker_loop, name="mlx", daemon=True).start()
    threading.Thread(target=keepwarm_loop, name="warm", daemon=True).start()
    try:
        server.serve_forever()
    finally:
        server.server_close()


def self_test() -> None:
    if (read_config().get("polishProvider") or DEFAULT_POLISH_PROVIDER) == "openai":
        print("Selbsttest übersprungen: Korrektur läuft über OpenAI.", flush=True)
        return
    prepare_metal()
    ENGINE.load()
    samples = [
        "ähm also ich wollte nur kurz sagen dass wir das meeting auf morgen um zehn verschieben",
        "bitte schick das an VEMA und setz Dieter in Kopie",
    ]
    for sample in samples:
        result = ENGINE.polish(
            {
                "raw": sample,
                "style": "auto",
                "instructions": "",
                "dictionary": "VEMA\nDieter",
            }
        )
        text = result["text"]
        print("IN ", sample, flush=True)
        print("OUT", text, flush=True)
        if not text.strip():
            raise SystemExit("Leere Formulierung")
        if "<think>" in text.lower():
            raise SystemExit("Denkblock wurde nicht entfernt")
    import mlx.core as mx

    print(f"Spitze {mx.get_peak_memory() / 1e9:.1f} GB", flush=True)
