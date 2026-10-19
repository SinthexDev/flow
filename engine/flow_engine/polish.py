"""Formuliert Rohtranskripte mit einem festen, prüfbaren Prompt."""

from __future__ import annotations

import re

THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
SPECIAL_RE = re.compile(r"<\|[^|]*\|>")

STYLES = {
    "auto": (
        "Formatiere passend zum Inhalt. Eine E-Mail wird eine E-Mail, "
        "eine Aufzählung eine Liste, eine kurze Nachricht bleibt kurz. "
        "Strukturiere nur, wenn das Gesprochene das hergibt."
    ),
    "literal": (
        "Bleib so wörtlich wie möglich. Ändere nur Füllwörter, "
        "Zeichensetzung und Großschreibung. Schreibe nichts um."
    ),
    "email": (
        "Setze das Diktat als E-Mail mit Anrede, Absätzen und Gruß, "
        "wenn sie gesprochen oder eindeutig gemeint sind. "
        "Erfinde keinen Betreff."
    ),
    "chat": "Kurze Nachricht, natürlicher Ton, keine förmliche Glättung.",
    "notes": (
        "Klare Notiz. Nutze Absätze oder Spiegelstriche, "
        "wenn mehrere Punkte gesprochen wurden."
    ),
    "code": (
        "Behandle den Text als Code oder technische Eingabe. "
        "Erhalte Bezeichner, Schreibweise und Symbole. Entferne nur Füllwörter."
    ),
}

LANG_NAMES = {
    "de": "Deutsch",
    "en": "Englisch",
    "fr": "Französisch",
    "es": "Spanisch",
    "it": "Italienisch",
    "pt": "Portugiesisch",
    "nl": "Niederländisch",
    "pl": "Polnisch",
    "tr": "Türkisch",
}

# Kurze Funktionswörter. Eine Ersetzung davon trifft fast jeden Satz.
_STOPWORDS = frozenset({
    "das", "der", "die", "den", "dem", "des", "ein", "eine", "einer", "einem",
    "einen", "eines", "mein", "meine", "meinem", "meinen", "meiner",
    "dein", "deine", "sein", "seine", "ihr", "ihre", "und", "oder", "aber",
    "nicht", "auch", "noch", "nur", "schon", "dann", "wenn", "dass", "ist",
    "sind", "war", "hat", "haben", "wird", "werden", "ich", "du", "er", "sie",
    "es", "wir", "man", "mit", "von", "zu", "auf", "für", "fur", "im", "in",
    "an", "am", "als", "wie", "doch", "mal", "the", "and", "for", "you", "your",
    "this", "that", "with", "was", "are",
})


def parse_dictionary(text: str) -> tuple[list[str], list[tuple[str, str]]]:
    hints: list[str] = []
    rules: list[tuple[str, str]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "->" in line:
            left, right = line.split("->", 1)
            left, right = left.strip(), right.strip()
            if left and right:
                rules.append((left, right))
        else:
            hints.append(line)
    return hints, rules


def _letters(text: str) -> str:
    return "".join(ch for ch in text.casefold() if ch.isalpha())


def _quotes_ok(text: str) -> bool:
    if text.count('"') % 2:
        return False
    if text.count("„") != text.count("“"):
        return False
    return text.count("«") == text.count("»")


def _show(term: str) -> str:
    return term.strip().strip("\"'„“”«»").strip()


def usable_hint(term: str) -> bool:
    if not term or not _quotes_ok(term):
        return False
    folded = _letters(_show(term))
    return len(folded) >= 3 and folded not in _STOPWORDS


def usable_rule(src: str, dst: str) -> bool:
    """Echte Schreibweisen. Reine Großschreibung und Wörter wie „das“ bleiben außen vor."""
    if not _quotes_ok(src) or not _quotes_ok(dst):
        return False
    left, right = _letters(src), _letters(dst)
    if len(left) < 3 or len(right) < 3 or left == right:
        return False
    return left not in _STOPWORDS and right not in _STOPWORDS


def weighted_terms(text: str) -> list[str]:
    """Begriffe, die Whisper und die Korrektur bevorzugen sollen."""
    hints, rules = parse_dictionary(text)
    terms: list[str] = []
    for term in hints:
        shown = _show(term)
        if usable_hint(shown) and shown not in terms:
            terms.append(shown)
    for src, dst in rules:
        shown = _show(dst)
        if usable_rule(src, dst) and usable_hint(shown) and shown not in terms:
            terms.append(shown)
    return terms


def clip_glossary(terms: list[str], limit: int = 800) -> str:
    """Whisper nimmt den Text als previous-context, nicht als festes Vokabular."""
    kept: list[str] = []
    size = 0
    for term in terms:
        extra = len(term) if not kept else len(term) + 2
        if size + extra > limit:
            break
        kept.append(term)
        size += extra
    return ", ".join(kept)


def _levenshtein(left: str, right: str) -> int:
    if left == right:
        return 0
    if not left:
        return len(right)
    if not right:
        return len(left)
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, start=1):
        current = [i]
        for j, b in enumerate(right, start=1):
            cost = 0 if a == b else 1
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + cost))
        previous = current
    return previous[-1]


