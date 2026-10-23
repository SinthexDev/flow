import unittest

from flow_engine.transcribe import (
    _join_whistle_stream,
    discard_transcript,
    looks_repetitive,
    normalize_dictation_text,
    resolve_asr_engine,
    resolve_asr_quality,
    strip_hallucinations,
    strip_short_utterance_period,
    strip_spurious_quotes,
    whistle_depth_for_quality,
    whisper_model_for_quality,
    whistle_language,
)


class RepetitionTests(unittest.TestCase):
    def test_das_mein_loop_is_repetitive(self):
        text = ", ".join(["Das, mein"] * 40)
        self.assertTrue(looks_repetitive(text))

    def test_normal_sentence_is_kept(self):
        self.assertFalse(
            looks_repetitive("Bitte schick mir morgen die Rechnung für den letzten Auftrag.")
        )

    def test_short_text_is_kept(self):
        self.assertFalse(looks_repetitive("Das meine ich."))

    def test_discard_empty(self):
        self.assertTrue(discard_transcript([], "   "))

    def test_discard_high_no_speech(self):
        segments = [{"no_speech_prob": 0.82, "compression_ratio": 1.1}]
        self.assertTrue(discard_transcript(segments, "irgendwas"))

    def test_keep_confident_speech(self):
        segments = [{"no_speech_prob": 0.2, "compression_ratio": 1.4}]
        self.assertFalse(discard_transcript(segments, "Hallo, wie geht es dir heute?"))


class HallucinationStripTests(unittest.TestCase):
    def test_strips_trailing_vielen_dank(self):
        self.assertEqual(
            strip_hallucinations("Bitte schick mir die Rechnung. Vielen Dank"),
            "Bitte schick mir die Rechnung.",
        )

    def test_keeps_solo_vielen_dank(self):
        self.assertEqual(strip_hallucinations("Vielen Dank"), "Vielen Dank")

    def test_strips_thanks_for_watching(self):
        self.assertEqual(
            strip_hallucinations("Das war's für heute. Thanks for watching."),
            "Das war's für heute.",
        )

    def test_strips_amara_subtitle(self):
        self.assertEqual(
            strip_hallucinations("Hallo Welt. Untertitel der Amara.org-Community"),
            "Hallo Welt.",
        )

    def test_drops_only_subtitle_junk(self):
        self.assertEqual(strip_hallucinations("Untertitel im Auftrag des ZDF"), "")


class PunctuationCleanupTests(unittest.TestCase):
    def test_strips_wrapping_quotes(self):
        self.assertEqual(strip_spurious_quotes('"Rechnung"'), "Rechnung")
        self.assertEqual(strip_spurious_quotes("„Hallo“"), "Hallo")

    def test_strips_orphan_leading_or_trailing_quote(self):
        self.assertEqual(strip_spurious_quotes('"Rechnung'), "Rechnung")
        self.assertEqual(strip_spurious_quotes("Rechnung“"), "Rechnung")

    def test_strips_period_on_single_word(self):
        self.assertEqual(strip_short_utterance_period("Rechnung."), "Rechnung")

    def test_keeps_sentence_period(self):
        self.assertEqual(
            strip_short_utterance_period("Schick mir die Rechnung."),
            "Schick mir die Rechnung.",
        )

    def test_normalize_combines_cleanup(self):
        self.assertEqual(normalize_dictation_text('"Rechnung."'), "Rechnung")
        self.assertEqual(
            normalize_dictation_text("Bitte die Rechnung schicken."),
            "Bitte die Rechnung schicken.",
        )


class WhistleHelperTests(unittest.TestCase):
    def test_resolve_asr_engine(self):
        self.assertEqual(resolve_asr_engine("whistle"), "whistle")
        self.assertEqual(resolve_asr_engine("parakeet"), "parakeet")
        self.assertEqual(resolve_asr_engine("qwen3"), "qwen3")
        self.assertEqual(resolve_asr_engine("Whisper"), "whisper")
        self.assertEqual(resolve_asr_engine("nope"), "whisper")
        self.assertEqual(resolve_asr_engine(None), "whisper")

    def test_whistle_language(self):
        self.assertEqual(whistle_language("de"), "de")
        self.assertIsNone(whistle_language("auto"))
        self.assertIsNone(whistle_language("tr"))

    def test_quality_maps_to_depth_and_whisper_model(self):
        self.assertEqual(resolve_asr_quality(99), 4)
        self.assertEqual(resolve_asr_quality(-3), 0)
        self.assertEqual(whistle_depth_for_quality(0), 2)
        self.assertEqual(whistle_depth_for_quality(4), 8)
        self.assertTrue(whisper_model_for_quality(0).endswith("whisper-tiny"))
        self.assertTrue(whisper_model_for_quality(4).endswith("whisper-large-v3-turbo"))

    def test_join_stream_keeps_pending_tail(self):
        text, language = _join_whistle_stream(
            [
                {"text": "Hallo", "pending": "Welt", "language": "de"},
                {"text": "", "pending": "dort", "language": "de"},
            ]
        )
        self.assertEqual(text, "Hallo dort")
        self.assertEqual(language, "de")


if __name__ == "__main__":
    unittest.main()
