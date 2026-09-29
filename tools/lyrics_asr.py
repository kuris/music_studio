#!/usr/bin/env python3
"""Recognise sung lyrics with Whisper and lay them out under SheetSage2's sections.

Imported by transcribe_sheetsage.py and run inside the SheetSage2 environment, whose
torch 2.8 / transformers 4.45 already carry everything Whisper needs — no extra pins.

Audio is decoded with macOS's own afconvert, like the rest of the transcriber, so no
FFmpeg install is needed.  When the melody run has written a structure.lab, each
recognised segment is placed in the section its midpoint falls in and the result comes
back with the [Verse]/[Chorus] tags the lyrics field expects; without one the lines are
returned untagged.  The timed segments are also written out as lyrics.srt so the words
can be used as subtitles.
"""

import re
import subprocess
from pathlib import Path

AFCONVERT = "/usr/bin/afconvert"
SAMPLE_RATE = 16000
DEFAULT_MODEL = "openai/whisper-large-v3-turbo"

# structure.lab labels → the tags ContentView's lyrics field documents.
SECTION_TAGS = {
    "intro": "[Intro]", "verse": "[Verse]", "pre-chorus": "[Pre-Chorus]",
    "prechorus": "[Pre-Chorus]", "chorus": "[Chorus]", "bridge": "[Bridge]",
    "interlude": "[Interlude]", "outro": "[Outro]", "solo": "[Interlude]",
}

# Whisper invents a credit line over instrumental tails. These only ever get dropped at
# the very end of a song, so a real lyric that happens to say "thank you" survives.
TRAILING_NOISE = re.compile(
    r"(자막|시청|구독|좋아요|영상|채널|번역|제작지원|MBC|KBS|SBS"
    r"|subtitle|subs? by|amara\.org|transcri|thanks for watching|thank you for watching)",
    re.IGNORECASE)


class LyricsError(Exception):
    pass


