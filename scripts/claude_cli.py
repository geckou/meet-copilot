"""scripts/ の外部プロセスから claude -p を呼ぶための共通部分。標準ライブラリだけで動く。"""

import glob
import json
import math
import os
import shutil
import subprocess


class ClaudeError(RuntimeError):
    """claude が見つからない、または claude -p の呼び出しが失敗した。"""


def positive(value):
    """argparse の type 用。正の有限の数だけ受け付ける。"""
    import argparse

    number = float(value)
    if not (math.isfinite(number) and number > 0):
        raise argparse.ArgumentTypeError("正の有限の数")
    return number


def add_claude_arguments(parser, *, model, timeout):
    """claude -p を呼ぶスクリプトに共通の引数を足す。"""
    parser.add_argument("--claude-bin", default=os.environ.get("MEET_COPILOT_CLAUDE"),
                        help="claude の実行ファイル。省略時は PATH とよくある置き場所から探す（環境変数 MEET_COPILOT_CLAUDE でも指定可）")
    parser.add_argument("--model", default=model)
    parser.add_argument("--timeout", type=positive, default=timeout, help="claude -p 1回の上限秒数")


def find_claude(explicit):
    """claude の実行ファイルを絶対パスで返す。nvm で入れた場合は PATH に無いことがあるので、よくある置き場所も見る。"""
    # claude は別のディレクトリを作業ディレクトリにして動かすので、相対パスはここで絶対パスにしておく
    if explicit:
        found = os.path.abspath(explicit) if os.sep in explicit else shutil.which(explicit)
        if not found or not os.access(found, os.X_OK):
            raise ClaudeError(f"claude として指定された実行ファイルがない: {explicit}")
        return found
    if found := shutil.which("claude"):
        return os.path.abspath(found)
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
    raise ClaudeError("claude が見つからない。--claude-bin か環境変数 MEET_COPILOT_CLAUDE で場所を指定する")


def format_time(seconds):
    minutes = int(seconds // 60)
    return f"{minutes:02d}:{seconds - minutes * 60:04.1f}"


def run_claude(claude_bin, prompt, *, model, schema, timeout, cwd, system_prompt=None, append_system_prompt=None,
               tools=(), add_dirs=()):
    """claude -p を1回呼び、--json-schema で固定した structured_output を返す。

    - tools：使わせるツール（例：("Read", "Grep", "Glob")）。空ならツールなし。指定したものは確認なしで許可する
    - MCP は読み込まない（起動が遅くなり、会議の内容を外のサービスに渡しうるため）
    - 失敗は ClaudeError、時間切れは subprocess.TimeoutExpired
    """
    command = [
        claude_bin, "-p",
        "--model", model,
        "--tools", ",".join(tools),
        "--strict-mcp-config",
        "--no-session-persistence",
        "--output-format", "json",
        "--json-schema", json.dumps(schema),
    ]
    if tools:
        command += ["--allowedTools", ",".join(tools)]
    for directory in add_dirs:
        command += ["--add-dir", directory]
    if system_prompt is not None:
        command += ["--system-prompt", system_prompt]
    if append_system_prompt is not None:
        command += ["--append-system-prompt", append_system_prompt]
    result = subprocess.run(
        command,
        input=prompt,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=cwd,
        # 端末の Ctrl-C は呼び出し元が受ける。実行中の claude まで止まらないよう別グループにする
        start_new_session=True,
        # nvm で入れた claude は同じ場所の node で動くので、その場所を PATH の先頭に足す
        env={**os.environ, "PATH": os.path.dirname(claude_bin) + os.pathsep + os.environ.get("PATH", "")},
    )
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ClaudeError(f"claude -p の出力を読めない（終了コード {result.returncode}）: {result.stderr.strip() or result.stdout.strip()}")
    if result.returncode != 0 or response.get("is_error"):
        raise ClaudeError(f"claude -p が失敗: {response.get('result')}")
    output = response.get("structured_output")
    if not isinstance(output, dict):
        raise ClaudeError(f"claude -p の結果が想定の形でない: {response.get('result')}")
    return output
