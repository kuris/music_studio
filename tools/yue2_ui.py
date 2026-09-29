#!/usr/bin/env python3
"""YuE Studio - Dark Theme Web UI with Gemini AI integration and Cover Song support.

    python tools/yue2_ui.py            # opens http://127.0.0.1:7860

Features:
- Dark theme UI matching ssokMusic Free reference
- Gemini 3.5 Flash API integration for AI lyric writing and title generation
- Style tag chips (city pop, trot, ballad, etc.)
- Audio upload for cover song transcription (SheetSage2)
- Korean language UI
"""
import argparse
import datetime as dt
import json
import os
import threading
import time
import traceback
import urllib.request
from pathlib import Path

import gradio as gr
import torch

from yue2 import YuE2Pipeline
from yue2.batched import generate_tokens_batched
from yue2.pipeline import SemanticResult, SongResult, SymbolicPlan
from yue2.protocol import CODEC_OFFSET, token_prefixes
from yue2.storage import identity

ROOT = Path(__file__).resolve().parents[1]
MAX_BATCH = 8
EXAMPLE = json.loads((ROOT / "examples/song.json").read_text(encoding="utf-8"))
PIPE = None
STOP = threading.Event()

# Style tags with prompt mappings
STYLE_TAGS = {
    "시티팝": "Korean city pop, warm analog synth, smooth bass, 95 BPM",
    "트로트": "Korean trot, accordion, brass, upbeat rhythm, 120 BPM",
    "발라드": "Korean ballad, piano, strings, emotional, 70 BPM",
    "K-pop 스": "K-pop dance, electronic, energetic, 128 BPM",
    "R&B": "R&B, soulful vocals, smooth production, 90 BPM",
    "어쿠스틱 포크": "Acoustic folk, guitar, warm, 85 BPM",
    "신스웨이브": "Synthwave, retro 80s, neon, 110 BPM",
    "록 밴드": "Rock band, electric guitar, drums, 130 BPM",
    "재즈 보사노바": "Jazz bossa nova, piano, light percussion, 100 BPM",
    "동요": "Children's song, simple melody, playful, 110 BPM",
}

# Gemini API settings from environment
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash")


def pipeline():
    global PIPE
    if PIPE is None:
        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        PIPE = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device=device, progress=False)
        PIPE._load_model()
    return PIPE


def bar(fraction, width=24):
    filled = int(round(max(0.0, min(1.0, fraction)) * width))
    return "`" + "█" * filled + "░" * (width - filled) + f"` {100 * fraction:3.0f}%"


def render_status(state):
    elapsed = time.perf_counter() - state["start"]
    lines = [f"### {state['stage']}", bar(state["fraction"]), state["detail"], f"경과 {elapsed:.0f}초",
             f"요청: 스타일 "{state['style'][:70]}…" · 가사 시작 "{state['lyric_start']}…" · "
             f"시드 {state['seeds']} · 모드 {state['mode']}"]
    if state["songs"]:
        lines.append("")
        lines.append("| 곡 | 상태 |")
        lines.append("|---|---|")
        for i, s in enumerate(state["songs"]):
            lines.append(f"| {i + 1} | {s} |")
    if state["error"]:
        lines.append(f"\n**오류:** `{state['error']}`")
    return "\n\n".join(lines)


