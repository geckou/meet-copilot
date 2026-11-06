#!/usr/bin/env python3
"""whisper.cpp で文字起こしする外部プロセス。meet-copilot record --transcribe から、録音1回につき
whisper-server の管理役（--serve）が1つと、文字起こし役がトラックごとに1つ起動される。

受け渡しの約束は Sources/Transcription/TranscriberProcess.swift を参照:
- 標準入力: 16kHz・モノラル・16bit 符号付き・リトルエンディアンの生 PCM。閉じられたら残りを処理して終了する
- 標準出力: 1行1件の JSON。{"start": 秒, "end": 秒, "text": "..."}

whisper.cpp には標準入力を受けて逐次処理する仕組みがないので、ここで音量から発話の区切りを見つけ、
区切りごとに whisper-server へ送る。モデルを二重に読まないよう、whisper-server は管理役が空きポートで1つだけ起動し、
準備ができたら URL を --url-file に書く。起動に失敗したら空のファイルを書く。管理役は標準入力が閉じられたら止める。
標準ライブラリだけで動く。
"""

import argparse
import array
import io
import json
import math
import os
import queue
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave

SAMPLE_RATE = 16_000
FRAME_SECONDS = 0.1
FRAME_BYTES = int(SAMPLE_RATE * FRAME_SECONDS) * 2
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 送り先は自分で立てた whisper-server だけ。環境変数のプロキシを通すと会議の音声が外に出うるので使わない
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(message):
    track = os.environ.get("MEET_COPILOT_TRACK", "?")
    print(f"[transcribe:{track}] {message}", file=sys.stderr, flush=True)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url-file", required=True, help="whisper-server の URL を受け渡すファイル")
    p.add_argument("--serve", action="store_true", help="文字起こしせず、whisper-server の管理役として動く")
    p.add_argument("--model", default=os.path.join(REPO_ROOT, "models", "ggml-large-v3-turbo.bin"))
    p.add_argument("--language", default="ja")
    p.add_argument("--server-bin", default="whisper-server")
    p.add_argument("--threshold-db", type=float, default=-45.0, help="これより大きい音量（RMS, dBFS）を発話とみなす")
    p.add_argument("--silence", type=float, default=0.6, help="発話の後にこの秒数だけ静かなら区切る")
    p.add_argument("--max-seconds", type=float, default=15.0, help="発話が続いてもこの秒数で区切る")
    p.add_argument("--min-seconds", type=float, default=0.3, help="これより短い発話は捨てる")
    p.add_argument("--pre-roll", type=float, default=0.3, help="発話の頭が欠けないよう、直前の音をこの秒数だけ含める")
    args = p.parse_args()
    # inf や nan はフレーム数に直せず、区切りの処理が途中で落ちて終われなくなるので、起動前に弾く
    if not math.isfinite(args.threshold_db):
        p.error("--threshold-db は有限の数")
    for name in ("silence", "max_seconds", "min_seconds"):
        value = getattr(args, name)
        if not (math.isfinite(value) and value > 0):
            p.error(f"--{name.replace('_', '-')} は正の有限の数")
    if not (math.isfinite(args.pre_roll) and args.pre_roll >= 0):
        p.error("--pre-roll は 0 以上の有限の数")
    return args


# MARK: - whisper-server


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server(args):
    """whisper-server を起動し、応答するまで待つ。失敗は RuntimeError か OSError。"""
    if not os.path.exists(args.model):
        raise RuntimeError(f"モデルがない: {args.model}（README の手順で落とす）")
    port = free_port()
    server = subprocess.Popen(
        [args.server_bin, "-m", args.model, "-l", args.language, "--host", "127.0.0.1", "--port", str(port)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        # 端末の Ctrl-C は録音側が受けて止める。サーバーまで届くと残りを処理できなくなるので別グループにする
        start_new_session=True,
    )
    url = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"whisper-server が起動直後に終了した（終了コード {server.returncode}）")
        try:
            HTTP.open(url, timeout=1).close()
            log(f"whisper-server 起動: {url}")
            return server, url
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            time.sleep(0.2)
    server.terminate()
    server.wait()
    raise RuntimeError("whisper-server が 60 秒以内に応答しない")


def publish_url(path, url):
    """途中まで書いた内容を読まれないよう、書き終えてから置く。"""
    temporary = f"{path}.tmp"
    with open(temporary, "w") as f:
        f.write(url)
    os.replace(temporary, path)


def wait_for_url(path):
    """管理役が書いた URL を読む。読めなければログを出して終了する。"""
    # 管理役は 60 秒で諦めて空のファイルを書くので、それより長く待つ
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with open(path) as f:
                url = f.read()
        except FileNotFoundError:
            time.sleep(0.2)
            continue
        if not url:
            log("whisper-server を起動できなかった")
            sys.exit(1)
        return url
    log("whisper-server の起動を待ちきれなかった")
    sys.exit(1)


def serve(args):
    """whisper-server を起動して URL を知らせ、標準入力が閉じられたら止める。"""
    server = None
    try:
        server, url = start_server(args)
    except (RuntimeError, OSError) as error:
        log(str(error))
        url = ""
    # whisper-server は別グループで動くので、ここで止めないと失敗時にモデルを抱えたまま残る
    try:
        publish_url(args.url_file, url)
        sys.stdin.buffer.read()
        # 文字起こし役が読み終えているので、ここで消してよい
        os.unlink(args.url_file)
    finally:
        crashed = server is not None and server.poll() is not None
        if server is not None:
            server.terminate()
            server.wait()
    if server is None:
        sys.exit(1)
    if crashed:
        log(f"whisper-server が途中で終了した（終了コード {server.returncode}）")
        sys.exit(1)