def _close(token: str, term: str) -> bool:
    left, right = token.casefold(), term.casefold()
    if left == right:
        return True
    if min(len(left), len(right)) < 4:
        return False
    distance = _levenshtein(left, right)
    limit = 1 if max(len(left), len(right)) < 8 else 2
    return distance <= limit and distance / max(len(left), len(right)) <= 0.34


def _mentioned(text: str, term: str) -> bool:
    folded = text.casefold()
    if term.casefold() in folded:
        return True
    for token in re.findall(r"[^\W\d_]+", text, flags=re.UNICODE):
        if _close(token, term):
            return True
    return False


def glossary_lines(dictionary: str, context: str) -> list[str]:
    """Nur die passenden Einträge. Chat-Modelle haben kein Wörterbuch-Feld."""
    hints, rules = parse_dictionary(dictionary)
    hints = [_show(term) for term in hints if usable_hint(_show(term))]
    rules = [(src, _show(dst)) for src, dst in rules if usable_rule(src, dst)]

    def take(items: list, hit) -> list:
        if len(items) <= 24:
            first = [item for item in items if hit(item)]
            rest = [item for item in items if item not in first]
            return first + rest
        first = [item for item in items if hit(item)]
        rest = [item for item in items if item not in first][:8]
        return (first + rest)[:24]

    chosen_hints = take(hints, lambda term: _mentioned(context, term))
    chosen_rules = take(
        rules,
        lambda rule: _mentioned(context, rule[0]) or _mentioned(context, rule[1]),
    )
    spellings: list[str] = []
    for term in chosen_hints + [dst for _, dst in chosen_rules]:
        if term and term not in spellings:
            spellings.append(term)
    lines: list[str] = []
    if spellings:
        lines.append(
            "- Schreibe diese Begriffe exakt so, wenn sie gemeint sind: "
            + ", ".join(spellings)
            + "."
        )
    if chosen_rules:
        pairs = [f"{src} → {dst}" for src, dst in chosen_rules]
        lines.append("- Diese Erkennungsfehler ersetzt du: " + "; ".join(pairs) + ".")
    return lines


def apply_rules(text: str, rules: list[tuple[str, str]]) -> str:
    usable = [(src, dst) for src, dst in rules if usable_rule(src, dst)]
    for src, dst in sorted(usable, key=lambda rule: len(rule[0]), reverse=True):
        pattern = r"\b" + re.escape(src) + r"\b"
        text = re.compile(pattern, re.IGNORECASE).sub(dst, text)
    return text


def apply_fuzzy(text: str, terms: list[str]) -> str:
    singles = [term for term in terms if term and " " not in term]
    if not singles:
        return text

    def replace(match: re.Match[str]) -> str:
        word = match.group(0)
        exact = [term for term in singles if word.casefold() == term.casefold()]
        if exact:
            return exact[0]
        best: str | None = None
        best_distance = 99
        ambiguous = False
        for term in singles:
            if not _close(word, term):
                continue
            distance = _levenshtein(word.casefold(), term.casefold())
            if distance < best_distance:
                best, best_distance = term, distance
                ambiguous = False
            elif distance == best_distance:
                ambiguous = True
        if ambiguous or best is None:
            return word
        return best

    return re.sub(r"[^\W\d_]+", replace, text, flags=re.UNICODE)


def apply_dictionary(text: str, dictionary: str, *, fuzzy: bool = False) -> str:
    _hints, rules = parse_dictionary(dictionary)
    text = apply_rules(text, rules)
    if fuzzy:
        text = apply_fuzzy(text, weighted_terms(dictionary))
    return text


def clean_output(text: str) -> str:
    text = THINK_RE.sub("", text)
    text = text.replace("<think>", "").replace("</think>", "")
    text = SPECIAL_RE.sub("", text)
    text = text.strip()
    fence = re.match(r"^```[a-zA-Z0-9]*\n([\s\S]*?)\n```$", text)
    if fence:
        text = fence.group(1).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        inner = text[1:-1].strip()
        if inner and "\n\n" not in text:
            text = inner
    return text.strip()


