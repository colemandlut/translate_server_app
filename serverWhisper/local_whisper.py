"""
Local Whisper API server - compatible with OpenAI/Groq API format.
Uses faster-whisper for fast transcription on Mac (CPU/CoreML).
Listens on port 8090.
"""

import io
import time
import json
from flask import Flask, request, jsonify
from faster_whisper import WhisperModel

app = Flask(__name__)

# Load model once at startup
# "large-v3-turbo" best accuracy, "small" good balance, "base"/"tiny" fastest
MODEL_SIZE = "base"
print(f"Loading Whisper model '{MODEL_SIZE}'...")
t0 = time.time()
model = WhisperModel(MODEL_SIZE, device="cpu", compute_type="int8")
print(f"Model loaded in {time.time()-t0:.1f}s")


@app.route("/v1/audio/transcriptions", methods=["POST"])
def transcribe():
    if "file" not in request.files:
        return jsonify({"error": {"message": "No file provided"}}), 400

    audio_file = request.files["file"]
    audio_bytes = audio_file.read()

    t0 = time.time()

    # Transcribe
    segments, info = model.transcribe(
        io.BytesIO(audio_bytes),
        beam_size=1,           # fastest
        best_of=1,
        temperature=0,
        vad_filter=True,       # filter silence
        vad_parameters=dict(
            min_silence_duration_ms=300,
        ),
    )

    # Collect all segments
    text_parts = []
    for segment in segments:
        text_parts.append(segment.text)

    text = "".join(text_parts).strip()
    elapsed = time.time() - t0
    detected_lang = info.language if info else ""

    print(f"[{elapsed:.2f}s] [{detected_lang}] \"{text[:60]}\"")

    # Return OpenAI-compatible format
    response_format = request.form.get("response_format", "json")
    if response_format == "verbose_json":
        return jsonify({
            "text": text,
            "language": detected_lang,
            "duration": info.duration if info else 0,
        })
    else:
        return jsonify({"text": text})


if __name__ == "__main__":
    print("Local Whisper server on http://localhost:8090")
    app.run(host="0.0.0.0", port=8090, debug=False)
