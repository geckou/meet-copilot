#!/usr/bin/env python3
"""会話のログから「相手が答えを求めている箇所」を候補として抜き出す外部プロセス。
meet-copilot record --candidates から1つ起動される。

受け渡しの約束は Sources/Candidates/CandidateExtractor.swift を参照:
- 標準入力: 文字起こし1件につき1行の JSON。{"speaker": "相手"|"自分", "track": "app"|"mic", "start": 秒, "end": 秒, "text": "..."}
  閉じられたら、まだ見ていない分を処理して終了する
- 標準出力: 候補1件につき1行の JSON。{"at": 秒, "question": "...", "quote": "..."}

相手の発言が来てから少し待ち（続きの発言や自分の反応も含めるため）、直近のやり取りを claude -p に渡す。
抽出は1回ずつ順に行い、実行中に来た発言は次の回にまとめる。標準ライブラリだけで動く。
"""

import argparse
import glob
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

OTHER = "相手"

SYSTEM_PROMPT = """\
あなたは会議に同席して、話し手（「自分」）の代わりに調べものを用意する助手。
渡されるのは Google Meet の会議の文字起こしで、「自分」はマイク、「相手」は会議相手の音声。

仕事は、相手が「自分」に答えや確認を求めている箇所を、調べる候補として抜き出すこと。
対象：
- 疑問形で終わっている相手の発言
- 「どうなってましたっけ」「〜でしたよね」のような確認の要求
- 相手の問いに自分が答えに詰まっている、言いよどんでいる、後で確認すると言っている箇所
対象外：
- 相槌、挨拶、雑談、すでにその場で答えが出て解決したもの
- 「自分」から相手への質問

文字起こしには聞き間違いがある。特に短い発言は言っていない文に置き換わっていることがあるので、
前後と噛み合わない短い発言は根拠にしない。

すでに出した候補（previous）と同じ問いは出さない。新しい候補がなければ空の配列を返す。
question は、ソースコードやドキュメントを調べる人が単独で読んで何を調べればよいか分かる一文にする。
quote は根拠になった相手の発言をそのまま写す。at はその発言の start 秒。
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "at": {"type": "number"},
                    "question": {"type": "string"},
                    "quote": {"type": "string"},
                },
                "required": ["at", "question", "quote"],
            },
        }
    },
    "required": ["candidates"],
}


def log(message):
    print(f"[candidates] {message}", file=sys.stderr, flush=True)


def positive(value):
    number = float(value)
    if not (math.isfinite(number) and number > 0):
        raise argparse.ArgumentTypeError("正の有限の数")
    return number


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--claude-bin", default=os.environ.get("MEET_COPILOT_CLAUDE"),
                   help="claude の実行ファイル。省略時は PATH とよくある置き場所から探す（環境変数 MEET_COPILOT_CLAUDE でも指定可）")
    p.add_argument("--model", default="sonnet")
    p.add_argument("--settle", type=positive, default=2.0, help="相手の最後の発言からこの秒数だけ新しい発言がなければ抽出する")
    p.add_argument("--window", type=positive, default=180.0, help="最新の発言からこの秒数分さかのぼったやり取りを渡す")
    p.add_argument("--timeout", type=positive, default=120.0, help="claude -p 1回の上限秒数")
    return p.parse_args()


def find_claude(explicit):
    """claude の実行ファイルを探す。nvm で入れた場合は PATH に無いことがあるので、よくある置き場所も見る。"""
    if explicit:
        return explicit
    if found := shutil.which("claude"):
        return found
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, ".claude", "local", "claude"),
        os.path.join(home, ".local", "bin", "claude"),
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    def node_version(path):
        version = path.split(os.sep)[-3].lstrip("v")
        return tuple(int(part) if part.isdigit() else 0 for part in version.split("."))

    # 新しい node のものを優先する
    candidates += sorted(glob.glob(os.path.join(home, ".nvm", "versions", "node", "*", "bin", "claude")), key=node_version, reverse=True)
    for path in candidates:
        if os.access(path, os.X_OK):
            return path
    log("claude が見つからない。--claude-bin か環境変数 MEET_COPILOT_CLAUDE で場所を指定する")
    sys.exit(1)


def format_time(seconds):
    minutes = int(seconds // 60)
    return f"{minutes:02d}:{seconds - minutes * 60:04.1f}"


def build_prompt(utterances, previous, window):
    latest = max(u["end"] for u in utterances)
    recent = [u for u in utterances if u["end"] >= latest - window]
    lines = [f'[{format_time(u["start"])} / start={u["start"]}] {u["speaker"]}: {u["text"]}' for u in recent]
    return (
        "## previous（すでに出した候補）\n"
        + (json.dumps(previous, ensure_ascii=False, indent=1) if previous else "なし")
        + "\n\n## 文字起こし（直近）\n"
        + "\n".join(lines)
    )


def run_claude(args, prompt, workdir):
    command = [
        args.claude_bin, "-p",
        "--model", args.model,
        "--tools", "",
        "--no-session-persistence",
        "--output-format", "json",
        "--json-schema", json.dumps(SCHEMA),
        "--system-prompt", SYSTEM_PROMPT,
    ]
    result = subprocess.run(
        command,
        input=prompt,
        capture_output=True,
        text=True,
        timeout=args.timeout,
        # このリポジトリの CLAUDE.md などを読み込ませないよう、空のディレクトリで動かす
        cwd=workdir,
        # 端末の Ctrl-C は録音側が受ける。抽出中の claude まで止まらないよう別グループにする
        start_new_session=True,
        # nvm で入れた claude は同じ場所の node で動くので、その場所を PATH の先頭に足す
        env={**os.environ, "PATH": os.path.dirname(args.claude_bin) + os.pathsep + os.environ.get("PATH", "")},
    )
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"claude -p の出力を読めない（終了コード {result.returncode}）: {result.stderr.strip() or result.stdout.strip()}")
    if result.returncode != 0 or response.get("is_error"):
        raise RuntimeError(f"claude -p が失敗: {response.get('result')}")
    output = response.get("structured_output")
    if not isinstance(output, dict) or not isinstance(output.get("candidates"), list):
        raise RuntimeError(f"claude -p の結果が想定の形でない: {response.get('result')}")
    return output["candidates"]


class Conversation:
    """標準入力から届く発言を溜め、抽出すべき時点を知らせる。"""

    def __init__(self):
        self.cond = threading.Condition()
        self.utterances = []
        self.closed = False
        self.unseen_other = False  # 前回の抽出以降に相手の発言が来ている
        self.last_arrival = 0.0

    def read(self, stream):
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                utterance = json.loads(line)
                utterance = {k: utterance[k] for k in ("speaker", "start", "end", "text")}
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                log(f"入力の行を読めない: {error}: {line}")
                continue
            with self.cond:
                self.utterances.append(utterance)
                self.last_arrival = time.monotonic()
                if utterance["speaker"] == OTHER:
                    self.unseen_other = True
                self.cond.notify_all()
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def wait_for_batch(self, settle):
        """抽出すべき時点まで待ち、その時点までの発言を返す。入力が閉じて残りもなければ None。"""
        with self.cond:
            while True:
                if self.unseen_other:
                    if self.closed:
                        break
                    remaining = settle - (time.monotonic() - self.last_arrival)
                    if remaining <= 0:
                        break
                    self.cond.wait(remaining)
                elif self.closed:
                    return None
                else:
                    self.cond.wait()
            self.unseen_other = False
            return list(self.utterances)


def main():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    args = parse_args()
    args.claude_bin = find_claude(args.claude_bin)
    conversation = Conversation()
    threading.Thread(target=conversation.read, args=(sys.stdin,), daemon=True).start()

    previous = []
    failures = 0
    with tempfile.TemporaryDirectory(prefix="meet-copilot-candidates-") as workdir:
        while (utterances := conversation.wait_for_batch(args.settle)) is not None:
            started = time.monotonic()
            try:
                candidates = run_claude(args, build_prompt(utterances, previous, args.window), workdir)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                log(f"抽出失敗: {error}")
                failures += 1
                continue
            log(f"抽出 {len(candidates)} 件（{time.monotonic() - started:.1f} 秒）")
            for candidate in candidates:
                record = {"at": candidate["at"], "question": candidate["question"], "quote": candidate["quote"]}
                # 指示していても同じ候補を返すことがあるので、完全に同じものはここで落とす
                if record in previous:
                    continue
                previous.append(record)
                print(json.dumps(record, ensure_ascii=False), flush=True)
    if failures:
        log(f"抽出に失敗した回: {failures} 回")
        sys.exit(1)


if __name__ == "__main__":
    main()