def worker(state, style, lyrics, mode, abc, seeds):
    n = len(seeds)
    pipe = pipeline()
    tokenizer = pipe.tokenizer
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_root = ROOT / "outputs" / "ui" / stamp
    state["out_root"] = out_root
    cancelled = STOP.is_set
    requests = [pipe._request(style=style, lyrics=lyrics, cot=mode, seed=s, abc=abc or None,
                              id=f"song{i + 1}", **({"cfg_scale": 1.0} if mode == "off" else {}))
                for i, s in enumerate(seeds)]

    # Stage 1: symbolic plans, batched when the model must write the score.
    state.update(stage=f"{n}개 곡 계획 중", fraction=0.02, detail="프롬프트 생성")
    model = pipe._load_model()
    if mode == "off" or abc:
        plans = [pipe.plan(request=r) for r in requests]
    else:
        prefixes = [token_prefixes(r, tokenizer) for r in requests]
        counts = [0] * n

        def on_abc(row, phase, token):
            counts[row] += 1
            total = sum(counts)
            state.update(fraction=0.02 + 0.13 * min(1.0, total / (n * 700)),
                         detail=f"악보 토큰: {', '.join(map(str, counts))} (일괄 {n}개)")
        rows, _ = generate_tokens_batched(model, prefixes, pipe.generation_config.abc, seeds, "abc",
                                          cancelled=cancelled, on_token=on_abc)
        plans = [SymbolicPlan(r, tokenizer.decode(ids), ids, token_prefixes(r, tokenizer, ids), timing, truncated)
                 for r, (ids, timing, truncated) in zip(requests, rows)]
    state["plans"] = plans

    # Stage 2: song tokens for all plans in one batch.
    counts = [0] * n
    state.update(stage=f"{n}개 곡 토 생성 중", fraction=0.15, detail="프리필링")

    def on_song(row, phase, token):
        counts[row] += 1
        total = sum(counts)
        state.update(fraction=0.15 + 0.25 * min(1.0, total / (n * 1500)),
                     detail=f"곡 토큰: {', '.join(map(str, counts))} · ~25 큰 ≈ 1초 오디오")
    rows, batch_timing = generate_tokens_batched(model, [p.prefix for p in plans],
                                                 pipe.generation_config.semantic, seeds, "semantic",
                                                 legacy_off=(mode == "off"), cancelled=cancelled, on_token=on_song)
    state["batch_timing"] = batch_timing

    # Stage 3: synthesis + decode per song; each result is published as it lands.
    from yue2.nar import synthesize
    for i, (plan, (tokens, timing, truncated)) in enumerate(zip(plans, rows)):
        seconds_est = len(tokens) / 25
        state.update(stage=f"오디오 합성: 곡 {i + 1}/{n}", fraction=0.4 + 0.6 * i / n,
                     detail=f"약 {seconds_est:.0f}초 오디오; 이 단계는 계산 집약적")
        state["songs"][i] = "합성 중"
        semantic = SemanticResult(plan, [int(t) - CODEC_OFFSET for t in tokens], timing, truncated)
        model = pipe._load_model(for_nar=True)

        def on_nar(done, total, i=i):
            state.update(fraction=0.4 + 0.6 * (i + 0.9 * done / max(total, 1)) / n,
                         detail=f"ODE 단계 {done}/{total} · 약 {len(tokens) / 25:.0f}초 오디오")
        t0 = time.perf_counter()
        latents = synthesize(model, plan.prefix, semantic.tokens, plan.request.seed,
                             steps=pipe.generation_config.ode_steps, context=pipe.generation_config.context,
                             offload_ar=pipe.offload_ar, cancelled=cancelled, on_progress=on_nar)
        latents = latents.detach().float().cpu().numpy()
        nar = time.perf_counter() - t0
        state.update(detail="파형 디코딩")
        t1 = time.perf_counter()
        audio = pipe.decode(latents)
        config = pipe.effective_config(plan.request)
        config["execution"] = "eager_batched"
        song = SongResult(audio, 48000, semantic, latents, config, pipe.weights,
                          {"semantic": timing, "nar_seconds": nar, "vae_seconds": time.perf_counter() - t1},
                          identity({"request": plan.request.to_dict(), "config": config, "weights": pipe.weights}))
        directory = out_root / plan.request.id
        song.save_artifacts(directory)
        length = len(audio) / 48000
        state["songs"][i] = f"완료 · {length:.1f}초 · {nar:.0f}초 합성"
        state["results"][i] = (str(directory / "audio.flac"), plan.abc or "(악보 없음: 직접 모드)",
                               length, plan.request.seed, truncated or plan.truncated)
    state.update(stage="완료", fraction=1.0, detail="")


def outputs_for(state, n):
    out = []
    for i in range(MAX_BATCH):
        result = state["results"][i] if i < n else None
        if result:
            path, score, length, seed_i, truncated = result
            label = f"곡 {i + 1} · 시드 {seed_i} · {length:.1f}초" + (" · 잘림" if truncated else "")
            out += [gr.update(value=path, label=label, visible=True), gr.update(value=score, visible=True)]
        elif i < n:
            out += [gr.update(value=None, label=f"곡 {i + 1} · 대기 중", visible=True), gr.update(value="", visible=False)]
        else:
            out += [gr.update(value=None, visible=False), gr.update(value="", visible=False)]
    return out


