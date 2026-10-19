import io
import json
import unittest
import urllib.error

from flow_engine.openai_polish import (
    choose_model,
    claude_message_text,
    complete,
    complete_chain,
    error_message,
    fetch_models,
    message_text,
    normalize_base_url,
    rank_models,
    reset_model_cache,
    resolve_model,
)


class _Body:
    def __init__(self, payload: bytes):
        self.payload = payload

    def read(self) -> bytes:
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def _model(model_id: str, created: int = 0) -> dict:
    return {"id": model_id, "created": created}


class OpenAIPolishTests(unittest.TestCase):
    def setUp(self):
        reset_model_cache()

    def test_message_text_reads_string_and_parts(self):
        self.assertEqual(
            message_text({"choices": [{"message": {"content": "Hallo."}}]}),
            "Hallo.",
        )
        self.assertEqual(
            message_text({"choices": [{"message": {"content": [{"text": "Hallo"}, {"text": " Welt"}]}}]}),
            "Hallo Welt",
        )

    def test_error_message_uses_api_text(self):
        raw = json.dumps({"error": {"message": "invalid api key"}})
        self.assertEqual(error_message(raw, 401), "OpenAI: invalid api key")

    def test_complete_posts_without_putting_the_key_in_the_body(self):
        def opener(request, timeout):
            self.assertEqual(timeout, 45)
            self.assertEqual(request.get_header("Authorization"), "Bearer secret-key")
            self.assertNotIn(b"secret-key", request.data)
            self.assertNotIn("secret-key", request.full_url)
            return _Body(b'{"choices":[{"message":{"content":"Morgen um zehn."}}]}')

        text = complete(
            [{"role": "user", "content": "roher text"}],
            "gpt-4.1-mini",
            "secret-key",
            40,
            opener=opener,
        )
        self.assertEqual(text, "Morgen um zehn.")

    def test_missing_key_does_not_call_the_network(self):
        def opener(request, timeout):
            raise AssertionError("Netz wurde aufgerufen")

        with self.assertRaisesRegex(RuntimeError, "fehlt"):
            complete([{"role": "user", "content": "x"}], "gpt-4.1-mini", "  ", 20, opener=opener)

    def test_http_error_is_redacted(self):
        def opener(request, timeout):
            raise urllib.error.HTTPError(
                request.full_url,
                401,
                "Unauthorized",
                hdrs=None,
                fp=io.BytesIO(b'{"error":{"message":"rejected secret-key"}}'),
            )

        with self.assertRaises(RuntimeError) as caught:
            complete(
                [{"role": "user", "content": "x"}],
                "gpt-4.1-mini",
                "secret-key",
                20,
                opener=opener,
            )
        self.assertNotIn("secret-key", str(caught.exception))
        self.assertIn("rejected", str(caught.exception))

    def test_choose_model_picks_newest_fast_tier(self):
        chosen = choose_model(
            [
                _model("whisper-large-v3"),
                _model("gpt-5.6-sol", 50),
                _model("gpt-6-astra", 90),
                _model("gpt-5-nano", 40),
                _model("gpt-5.6-luna-2026-07-30", 80),
                _model("gpt-5.6-mini", 70),
                _model("gpt-5.6-luna", 60),
                _model("gpt-4.1-mini", 10),
                _model("ft:gpt-4.1-mini", 99),
                _model("o3", 100),
            ]
        )
        self.assertEqual(chosen, "gpt-5.6-luna")

    def test_choose_model_prefers_nano_inside_the_same_generation(self):
        chosen = choose_model(
            [
                _model("gpt-5.6-luna", 2),
                _model("gpt-5.6-nano", 1),
                _model("gpt-5.6-mini", 3),
            ]
        )
        self.assertEqual(chosen, "gpt-5.6-nano")

    def test_choose_model_newer_generation_beats_an_older_nano(self):
        chosen = choose_model([_model("gpt-5-nano", 9), _model("gpt-5.6-luna", 1)])
        self.assertEqual(chosen, "gpt-5.6-luna")

    def test_choose_model_falls_back_when_no_fast_tier_exists(self):
        chosen = choose_model([_model("gpt-6-astra", 2), _model("gpt-6-sol", 1), _model("gpt-5.6-sol", 9)])
        self.assertEqual(chosen, "gpt-6-sol")

    def test_rank_models_lists_alternatives_and_skips_dated_snapshots(self):
        ranked = rank_models(
            [
                _model("whisper-1"),
                _model("gpt-5.6-luna-2026-07-30", 80),
                _model("gpt-5.6-luna", 60),
                _model("gpt-5.6-sol", 70),
                _model("gpt-4.1-mini", 10),
                _model("gpt-5-nano", 40),
            ]
        )
        self.assertEqual(ranked[0], "gpt-5.6-luna")
        self.assertIn("gpt-5.6-sol", ranked)
        self.assertIn("gpt-4.1-mini", ranked)
        self.assertNotIn("gpt-5.6-luna-2026-07-30", ranked)
        self.assertNotIn("whisper-1", ranked)

    def test_resolve_model_reads_the_list_and_caches_it(self):
        calls = {"n": 0}

        def opener(request, timeout):
            calls["n"] += 1
            self.assertEqual(timeout, 20)
            self.assertIn("/v1/models", request.full_url)
            self.assertEqual(request.get_header("Authorization"), "Bearer secret-key")
            body = json.dumps({"data": [_model("gpt-5.6-sol", 2), _model("gpt-5.6-luna", 1)]}).encode()
            return _Body(body)

        self.assertEqual(resolve_model("secret-key", opener=opener, now=100), "gpt-5.6-luna")
        self.assertEqual(resolve_model("secret-key", opener=opener, now=200), "gpt-5.6-luna")
        self.assertEqual(calls["n"], 1)

    def test_modern_model_asks_for_no_reasoning(self):
        def opener(request, timeout):
            payload = json.loads(request.data)
            self.assertEqual(payload["model"], "gpt-5.6-luna")
            self.assertEqual(payload["reasoning_effort"], "none")
            self.assertNotIn("temperature", payload)
            return _Body(b'{"choices":[{"message":{"content":"Klar."}}]}')

        text = complete([{"role": "user", "content": "x"}], "gpt-5.6-luna", "secret-key", 40, opener=opener)
        self.assertEqual(text, "Klar.")

    def test_rejected_reasoning_effort_is_retried_without_it(self):
        calls = {"n": 0}

        def opener(request, timeout):
            calls["n"] += 1
            payload = json.loads(request.data)
            if "reasoning_effort" in payload:
                raise urllib.error.HTTPError(
                    request.full_url,
                    400,
                    "Bad Request",
                    hdrs=None,
                    fp=io.BytesIO(b'{"error":{"message":"unknown parameter reasoning_effort"}}'),
                )
            self.assertEqual(payload["temperature"], 0.2)
            return _Body(b'{"choices":[{"message":{"content":"Klar."}}]}')

        text = complete([{"role": "user", "content": "x"}], "gpt-5.6-luna", "secret-key", 40, opener=opener)
        self.assertEqual(text, "Klar.")
        self.assertEqual(calls["n"], 2)

    def test_custom_base_posts_there_without_a_key(self):
        def opener(request, timeout):
            self.assertEqual(request.full_url, "http://127.0.0.1:11434/v1/chat/completions")
            self.assertIsNone(request.get_header("Authorization"))
            self.assertEqual(timeout, 90)
            payload = json.loads(request.data)
            self.assertEqual(payload["model"], "llama3.2")
            self.assertEqual(payload["max_tokens"], 40)
            self.assertNotIn("max_completion_tokens", payload)
            self.assertNotIn("reasoning_effort", payload)
            return _Body(b'{"choices":[{"message":{"content":"Morgen."}}]}')

        text = complete(
            [{"role": "user", "content": "x"}],
            "llama3.2",
            "",
            40,
            opener=opener,
            base_url="http://127.0.0.1:11434/v1/",
        )
        self.assertEqual(text, "Morgen.")

    def test_custom_catalog_lists_non_gpt_models(self):
        def opener(request, timeout):
            self.assertEqual(request.full_url, "http://127.0.0.1:1234/v1/models")
            body = json.dumps({"data": [_model("nomic-embed-text"), _model("qwen2.5"), _model("llama3.2")]}).encode()
            return _Body(body)

        self.assertEqual(
            resolve_model("", opener=opener, now=10, base_url="http://127.0.0.1:1234"),
            "qwen2.5",
        )

    def test_normalize_base_url_strips_the_endpoint_and_adds_v1(self):
        self.assertEqual(normalize_base_url(""), "https://api.openai.com/v1")
        self.assertEqual(
            normalize_base_url("https://api.openai.com/v1/chat/completions"),
            "https://api.openai.com/v1",
        )
        self.assertEqual(normalize_base_url("http://127.0.0.1:11434"), "http://127.0.0.1:11434/v1")
        with self.assertRaisesRegex(RuntimeError, "http"):
            normalize_base_url("file:///tmp/model")

    def test_complete_chain_skips_an_unreachable_endpoint(self):
        calls = {"n": 0}

        def opener(request, timeout):
            calls["n"] += 1
            if "11434" in request.full_url:
                raise urllib.error.URLError("Connection refused")
            return _Body(b'{"choices":[{"message":{"content":"Klar."}}]}')

        text, used = complete_chain(
            [{"role": "user", "content": "x"}],
            [
                {"model": "llama3.2", "apiKey": "", "baseURL": "http://127.0.0.1:11434/v1"},
                {"model": "gpt-4.1-mini", "apiKey": "secret-key", "baseURL": "https://api.openai.com/v1"},
            ],
            40,
            opener=opener,
        )
        self.assertEqual(text, "Klar.")
        self.assertEqual(calls["n"], 2)
        self.assertTrue(used)

    def test_claude_complete_uses_messages_and_x_api_key(self):
        def opener(request, timeout):
            self.assertEqual(timeout, 45)
            self.assertTrue(request.full_url.endswith("/messages"))
            self.assertEqual(request.get_header("X-api-key"), "sk-ant-secret")
            self.assertEqual(request.get_header("Anthropic-version"), "2023-06-01")
            self.assertIsNone(request.get_header("Authorization"))
            payload = json.loads(request.data.decode())
            self.assertEqual(payload["model"], "claude-haiku-4-5")
            self.assertEqual(payload["system"], "Sei knapp.")
            self.assertEqual(payload["messages"], [{"role": "user", "content": "roher text"}])
            return _Body(b'{"content":[{"type":"text","text":"Morgen um zehn."}]}')

        text = complete(
            [{"role": "system", "content": "Sei knapp."}, {"role": "user", "content": "roher text"}],
            "claude-haiku-4-5",
            "sk-ant-secret",
            40,
            opener=opener,
            base_url="https://api.anthropic.com/v1",
        )
        self.assertEqual(text, "Morgen um zehn.")

    def test_claude_message_text_joins_blocks(self):
        self.assertEqual(
            claude_message_text({"content": [{"type": "text", "text": "Hallo"}, {"type": "text", "text": " Welt"}]}),
            "Hallo Welt",
        )

    def test_choose_claude_prefers_haiku(self):
        chosen = choose_model(
            [
                {"id": "claude-opus-4-6"},
                {"id": "claude-sonnet-4-5"},
                {"id": "claude-haiku-4-5"},
            ],
            kind="claude",
        )
        self.assertEqual(chosen, "claude-haiku-4-5")

    def test_cursor_models_fall_back_when_list_is_missing(self):
        def opener(request, timeout):
            raise urllib.error.HTTPError(
                request.full_url,
                404,
                "Not Found",
                hdrs=None,
                fp=io.BytesIO(b'{"message":"not found"}'),
            )

        models = fetch_models("key_test", opener=opener, base_url="https://api.cursor.com/v1")
        self.assertEqual([item["id"] for item in models], ["composer-2", "composer-2-fast"])

    def test_missing_claude_key_does_not_call_the_network(self):
        def opener(request, timeout):
            raise AssertionError("Netz wurde aufgerufen")

        with self.assertRaisesRegex(RuntimeError, "fehlt"):
            complete(
                [{"role": "user", "content": "x"}],
                "claude-haiku-4-5",
                "  ",
                20,
                opener=opener,
                base_url="https://api.anthropic.com/v1",
            )

    def test_complete_chain_fails_when_every_endpoint_fails(self):
        def opener(request, timeout):
            raise urllib.error.URLError("down")

        with self.assertRaisesRegex(RuntimeError, "erreichbar"):
            complete_chain(
                [{"role": "user", "content": "x"}],
                [{"model": "llama3.2", "apiKey": "", "baseURL": "http://127.0.0.1:11434/v1"}],
                20,
                opener=opener,
            )


if __name__ == "__main__":
    unittest.main()
