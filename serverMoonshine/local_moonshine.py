"""
Local Moonshine ASR server (v2 / moonshine-voice).

Loads per-language models (en + ja + zh), runs all 3 in parallel per request,
picks the winner by script match (en -> Latin-only, ja -> must contain kana,
zh -> must contain Han with no kana). Exposes OpenAI-compatible
/v1/audio/transcriptions. Listens on port 8091.

Note: ja/zh are released under Moonshine Community (non-commercial) License.
See https://www.moonshine.ai/license

Run:
    pip install -r requirements.txt
    python local_moonshine.py
"""

import io
import re
import time
import wave
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from flask import Flask, request, jsonify
from moonshine_voice import get_model_for_language
from moonshine_voice.transcriber import Transcriber

LANGUAGES = ["en", "ja", "zh"]

# ---- Load models ----
transcribers = {}
for lang in LANGUAGES:
    print(f"Loading Moonshine model for '{lang}'...")
    t0 = time.time()
    model_path, model_arch = get_model_for_language(lang)
    opts = {"word_timestamps": "true"}
    if lang != "en":
        # Required per Moonshine docs for non-Latin scripts to avoid over-fast decoding
        opts["max_tokens_per_second"] = "13.0"
    t = Transcriber(model_path=model_path, model_arch=model_arch, options=opts)
    t.start()
    transcribers[lang] = t
    print(f"  {lang} loaded in {time.time() - t0:.1f}s")

executor = ThreadPoolExecutor(max_workers=len(LANGUAGES))


# ---- Audio helpers ----
def wav_bytes_to_float32(wav_bytes: bytes) -> np.ndarray:
    """Decode WAV bytes -> float32 mono 16 kHz samples in [-1, 1]."""
    with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
        sample_rate = wf.getframerate()
        channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        frames = wf.readframes(wf.getnframes())

    if sample_width != 2:
        raise ValueError(f"Expected 16-bit PCM, got {sample_width*8}-bit")
    audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels == 2:
        audio = audio.reshape(-1, 2).mean(axis=1)
    if sample_rate != 16000:
        raise ValueError(f"Expected 16 kHz, got {sample_rate} Hz")
    return audio


# ---- Script classification ----
def has_kana(s: str) -> bool:
    # Hiragana U+3040-309F, Katakana U+30A0-30FF
    return any(0x3040 <= ord(c) <= 0x30FF for c in s)


def has_han(s: str) -> bool:
    # CJK Unified Ideographs U+4E00-9FFF (+ ext A 3400-4DBF)
    return any(0x4E00 <= ord(c) <= 0x9FFF or 0x3400 <= ord(c) <= 0x4DBF for c in s)


def is_mostly_latin(s: str) -> bool:
    letters = [c for c in s if c.isalpha()]
    if not letters:
        return False
    ascii_count = sum(1 for c in letters if c.isascii())
    return ascii_count / len(letters) >= 0.9


def script_matches_language(text: str, lang: str) -> bool:
    """Return True if `text`'s script is plausible for `lang`.

    - en: mostly ASCII letters, no CJK
    - ja: must contain hiragana or katakana (distinguishes ja from zh)
    - zh: must contain Han but NO kana
    """
    text = text.strip()
    if not text:
        return False
    if lang == "en":
        return not (has_kana(text) or has_han(text)) and is_mostly_latin(text)
    if lang == "ja":
        return has_kana(text)
    if lang == "zh":
        return has_han(text) and not has_kana(text)
    return False


_CJK_RE = r"[\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF]"
_CJK_SPACE_RE = re.compile(f"({_CJK_RE}) (?={_CJK_RE})")
_STRIP_PUNCT_RE = re.compile(r"[.,!?。、！？…·・,\s]")


def normalize_cjk_spacing(text: str) -> str:
    """Collapse single spaces between two CJK chars. base-ja/zh sometimes inserts
    these during decoding; they are visual noise, not real word boundaries."""
    prev = None
    cur = text
    # Multiple passes in case of overlapping matches like "A B C"
    while cur != prev:
        prev = cur
        cur = _CJK_SPACE_RE.sub(r"\1", cur)
    return cur


def _cjk_heavy(text: str) -> bool:
    if not text:
        return False
    cjk = sum(1 for c in text if 0x3040 <= ord(c) <= 0x30FF or 0x4E00 <= ord(c) <= 0x9FFF)
    return cjk / len(text) > 0.3


def has_substring_repetition(text: str) -> bool:
    """True if any contiguous substring of length >= min_len appears twice.
    CJK-heavy text uses a shorter min_len because CJK loops tend to be short."""
    n = len(text)
    min_len = 4 if _cjk_heavy(text) else 12
    if n < min_len * 2:
        return False
    step = 1
    for start in range(0, n - min_len, step):
        chunk = text[start : start + min_len]
        if text.find(chunk, start + min_len) != -1:
            return True
    return False


def _kana_ratio(text: str) -> float:
    cjk = [
        c for c in text
        if 0x3040 <= ord(c) <= 0x30FF or 0x4E00 <= ord(c) <= 0x9FFF
    ]
    if not cjk:
        return 0.0
    kana = sum(1 for c in cjk if 0x3040 <= ord(c) <= 0x30FF)
    return kana / len(cjk)


def has_char_over_freq(text: str, threshold: float = 0.25) -> bool:
    """True if a single non-punct, non-space char dominates (>25% of chars).
    Also flags when any single char appears >= 8 times in CJK text."""
    chars = [c for c in text if not _STRIP_PUNCT_RE.match(c)]
    if len(chars) < 8:
        return False
    top_char, top_count = Counter(chars).most_common(1)[0]
    if top_count / len(chars) > threshold:
        return True
    # CJK runaway: a single CJK char repeating 8+ times is always hallucination
    if top_count >= 8 and (0x3040 <= ord(top_char) <= 0x30FF or 0x4E00 <= ord(top_char) <= 0x9FFF):
        return True
    return False


