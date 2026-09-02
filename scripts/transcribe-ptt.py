#!/usr/bin/env python3
"""PTT wav -> Nemotron ASR -> S1-mini by Superwhisper -> one stdout line.

Serve mode keeps S1-mini loaded. The Mac app talks to stdin/stdout.
Never print audio bytes or raw transcripts to stderr.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

STT_ROOT = Path(os.environ.get("PHONE_REMOTE_STT_ROOT", Path.home() / "stt-tts-agent")).expanduser()
sys.path.insert(0, str(STT_ROOT))

from paths import REPOS, hf_snapshot, require_file  # noqa: E402

S1_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)
HAN = re.compile(r"[\u4e00-\u9fff]")
LANG_TAG = re.compile(r"<[A-Za-z]{2}(?:-[A-Za-z]{2})?>")


def nemo_speech_bin() -> str:
    path = shutil.which("nemo-speech") or str(Path.home() / ".local/bin/nemo-speech")
    if not Path(path).is_file():
        raise FileNotFoundError("nemo-speech missing")
    return path


def gguf_path() -> Path:
    snap = hf_snapshot(REPOS["nemotron"])
    return require_file(
        snap / "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf",
        "hf download nvidia/nemotron-3.5-asr-streaming-0.6b",
    )


def s1_gguf_path() -> Path:
    snap = hf_snapshot(REPOS["s1_mini"])
    return require_file(
        snap / "s1-mini-f16.gguf",
        "hf download superwhisper/s1-mini-GGUF",
    )


def clean_asr(text: str) -> str:
    return LANG_TAG.sub("", text).strip()


def looks_chinese(text: str) -> bool:
    han = len(HAN.findall(text))
    if han == 0:
        return False
    letters = len(re.findall(r"[A-Za-z]", text))
    return han >= letters


class Cleaner:
    def __init__(self) -> None:
        from llama_cpp import Llama

        gguf = s1_gguf_path()
        self.llm = Llama(
            model_path=str(gguf),
            n_ctx=2048,
            n_gpu_layers=-1,
            verbose=False,
        )

    def clean(self, text: str) -> str:
        text = text.strip()
        if not text:
            return ""
        control = "[Styling: semi-formal] [Structure: prose] [Context: general]"
        prompt = (
            f"<|im_start|>system\n{S1_SYSTEM}<|im_end|>\n"
            f"<|im_start|>user\n{control}\n{text}<|im_end|>\n"
            "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
        t_tokens = max(1, len(self.llm.tokenize(text.encode("utf-8"), add_bos=False)))
        max_new = max(16, min(256, int(1.3 * t_tokens) + 32))
        out = self.llm(
            prompt,
            max_tokens=max_new,
            temperature=0,
            stop=["<|im_end|>", "<|endoftext|>"],
        )
        return out["choices"][0]["text"].strip()


def transcribe_wav(wav: Path, language: str) -> str:
    cmd = [
        nemo_speech_bin(),
        "transcribe",
        str(wav),
        "--model",
        str(gguf_path()),
        "--language",
        language,
        "--device",
        "metal",
    ]
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return clean_asr(result.stdout.strip())


def one_line(text: str) -> str:
    return " ".join(text.split())


def process_wav(wav: Path, cleaner: Cleaner | None, language: str) -> str:
    heard = transcribe_wav(wav, language)
    if not heard:
        return ""
    if cleaner is not None and not looks_chinese(heard):
        try:
            cleaned = cleaner.clean(heard)
        except Exception:
            cleaned = heard
        if cleaned:
            heard = cleaned
    return one_line(heard)


SERVE_PORT = int(os.environ.get("PHONE_REMOTE_NEMO_PORT", "18766"))
_serve_proc: subprocess.Popen | None = None


def health_ok() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{SERVE_PORT}/health", timeout=1) as resp:
            return resp.status == 200
    except Exception:
        return False


def ensure_serve() -> None:
    global _serve_proc
    if health_ok():
        return
    cmd = [
        nemo_speech_bin(),
        "serve",
        "--asr-model",
        str(gguf_path()),
        "--device",
        "metal",
        "--host",
        "127.0.0.1",
        "--port",
        str(SERVE_PORT),
        "--no-ui",
        "--read-timeout",
        "120",
        "--write-timeout",
        "120",
    ]
    _serve_proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + 40
    while time.time() < deadline:
        if health_ok():
            return
        if _serve_proc.poll() is not None:
            raise RuntimeError("asr server exited")
        time.sleep(0.2)
    raise RuntimeError("asr server timeout")


def open_stream(language: str):
    ensure_serve()
    from websocket import create_connection

    ws = create_connection(f"ws://127.0.0.1:{SERVE_PORT}/v1/realtime", timeout=30)
    try:
        ws.recv()
    except Exception:
        pass
    ws.send(
        json.dumps(
            {
                "type": "session.update",
                "session": {"sample_rate": 16_000, "language": language},
            }
        )
    )
    try:
        ws.settimeout(2)
        ws.recv()
    except Exception:
        pass
    ws.settimeout(30)
    return ws


def finish_stream(ws) -> str:
    if ws is None:
        return ""
    ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
    deadline = time.time() + 30
    final = ""
    while time.time() < deadline:
        ws.settimeout(max(0.2, deadline - time.time()))
        try:
            raw = ws.recv()
        except Exception:
            break
        if isinstance(raw, (bytes, bytearray)):
            continue
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        kind = str(msg.get("type", ""))
        if kind.endswith("completed"):
            final = str(msg.get("transcript") or msg.get("text") or "")
            break
        if kind == "error":
            break
    try:
        ws.close()
    except Exception:
        pass
    return clean_asr(final)


def close_stream(ws, commit: bool) -> None:
    if ws is None:
        return
    try:
        if commit:
            ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
        else:
            ws.send(json.dumps({"type": "input_audio_buffer.clear"}))
    except Exception:
        pass
    try:
        ws.close()
    except Exception:
        pass


def serve(language: str) -> None:
    cleaner: Cleaner | None = None
    ws = None
    print("READY", flush=True)
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line or line == "QUIT":
                break
            if line == "PING":
                print("PONG", flush=True)
                continue
            if line == "STREAM":
                close_stream(ws, commit=False)
                try:
                    ws = open_stream(language)
                except Exception:
                    ws = None
                    print("ERR", flush=True)
                continue
            if line == "CANCEL":
                close_stream(ws, commit=False)
                ws = None
                continue
            if line == "END":
                try:
                    text = finish_stream(ws)
                    ws = None
                    if cleaner is None:
                        cleaner = Cleaner()
                    if text and not looks_chinese(text):
                        try:
                            cleaned = cleaner.clean(text)
                        except Exception:
                            cleaned = text
                        if cleaned:
                            text = cleaned
                    print("OK " + one_line(text), flush=True)
                except Exception:
                    ws = None
                    print("ERR", flush=True)
                continue
            if line.startswith("PCM ") and ws is not None:
                try:
                    pcm = base64.b64decode(line[4:])
                    if pcm:
                        ws.send_binary(pcm)
                except Exception:
                    pass
                continue
            wav = Path(line)
            try:
                if cleaner is None:
                    cleaner = Cleaner()
                if not wav.is_file():
                    print("ERR", flush=True)
                    continue
                text = process_wav(wav, cleaner, language)
                print("OK " + text, flush=True)
            except Exception:
                print("ERR", flush=True)
    finally:
        close_stream(ws, commit=False)
        if _serve_proc is not None and _serve_proc.poll() is None:
            _serve_proc.terminate()


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe a PTT wav with Nemotron and S1-mini")
    parser.add_argument("wav", nargs="?", help="WAV path. Omit with --serve.")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--language", default="en-US")
    parser.add_argument("--no-s1", action="store_true")
    args = parser.parse_args()

    if args.serve:
        serve(args.language)
        return

    if not args.wav:
        raise SystemExit("wav path required unless --serve")
    wav = Path(args.wav).expanduser().resolve()
    if not wav.is_file():
        raise SystemExit(f"No audio file: {wav}")
    cleaner = None if args.no_s1 else Cleaner()
    print(process_wav(wav, cleaner, args.language))


if __name__ == "__main__":
    main()