def is_degenerate(text):
    """True for Whisper's repetition loops ("!!!!!!…", "다다다다…") over instrumental parts."""
    stripped = "".join(text.split())
    if not stripped:
        return True
    if len(stripped) >= 12 and len(set(stripped)) <= 2:
        return True
    # A long line built from one short repeated unit is a loop, not a lyric.
    for size in (1, 2, 3):
        if len(stripped) >= 8 * size and stripped == (stripped[:size] * (len(stripped) // size))[:len(stripped)]:
            return True
    return False


def decode_16k_mono(audio, output):
    """Decode any macOS-readable format to the 16 kHz mono WAV Whisper wants."""
    wav = Path(output) / "lyrics_input.wav"
    proc = subprocess.run(
        [AFCONVERT, str(audio), str(wav), "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1"],
        capture_output=True, text=True)
    if proc.returncode != 0 or not wav.is_file():
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise LyricsError(tail[-1] if tail else f"afconvert exited {proc.returncode}")
    return wav


def read_sections(output):
    """structure.lab as [(start, end, label)]; empty when the melody run wrote none."""
    path = Path(output) / "structure.lab"
    if not path.is_file():
        return []
    sections = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        try:
            start, end = float(parts[0]), float(parts[1])
        except ValueError:
            continue
        label = parts[2].strip().lower()
        if sections and sections[-1][2] == label:      # merge the repeats structure.lab emits
            sections[-1] = (sections[-1][0], end, label)
        else:
            sections.append((start, end, label))
    return [tuple(s) for s in sections]


def section_at(sections, seconds):
    """The section a moment belongs to, clamped at both ends of the timeline."""
    if not sections:
        return None
    if seconds < sections[0][0]:
        return sections[0][2]
    for start, end, label in sections:
        if start <= seconds < end:
            return label
    return sections[-1][2]


def strip_trailing_noise(lines):
    """Drop Whisper's invented credits, which only ever appear at the end."""
    while lines and TRAILING_NOISE.search(lines[-1][2]):
        lines.pop()
    return lines


def lay_out(lines, sections):
    """[(start, end, text)] → tagged lyrics text. Sections with no words are skipped."""
    if not lines:
        return ""
    if not sections:
        return "\n".join(text for _, _, text in lines)
    out, current = [], None
    for seconds, _, text in lines:
        label = section_at(sections, seconds)
        if label != current:
            current = label
            tag = SECTION_TAGS.get(label or "", "")
            if tag:
                if out:
                    out.append("")
                out.append(tag)
        out.append(text)
    return "\n".join(out)


def srt_time(seconds):
    seconds = max(0.0, seconds)
    hours, rest = divmod(int(seconds), 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{int(round((seconds % 1) * 1000)):03d}"


def write_srt(lines, path):
    """SubRip of the timed segments; each cue is clamped so cues never overlap."""
    blocks = []
    for index, (start, end, text) in enumerate(lines, start=1):
        stop = max(end, start + 0.5)
        if index < len(lines):
            stop = min(stop, lines[index][0])       # never run into the next cue
        blocks.append(f"{index}\n{srt_time(start)} --> {srt_time(max(stop, start + 0.2))}\n{text}\n")
    Path(path).write_text("\n".join(blocks), encoding="utf-8")
    return path


def transcribe(audio, output, *, model_id=DEFAULT_MODEL, language=None,
               device="mps", offline=False, progress=None):
    """Recognise lyrics; returns {"text", "lines", "language", "model"}.

    `progress(detail)` is called as the run advances so the caller can forward it.
    """
    def note(detail):
        if progress:
            progress(detail)

    import torch
    import soundfile
    from transformers import AutoProcessor, WhisperForConditionalGeneration

    note("decoding audio for lyrics")
    wav = decode_16k_mono(audio, output)
    try:
        data, sample_rate = soundfile.read(wav, dtype="float32")
    finally:
        wav.unlink(missing_ok=True)
    if data.ndim > 1:
        data = data.mean(axis=1)

    note("loading the lyrics model")
    if device == "mps" and not torch.backends.mps.is_available():
        device = "cpu"
    # fp32 throughout: half precision on MPS makes the temperature-fallback sampling
    # produce NaN logits, and the fallback is what keeps silence from looping.
    dtype = torch.float32
    processor = AutoProcessor.from_pretrained(model_id, local_files_only=offline)
    model = WhisperForConditionalGeneration.from_pretrained(
        model_id, torch_dtype=dtype, local_files_only=offline).to(device).eval()

    try:
        note("recognising lyrics")
        # truncation=False + an attention mask selects Whisper's sequential long-form
        # decoding, which keeps timestamps usable across a whole song.
        inputs = processor(data, sampling_rate=sample_rate, return_tensors="pt",
                           truncation=False, padding="longest", return_attention_mask=True)
        generated = model.generate(
            inputs.input_features.to(device, dtype),
            attention_mask=inputs.attention_mask.to(device),
            task="transcribe", language=language,
            return_timestamps=True, return_segments=True,
            condition_on_prev_tokens=False,
            # Whisper's standard fallback thresholds. Without them a long instrumental
            # stretch decodes into a repetition loop instead of silence.
            temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
            compression_ratio_threshold=2.4,
            logprob_threshold=-1.0,
            no_speech_threshold=0.6)
        segments = generated["segments"][0]
        lines = []
        for segment in segments:
            text = processor.decode(segment["tokens"], skip_special_tokens=True).strip()
            # Only outright gibberish is dropped. Whisper times an opening line against the
            # whole first window, so judging a line by its words-per-second threw away a real
            # one — and a lost lyric is invisible where a stray line is one keystroke to delete.
            if text and not is_degenerate(text):
                lines.append((float(segment["start"]), float(segment["end"]), text))
        # Long-form decoding can hand segments back out of order; the layout and the SRT
        # both read them as a timeline, so put them back in one.
        lines.sort(key=lambda line: line[0])
    finally:
        del model
        if device == "mps":
            torch.mps.empty_cache()

    lines = strip_trailing_noise(lines)
    srt = write_srt(lines, Path(output) / "lyrics.srt") if lines else None
    return {"text": lay_out(lines, read_sections(output)),
            "lines": [{"start": round(a, 2), "end": round(b, 2), "text": t} for a, b, t in lines],
            "srt": str(srt) if srt else "",
            "language": language or "auto", "model": model_id}
