#!/usr/bin/env python3
"""候補の問いについて、ローカルのリポジトリを読んで（--repo が無ければ Web で調べて）答えを用意する外部プロセス。
meet-copilot answer と UI から1つ起動される。

受け渡しの約束は Sources/Candidates/CandidateAnswerer.swift を参照:
- 標準入力: 問い1件につき1行の JSON。{"meeting": "...", "at": 秒, "question": "...", "quote": "...", "context": [{"speaker", "start", "text"}, ...]}
  閉じられたら、受け取った分を処理して終了する
- 標準出力: 問い1件につき1行の JSON。meeting / at / question は問いのものをそのまま返す
  答え: {"meeting", "at", "question", "answer", "confidence", "sources": [{"path", "line"}]}
  （Web で調べたときの path は URL で、line は無い）
  調べられなかったとき: {"meeting", "at", "question", "error"}

問いは届いた順に1件ずつ処理する。--repo があれば、claude -p には読み取り用のツール（Read / Grep / Glob）だけを渡し、
1つ目の --repo を作業ディレクトリ、残りを --add-dir にする。
--repo が無ければ WebSearch / WebFetch だけを渡し、空の一時ディレクトリで動かす。標準ライブラリだけで動く。
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

from claude_cli import ClaudeError, add_claude_arguments, find_claude, format_time, run_claude

REPO_TOOLS = ("Read", "Grep", "Glob")
WEB_TOOLS = ("WebSearch", "WebFetch")

COMMON_PROMPT = """\
あなたは会議中の話し手（「自分」）の隣で、会議相手からの問いに答えるための調べものをする助手。
渡されるのは、会議の文字起こしから抜き出した問いと、その前後のやり取り。
"""

COMMON_RULES = """\
- answer は、話し手が会議でそのまま口にできる 2〜3 文、合わせて 120 字程度の日本語。1 文目に結論を書く
- 聞かれていない補足（オプション、例外、関連する設定など）は書かない。答えに要るものだけにする
- 時間をかけすぎない。会議中に使うので、関係の薄いものまで読み広げない
"""

REPO_PROMPT = COMMON_PROMPT + """\
作業ディレクトリ（と追加のディレクトリ）にあるリポジトリを Read / Grep / Glob で読み、答えを用意する。

- 推測で答えない。コード・設定・ドキュメントで確かめたことだけを書く。確かめられなければ、answer にはその旨と主に見た場所1つだけを書き、
  見たが根拠にならなかったファイルは sources に入れない
- sources には、根拠にしたファイルをリポジトリからの相対パスと行番号で挙げる（最大 5 件）
- confidence：コードで直接確かめた → high、状況から強く推定できる → medium、見つからない・判断できない → low
- 文字起こしには聞き間違いがある。問いの固有名詞がリポジトリに無ければ、似た名前を探す
""" + COMMON_RULES

WEB_PROMPT = COMMON_PROMPT + """\
WebSearch / WebFetch で調べ、答えを用意する。

- 推測で答えない。調べて確かめたことだけを書く。確かめられなければ、answer にはその旨だけを書き、
  見たが根拠にならなかったページは sources に入れない
- sources には、根拠にしたページの URL を path に入れて挙げる（line は付けない。最大 5 件）。公式のドキュメントを優先する
- confidence：信頼できる出典で直接確かめた → high、複数の出典から強く推定できる → medium、見つからない・判断できない → low
- 文字起こしには聞き間違いがある。問いの固有名詞で見つからなければ、似た名前で探す
""" + COMMON_RULES

SCHEMA = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "sources": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"path": {"type": "string"}, "line": {"type": "integer"}},
                "required": ["path"],
            },
        },
    },
    "required": ["answer", "confidence", "sources"],
}


def log(message):
    print(f"[answer] {message}", file=sys.stderr, flush=True)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", action="append", default=[],
                   help="調べるリポジトリ。複数指定できる。1つ目を作業ディレクトリにする。省略時は Web で調べる")
    add_claude_arguments(p, model="sonnet", timeout=300.0)
    args = p.parse_args()
    args.repo = [os.path.abspath(os.path.expanduser(r)) for r in args.repo]
    for repo in args.repo:
        if not os.path.isdir(repo):
            p.error(f"--repo がディレクトリでない: {repo}")
    return args


def build_prompt(request):
    lines = [f'[{format_time(u["start"])}] {u["speaker"]}: {u["text"]}' for u in request.get("context", [])]
    return (
        f'## 問い\n{request["question"]}\n\n'
        f'## 根拠になった相手の発言（{format_time(request["at"])}）\n{request["quote"]}\n\n'
        "## 前後のやり取り\n" + ("\n".join(lines) if lines else "なし")
    )


def echo(request):
    """問いから答えにそのまま返す分。呼び出し元はこれで問いと答えを対応付ける"""
    return {"meeting": request.get("meeting"), "at": request["at"], "question": request["question"]}


def answer(args, request):
    if args.repo:
        options = {"append_system_prompt": REPO_PROMPT, "tools": REPO_TOOLS, "cwd": args.repo[0], "add_dirs": args.repo[1:]}
    else:
        # 起動したディレクトリの CLAUDE.md などを読ませないよう、空のディレクトリで動かす
        options = {"append_system_prompt": WEB_PROMPT, "tools": WEB_TOOLS, "cwd": args.workdir}
    output = run_claude(
        args.claude_bin, build_prompt(request),
        model=args.model, schema=SCHEMA, timeout=args.timeout,
        **options,
    )
    sources = output.get("sources")
    if not (isinstance(output.get("answer"), str) and output.get("confidence") in ("high", "medium", "low")
            and isinstance(sources, list) and all(isinstance(s, dict) and isinstance(s.get("path"), str) for s in sources)):
        raise ClaudeError(f"claude -p の答えが想定の形でない: {output}")
    return {
        **echo(request),
        "answer": output["answer"],
        "confidence": output["confidence"],
        "sources": [{"path": s["path"], **({"line": s["line"]} if isinstance(s.get("line"), int) else {})} for s in sources],
    }


def main():
    # Ctrl-C は呼び出し元が受ける。こちらは標準入力が閉じられるまで受け取った問いを処理する
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    args = parse_args()
    try:
        args.claude_bin = find_claude(args.claude_bin)
    except ClaudeError as error:
        log(str(error))
        sys.exit(1)

    workdir = None if args.repo else tempfile.TemporaryDirectory(prefix="meet-copilot-answer-")
    args.workdir = workdir and workdir.name

    failures = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            if not (isinstance(request.get("question"), str) and isinstance(request.get("quote"), str)
                    and isinstance(request.get("at"), (int, float))):
                raise ValueError("question / quote / at が無い")
        except (json.JSONDecodeError, ValueError, AttributeError) as error:
            log(f"入力の行を読めない: {error}: {line}")
            failures += 1
            continue
        started = time.monotonic()
        try:
            result = answer(args, request)
        except (ClaudeError, OSError, subprocess.TimeoutExpired) as error:
            log(f"「{request['question']}」の調査失敗: {error}")
            print(json.dumps({**echo(request), "error": str(error)}, ensure_ascii=False), flush=True)
            failures += 1
            continue
        log(f"「{request['question']}」の調査完了（{time.monotonic() - started:.1f} 秒）")
        print(json.dumps(result, ensure_ascii=False), flush=True)
    if failures:
        log(f"失敗した問い: {failures} 件")
        sys.exit(1)


if __name__ == "__main__":
    main()