def transcribe(url, pcm):
    wav = io.BytesIO()
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)

    boundary = uuid.uuid4().hex
    parts = [
        f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'.encode(),
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="chunk.wav"\r\n'
        "Content-Type: audio/wav\r\n\r\n".encode(),
        wav.getvalue(),
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    request = urllib.request.Request(
        f"{url}/inference",
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with HTTP.open(request, timeout=120) as response:
        text = json.load(response).get("text", "")
    # whisper の内部の区切りごとに改行が入るので、1件1行に収める
    return " ".join(line.strip() for line in text.splitlines() if line.strip())


# MARK: - 発話の区切り


def rms_db(frame):
    samples = array.array("h", frame)
    mean_square = sum(s * s for s in samples) / len(samples)
    return 10 * math.log10(mean_square / (32768.0 ** 2)) if mean_square > 0 else -math.inf


def segment_stdin(args, segments):
    """標準入力を 0.1 秒ずつ読み、発話のまとまりを (開始秒, PCM) で segments に積む。終わりに None を積む。"""
    try:
        read_segments(args, segments)
    except Exception as error:  # noqa: BLE001 ここで落ちても None は積まないと main が終われない
        log(f"音声の読み取り・区切りに失敗: {error}")
        segments.put(("error", None))
    finally:
        segments.put(None)


def read_segments(args, segments):
    pre_roll_frames = max(0, round(args.pre_roll / FRAME_SECONDS))
    silence_frames = max(1, round(args.silence / FRAME_SECONDS))
    max_frames = max(1, round(args.max_seconds / FRAME_SECONDS))
    min_frames = max(1, round(args.min_seconds / FRAME_SECONDS))

    recent = []  # 発話前の直近の音（pre-roll 用）
    current = []  # 発話中のフレーム
    current_start = 0
    voiced = 0  # current のうち発話と判定したフレーム数
    quiet = 0  # 末尾から続く静かなフレーム数
    index = 0
    after_max_split = False  # 直前の区切りが最大長によるもので、まだ発話が途切れていない
    continues_previous = False  # current が最大長で区切られた発話の続き
    idle = 0  # 発話の外で続いている静かなフレーム数

    def flush(by_max):
        nonlocal current, recent, voiced, quiet, after_max_split, idle
        # 末尾の静かな部分は送らない
        frames = current[: len(current) - quiet] if quiet < len(current) else current
        # 最大長で区切った発話の続きは、短くても捨てない
        if voiced >= min_frames or (continues_previous and voiced > 0):
            segments.put((current_start * FRAME_SECONDS, b"".join(frames)))
        after_max_split = by_max
        idle = quiet
        # 送らなかった末尾の静かな部分は、すぐ次の発話が始まったときの pre-roll に回す
        trailing = current[len(current) - quiet :] if quiet else []
        recent = trailing[-pre_roll_frames:] if pre_roll_frames else []
        current, voiced, quiet = [], 0, 0

    stdin = sys.stdin.buffer
    while True:
        frame = stdin.read(FRAME_BYTES)
        if not frame:
            break
        loud = rms_db(frame) > args.threshold_db
        if current:
            current.append(frame)
            if loud:
                voiced += 1
                quiet = 0
            else:
                quiet += 1
            if quiet >= silence_frames:
                flush(by_max=False)
            elif len(current) >= max_frames:
                flush(by_max=True)
        elif loud:
            current_start = index - len(recent)
            current = recent + [frame]
            recent = []
            voiced, quiet = 1, 0
            continues_previous = after_max_split
        else:
            recent = (recent + [frame])[-pre_roll_frames:] if pre_roll_frames else []
            # 区切りの後に静かな時間が続いたら、発話は途切れたとみなす
            idle += 1
            if idle >= silence_frames:
                after_max_split = False
        index += 1
    if current:
        flush(by_max=False)


# MARK: - main


def main():
    # 端末の Ctrl-C は録音側が受ける。こちらは標準入力が閉じられるまで残りを処理し続ける
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    args = parse_args()
    if args.serve:
        serve(args)
        return
    url = wait_for_url(args.url_file)
    log(f"whisper-server: {url}")
    failures = 0
    segments = queue.Queue()
    # 文字起こし中も標準入力を読み続けないと、パイプが詰まって録音側に溜まる
    threading.Thread(target=segment_stdin, args=(args, segments), daemon=True).start()
    while (item := segments.get()) is not None:
        start, pcm = item
        if pcm is None:  # 区切りの処理が失敗した
            failures += 1
            continue
        end = start + len(pcm) / 2 / SAMPLE_RATE
        try:
            text = transcribe(url, pcm)
        except Exception as error:  # noqa: BLE001 1区切りの失敗で全体を止めない
            log(f"{start:.1f}s 〜 {end:.1f}s の文字起こし失敗: {error}")
            failures += 1
            continue
        if text:
            print(json.dumps({"start": round(start, 2), "end": round(end, 2), "text": text}, ensure_ascii=False), flush=True)
    # 残りの区切りは処理し続けたうえで、取りこぼしがあったことを終了コードで録音側に伝える
    if failures:
        log(f"文字起こしに失敗した区切り: {failures} 件")
        sys.exit(1)


if __name__ == "__main__":
    main()