# Hard hallucination patterns lifted from Whisper/Moonshine distillation lineage.
HALLUCINATION_PATTERNS = {
    # English
    "thank you", "thanks for watching", "thanks for listening",
    "please subscribe", "like and subscribe", "see you next time",
    "goodbye", "bye bye", "bye-bye", "the end",
    "subtitles", "copyright", "music", "♪",
    "you", "yeah", "okay", "ok", "hmm", "uh", "um", "oh",
    "so", "whole", "well", "right", "i don't know",
    # Japanese
    "ご視聴ありがとうございました", "チャンネル登録",
    "ありがとうございました", "ありがとうございます",
    "お疲れ様でした", "それでは", "では",
    "はい", "ではでは", "じゃあ",
    # Chinese
    "谢谢", "谢谢观看", "感谢收看", "请订阅",
}


def has_too_much_latin_in_cjk(text: str) -> bool:
    """CJK-heavy text with >40% ASCII letters is almost always a ja/zh model
    hallucinating an English passage in the middle of made-up CJK.
    (30% would false-positive on short Chinese with a Latin name like "monch machine".)"""
    if not _cjk_heavy(text):
        return False
    alnum = [c for c in text if c.isalnum()]
    if not alnum:
        return False
    latin = sum(1 for c in alnum if c.isascii())
    return latin / len(alnum) > 0.40


def is_hallucination(text: str) -> bool:
    stripped = text.strip().lower()
    stripped_punct = _STRIP_PUNCT_RE.sub("", stripped)
    if len(stripped_punct) < 2:
        return True
    if stripped in HALLUCINATION_PATTERNS or stripped_punct in HALLUCINATION_PATTERNS:
        return True
    if has_char_over_freq(text):
        return True
    if has_substring_repetition(text):
        return True
    if has_too_much_latin_in_cjk(text):
        return True
    return False


# ---- Transcription ----
def transcribe_one(lang: str, audio: np.ndarray) -> dict:
    t0 = time.time()
    try:
        tr = transcribers[lang].transcribe_without_streaming(
            audio.tolist(), sample_rate=16000
        )
        raw = " ".join(line.text for line in tr.lines).strip()
    except Exception as e:
        return {"language": lang, "text": "", "error": str(e), "ms": 0}
    text = normalize_cjk_spacing(raw)
    ms = int((time.time() - t0) * 1000)
    flags = []
    if not script_matches_language(text, lang):
        flags.append("script_mismatch")
    if is_hallucination(text):
        flags.append("hallucination")
    # Real Japanese uses kana particles everywhere; <25% kana-of-CJK = likely the
    # ja model regurgitating Chinese audio with a sprinkle of kana.
    if lang == "ja" and _kana_ratio(text) < 0.25:
        flags.append("low_kana")
    return {"language": lang, "text": text, "ms": ms, "flags": flags}


def pick_winner(results: list, allowed: set) -> dict:
    """Winner must (a) be in the allowed language set (usually the app's
    langA/langB), (b) match its model's native script, (c) not look like a
    hallucination. Among survivors, prefer longest text."""
    survivors = [
        r for r in results
        if r["language"] in allowed and r["text"] and not r.get("flags")
    ]
    if not survivors:
        return {"language": "", "text": ""}
    survivors.sort(key=lambda r: len(r["text"]), reverse=True)
    return survivors[0]


app = Flask(__name__)


@app.route("/v1/audio/transcriptions", methods=["POST"])
def transcribe():
    if "file" not in request.files:
        return jsonify({"error": {"message": "No file provided"}}), 400

    audio_bytes = request.files["file"].read()
    try:
        audio = wav_bytes_to_float32(audio_bytes)
    except Exception as e:
        return jsonify({"error": {"message": f"WAV decode failed: {e}"}}), 400

    # Reject very short audio (< 100 ms) to avoid garbage
    if audio.shape[0] < 1600:
        return jsonify({"text": "", "language": "", "duration": audio.shape[0] / 16000.0})

    # Optional "languages" form field: comma-separated list of allowed languages
    # the caller cares about (e.g. "en,ja" if the app's langA/langB are en/ja).
    # If absent, all three candidates are eligible.
    raw_allowed = request.form.get("languages", "")
    allowed = {x.strip() for x in raw_allowed.split(",") if x.strip()}
    if not allowed:
        allowed = set(LANGUAGES)

    # Only run the models the caller actually cares about. en's medium-streaming
    # model is ~2x slower than ja/zh base, so skipping it when unused cuts the
    # parallel total from ~3s to ~1.5s.
    langs_to_run = [l for l in LANGUAGES if l in allowed]
    t0 = time.time()
    futures = [executor.submit(transcribe_one, lang, audio) for lang in langs_to_run]
    results = [f.result() for f in futures]
    total_ms = int((time.time() - t0) * 1000)

    winner = pick_winner(results, allowed)
    print(
        f"[{total_ms}ms] ran={langs_to_run} winner={winner['language'] or 'none'} "
        + " | ".join(f"{r['language']}({r['ms']}ms):{r['text'][:25]!r}" for r in results)
    )

    return jsonify({
        "text": winner["text"],
        "language": winner["language"],
        "duration": audio.shape[0] / 16000.0,
        "candidates": results,
    })


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "languages": LANGUAGES})


if __name__ == "__main__":
    print(f"Local Moonshine server on http://localhost:8091 (langs: {LANGUAGES})")
    app.run(host="0.0.0.0", port=8091, debug=False, threaded=True)