def generate(style, lyrics, mode, abc, seed, random_seed, batch):
    style, lyrics, abc = style.strip(), lyrics.strip(), (abc or "").strip()
    if not style or not lyrics:
        raise gr.Error("스타일과 가사를 모두 입력하세요.")
    if mode == "off" and abc:
        raise gr.Error("공급된 악보는 full 또는 melody 모드가 필요합니다.")
    n = int(batch)
    base = int(time.time()) % 10_000_000 if random_seed else int(seed)
    seeds = [base + i for i in range(n)]
    STOP.clear()
    first_line = next((l for l in lyrics.splitlines() if l.strip() and not l.strip().startswith("[")), lyrics)[:50]
    state = {"stage": "시작 중", "fraction": 0.0, "detail": "모델 로딩 중", "start": time.perf_counter(),
             "songs": ["대기 중"] * n, "results": [None] * n, "error": None, "done": False,
             "style": style, "lyric_start": first_line, "seeds": seeds, "mode": mode}
    yield [render_status(state), *outputs_for(state, n)]

    def run():
        try:
            worker(state, style, lyrics, mode, abc, seeds)
        except InterruptedError:
            state.update(stage="중단됨", detail="Stop 버튼으로 취소됨")
        except Exception as exc:
            state["error"] = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()
        finally:
            state["done"] = True
    threading.Thread(target=run, daemon=True).start()

    published = 0
    while not state["done"]:
        time.sleep(1)
        ready = sum(1 for r in state["results"] if r)
        if ready != published:
            published = ready
            yield [render_status(state), *outputs_for(state, n)]
        else:
            yield [render_status(state), *([gr.update()] * (2 * MAX_BATCH))]
    if state["error"]:
        raise gr.Error(state["error"])
    if state.get("batch_timing") and state["stage"] == "완료":
        bt = state["batch_timing"]
        total = time.perf_counter() - state["start"]
        state["detail"] = f"**{n}곡**이 **{total:.0f}초**에 생성됨. Token 단계는 {n}개 일괄 처리: "
                         f"{bt['aggregate_tps']:.1f} tokens/s, {1000 * (bt['mean_step_seconds'] or 0):.0f} ms/step. "
                         f"`{state['out_root'].relative_to(ROOT)}`에 저장됨"
    yield [render_status(state), *outputs_for(state, n)]


def write_lyrics_gemini(style, title, about):
    """Write lyrics using Gemini API."""
    if not GEMINI_API_KEY:
        return None, "Gemini API 키가 설정되지 않았습니다. 환경 변수 GEMINI_API_KEY을 설정하세요."

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    prompt = f"""You are a professional songwriter and lyricist.
Write original, emotional song lyrics with standard structure tags like [Verse], [Pre-Chorus], [Chorus], [Bridge], [Outro].
Match the requested language (Korean or English as requested), musical style, and theme.
Only output the lyrics and section tags without extra commentary.

Style: {style if style else "K-Pop ballad"}
Title: {title if title else "Untitled"}
Theme/Story: {about if about else "Heartfelt story"}"""

    payload = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.85, "maxOutputTokens": 2048}
    }).encode("utf-8")

    try:
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
            text = data["candidates"][0]["content"]["parts"][0]["text"]
            return text, None
    except Exception as e:
        return None, str(e)


def suggest_title(lyrics, style, instrumental):
    """Suggest a title using Gemini API."""
    if not GEMINI_API_KEY:
        return None

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    body = "An instrumental piece in this style: " + style if instrumental else "Lyrics:\n" + lyrics[:1500]
    prompt = f"""You name songs. Given lyrics or a style description, reply with ONE evocative title of 2 to 5 words.
Respond with the title ONLY in Korean or English, no quotes, no explanation.

{body}"""

    payload = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 60}
    }).encode("utf-8")

    try:
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
            return data["candidates"][0]["content"]["parts"][0]["text"].strip()
    except Exception:
        return None