def token_budget(raw: str, selection: str | None) -> int:
    words = max(1, len(raw.split()))
    if selection:
        words += len(selection.split())
        # A rewrite may be a whole document, not a one-line answer.
        return min(1600, max(500, words * 4 + 80))
    # Knapp halten – 27B ist der Flaschenhals nach Whisper.
    return min(320, max(40, words * 3 + 24))


def build_messages(
    raw: str,
    selection: str | None,
    style: str,
    instructions: str,
    dictionary: str,
    target_language: str | None = None,
) -> list[dict[str, str]]:
    if target_language:
        return build_translate_messages(raw if not selection else selection, target_language)
    if selection and selection.strip():
        return build_command_messages(raw, selection, style, instructions, dictionary)

    style_text = STYLES.get(style, STYLES["auto"])
    lines = [
        "Du bist die Formulierungsstufe einer Diktier-App.",
        "Du bekommst gesprochene Sprache als Rohtranskript und lieferst den Text, der eingefügt werden soll.",
        "Regeln:",
        "- Gib nur den fertigen Text zurück.",
        "- Keine Erklärung, keine Anführungszeichen um die ganze Antwort, kein Markdown, außer der Text selbst Markdown sein soll.",
        "- Entferne Füllwörter wie äh, ähm, also, halt, quasi, sozusagen, um, uh.",
        "- Setze Zeichensetzung, Großschreibung und Absätze.",
        "- Korrigiere Versprecher, ohne Inhalt, Namen oder Zahlen zu erfinden.",
        "- Behalte die Sprache des Gesprochenen.",
        "- Gesprochene Hinweise wie Absatz, neuer Absatz oder Zeilenumbruch werden zu einer neuen Zeile.",
        "- Gesprochene Satzzeichen wie Komma, Punkt, Fragezeichen, Ausrufezeichen und Doppelpunkt setzt du als Zeichen, wenn sie als Satzzeichen gemeint sind.",
        f"- Stil: {style_text}",
    ]
    lines.extend(glossary_lines(dictionary, raw))
    extra = instructions.strip()
    if extra:
        lines.append("Zusätzliche Anweisung des Nutzers: " + extra)
    user = f"Rohtranskript:\n{raw.strip()}"
    return [
        {"role": "system", "content": "\n".join(lines)},
        {"role": "user", "content": user},
    ]


def build_command_messages(
    raw: str,
    selection: str,
    style: str,
    instructions: str,
    dictionary: str,
) -> list[dict[str, str]]:
    lines = [
        "Du bist die Bearbeitungsstufe einer Diktier-App.",
        "Im Textfeld ist Text markiert. Das Gesprochene ist die Anweisung, nicht der neue Text.",
        "Schreibe den vollständigen Text, der die Markierung ersetzen soll.",
        "Regeln:",
        "- Gib nur diesen Ersatztext zurück.",
        "- Wiederhole die Anweisung nicht und antworte nicht mit einem einzelnen Stichwort daraus.",
        "- Verlangt die Anweisung ein Dokument, eine Liste, eine Zusammenfassung oder eine Umformulierung, schreibe das Ergebnis vollständig.",
        "- Keine Erklärung, keine Anführungszeichen um die ganze Antwort, kein Markdown, außer der Text selbst Markdown sein soll.",
        "- Fakten, Namen und Zahlen kommen aus der Markierung oder aus der Anweisung. Die verlangte Form darfst du ausformulieren.",
        "- Behalte die Sprache der Markierung, außer die Anweisung verlangt eine andere.",
    ]
    tone = {
        "email": "Wenn die Anweisung keinen Ton nennt, darf der Ersatz wie eine E-Mail klingen.",
        "chat": "Wenn die Anweisung keinen Ton nennt, bleib im Ton einer kurzen Nachricht.",
        "notes": "Wenn die Anweisung keinen Ton nennt, darf der Ersatz eine klare Notiz sein.",
    }.get(style)
    if tone:
        lines.append("- " + tone)
    lines.extend(glossary_lines(dictionary, f"{selection}\n{raw}"))
    extra = instructions.strip()
    if extra:
        lines.append("Zusätzliche Anweisung des Nutzers: " + extra)
    user = f"Markierter Text:\n{selection.strip()}\n\nAnweisung:\n{raw.strip()}"
    return [
        {"role": "system", "content": "\n".join(lines)},
        {"role": "user", "content": user},
    ]


def build_translate_messages(text: str, target_language: str) -> list[dict[str, str]]:
    name = LANG_NAMES.get(target_language, target_language)
    return [
        {
            "role": "system",
            "content": (
                f"Übersetze den Text nach {name}. "
                "Gib nur die Übersetzung zurück, ohne Anführungszeichen und ohne Erklärung. "
                "Erhalte Absätze und Aufzählungen."
            ),
        },
        {"role": "user", "content": text.strip()},
    ]
