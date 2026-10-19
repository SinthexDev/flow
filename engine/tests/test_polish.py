import unittest

from flow_engine.polish import (
    apply_dictionary,
    apply_rules,
    build_messages,
    clean_output,
    clip_glossary,
    parse_dictionary,
    token_budget,
    weighted_terms,
)


class PolishTests(unittest.TestCase):
    def test_clean_strips_thinking_and_fences(self):
        raw = "<think>\nlang\n</think>\n```text\nHallo Welt\n```"
        self.assertEqual(clean_output(raw), "Hallo Welt")

    def test_clean_unwraps_quotes(self):
        self.assertEqual(clean_output('"Morgen um zehn."'), "Morgen um zehn.")

    def test_dictionary_rules_replace_longest_first(self):
        hints, rules = parse_dictionary("VEMA\nflow app -> Flow\n# Kommentar")
        self.assertEqual(hints, ["VEMA"])
        self.assertEqual(apply_rules("Die flow app ist da.", rules), "Die Flow ist da.")

    def test_weighted_terms_include_the_correct_spelling(self):
        self.assertEqual(weighted_terms("VEMA\nflow app -> Flow"), ["VEMA", "Flow"])

    def test_function_word_rules_are_ignored(self):
        dictionary = "Das -> das\nMein -> mein\ndas -> \"Das\nBillbee\nSyntax -> Sinthex"
        self.assertEqual(weighted_terms(dictionary), ["Billbee", "Sinthex"])
        text = "Das ist mein Text."
        self.assertEqual(apply_dictionary(text, dictionary), text)
        self.assertEqual(apply_dictionary("Die Syntax bleibt.", dictionary), "Die Sinthex bleibt.")

    def test_fuzzy_spelling_follows_a_dictionary_term(self):
        self.assertEqual(
            apply_dictionary("Die Sintex steht fest.", "Sinthex", fuzzy=True),
            "Die Sinthex steht fest.",
        )
        self.assertEqual(
            apply_dictionary("bei sinthex nachfragen", "Sinthex", fuzzy=True),
            "bei Sinthex nachfragen",
        )
        both = "Sinthex\nSinthern\nSyntax -> Sinthex"
        self.assertEqual(
            apply_dictionary("Die Syntax und Sinthex.", both, fuzzy=True),
            "Die Sinthex und Sinthex.",
        )

    def test_glossary_lists_real_mappings(self):
        messages = build_messages(
            "Die Syntax ist da.",
            None,
            "auto",
            "",
            "Das -> das\nSyntax -> Sinthex\nBillbee",
        )
        system = messages[0]["content"]
        self.assertIn("Syntax → Sinthex", system)
        self.assertIn("Billbee", system)
        self.assertNotIn("→ das", system)

    def test_glossary_clips_on_a_term_boundary(self):
        self.assertEqual(clip_glossary(["Sinthex", "Billbee", "beeUnity"], limit=16), "Sinthex, Billbee")

    def test_token_budget_grows_with_text(self):
        self.assertGreaterEqual(token_budget("eins zwei drei vier", "markiert"), 80)

    def test_selection_is_an_instruction(self):
        messages = build_messages(
            "kannst du das zusammenfassen",
            "Ein langer Absatz über das Projekt.",
            "code",
            "",
            "",
        )
        system = messages[0]["content"]
        user = messages[1]["content"]
        self.assertIn("Anweisung", system)
        self.assertIn("Wiederhole die Anweisung nicht", system)
        self.assertIn("vollständig", system)
        self.assertNotIn("knapp und klar", system)
        self.assertNotIn("Entferne nur Füllwörter", system)
        self.assertIn("Ein langer Absatz über das Projekt.", user)
        self.assertIn("kannst du das zusammenfassen", user)
        self.assertNotIn("Rohtranskript", user)

    def test_note_answer_uses_selection_as_context(self):
        messages = build_messages(
            "Speichere als Notiz, welche Farben auf der Seite sind",
            "Die Seite ist violett und weiß.",
            "auto",
            "",
            "",
            note_answer=True,
        )
        system = messages[0]["content"]
        user = messages[1]["content"]
        self.assertIn("nur der Kontext", system)
        self.assertIn("Übernimm die Markierung nicht", system)
        self.assertIn("Die Seite ist violett und weiß.", user)
        self.assertIn("welche Farben", user)
        self.assertNotIn("ersetzen soll", system)


if __name__ == "__main__":
    unittest.main()