def build():
    with gr.Blocks(title="YuE Studio") as demo:
        # Custom CSS for dark theme
        css = """
        .gradio-container { background-color: #10141d !important; }
        .block { background-color: #161b26 !important; }
        .button-primary { background: linear-gradient(to right, #7c3aed, #ec4899) !important; }
        .textbox, .number { background-color: #1e2535 !important; color: #e2e8f0 !important; border-color: #2a3449 !important; }
        """

        gr.Markdown("""
# 🎵 **YuE Studio**
**다크 테마 음악 스튜디오** - Gemini AI 가사 작성 & 음악 커버 기능

[Verse] [Pre-Chorus] [Chorus] [Bridge] 로 구간을 나누면 곡 구조가 좋아집니다.
""")

        with gr.Row():
            with gr.Column(scale=1):
                # Top Bar
                with gr.Accordion("상단 바", open=False):
                    gr.Markdown("### YuE Studio v2.0")
                    gr.Markdown(f"**Gemini:** {GEMINI_MODEL if GEMINI_API_KEY else '설정 필요'}")

                # Lyrics Section
                with gr.Accordion("가사", open=True):
                    title = gr.Textbox(label="곡 제목", value="", placeholder="AI가 자동으로 채울 수 있습니다")
                    instrumental = gr.Checkbox(label="가사 없이 (연주곡)", value=False)
                    lyrics = gr.Textbox(label="가사", value=EXAMPLE["lyrics"], lines=14,
                                        info="[Verse] [Chorus] [Bridge] 태그 사용 가능")

                    with gr.Row():
                        write_lyrics_btn = gr.Button("🤖 AI 가사 작성 (Gemini)", variant="primary")
                        tag_guide_btn = gr.Button("📖 태그 안내")

                    tag_guide_modal = gr.Markdown("### 태그 안내\n\n"
                        "[Verse] - 4-6줄, 구체적인 이미지와 스토리 전개\n"
                        "[Pre-Chorus] - 2-4줄, 후렴부로 이어지는 연결\n"
                        "[Chorus] - 4줄, 가장 기억에 남는 훅\n"
                        "[Bridge] - 3-4줄, 새로운 관점\n"
                        "[Outro] - 2-3줄, 곡 마무리")

                    write_lyrics_btn.click(
                        fn=write_lyrics_gemini,
                        inputs=[style, title, gr.Textbox(value="")],
                        outputs=[lyrics, gr.Markdown()]
                    )

                # Style Tags
                with gr.Accordion("스타일 태그", open=False):
                    gr.Markdown("스타일 칩을 클릭하면 프롬프트에 추가됩니다:")
                    for tag in STYLE_TAGS.keys():
                        gr.Markdown(f"- **{tag}**")

                # Style Prompt
                with gr.Accordion("스타일 프롬프트", open=True):
                    style = gr.Textbox(label="스타일", value=EXAMPLE["style"], lines=3,
                                       info="장르, 악기, 보컬 , 분위기, BPM을 영어로 적으면 가장 잘 나옵니다.")

                    with gr.Row():
                        seed = gr.Number(value=EXAMPLE["seed"], precision=0, label="시드", value=831001)
                        random_seed = gr.Checkbox(label="랜덤", value=False)
                        batch = gr.Slider(1, MAX_BATCH, value=2, step=1, label="곡 수")

                    mode = gr.Radio(["full", "melody", "off"], value="full", label="계획 모드",
                                    info="full: 멜로디+화성 · melody: 멜로디만 · off: 직접")

                # ABC Score (Cover)
                with gr.Accordion("음원 업로드 (음악 커버)", open=False):
                    audio_upload = gr.Audio(label="원곡 오디오 (WAV/MP3/M4A)", type="filepath")
                    transcribe_btn = gr.Button("멜로디 전사 (SheetSage2)")
                    abc = gr.Textbox(label="ABC 악보 (자동 추출됨)", lines=8, interactive=False)

                # Generate Button
                with gr.Row():
                    generate_btn = gr.Button("🎵 곡 만들기", variant="primary")
                    stop_btn = gr.Button("⏹ 중단")

                status = gr.Markdown("준비됨. AI 가사 작성을하려면 Gemini API 키를 설정하세요.")

            with gr.Column(scale=1):
                # Right Sidebar - 내 곡
                gr.Markdown("### 내 곡")
                gr.Markdown("[v] 완성되면 MP3로 자동 저장 | [ ] 원본 WAV 지워 용량 아끼기")

                players, scores = [], []
                for i in range(MAX_BATCH):
                    players.append(gr.Audio(label=f"곡 {i + 1}", type="filepath", visible=False, interactive=False))
                    scores.append(gr.Textbox(label=f"악보 {i + 1} (ABC)", lines=6, visible=False))

        outputs = [status]
        for player, score in zip(players, scores):
            outputs += [player, score]

        generate_btn.click(
            generate,
            inputs=[style, lyrics, mode, abc, seed, random_seed, batch],
            outputs=outputs,
            show_progress="minimal"
        )
        stop_btn.click(lambda: STOP.set(), None, None, queue=False)

    return demo


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7860)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    build().queue(default_concurrency_limit=1).launch(server_name="127.0.0.1", server_port=args.port,
                                                      inbrowser=not args.no_browser, show_error=True)
