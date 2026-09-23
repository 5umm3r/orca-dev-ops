---
description: このリポジトリに汎用「Orca worktree rules」ブロックを設置する
allowed-tools: Bash(sh:*), Read
---

`${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh` を実行し、現在のリポジトリの
`.claude/CLAUDE.md` に子ワークツリー向けの汎用ルールブロックを設置する。

手順:

1. 引数なしで実行する。

   ```sh
   sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh"
   ```

2. 終了コードで分岐する。

   - `0` — `.claude/CLAUDE.md` の作成・更新・変更なしのいずれか。出力をそのまま
     ユーザーへ報告して終了する。ただし出力に `AGENTS.md` についての注意（下記
     手順3）が含まれていないか必ず確認する。
   - `2` — `.claude/CLAUDE.md` が存在し、マーカーブロックが無い。既存ファイルを
     読み、手書きの worktree ルールが既にあるかを確認する。重複や矛盾があれば
     その箇所を指摘し、追記してよいかユーザーに確認する。承認後に
     `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh" --apply` を実行する。
   - `64` – 未知のオプション。`66` – テンプレート欠落。`65` – git リポジトリ外。
     原因を報告して終了する。
   - `67` — `.claude/CLAUDE.md` のマーカーブロックが壊れている（開始マーカーの
     みで終了マーカーが無い、終了マーカーのみ、または複数ブロック）。ファイルは
     変更されていない。エラー出力の内容をユーザーへ報告し、該当箇所を手動で
     修正してから再実行するよう伝える。

3. 出力に含まれる `AGENTS.md` についての報告を確認する。
   - `linked: AGENTS.md -> .claude/CLAUDE.md` — 新規にリンクした。対応不要。
   - `updated` / `up to date` — 通常ファイルのマーカーブロックを
     `.claude/CLAUDE.md` と同様に更新済み。対応不要。
   - `note: AGENTS.md is a symlink to ...`（`.claude/CLAUDE.md` 以外へのリンク）
     — 変更していない。リンク先に既にマーカーブロックがあるかを出力から確認し、
     無ければ Codex の子エージェントがルールを読めない旨をユーザーへ伝える。
   - `note: AGENTS.md exists as a regular file without an orca-worktree-rules
     marker` — 変更していない。Codex の子エージェントが同じルールを読めるよう、
     `AGENTS.md` にもブロックを追記してよいかユーザーに確認し、承認後
     `--apply` を付けて再実行する。
   - `note: AGENTS.md has an unterminated ...` — `AGENTS.md` のマーカーブロック
     が壊れている。手順2の `67` と同様、該当箇所を手動で修正するよう伝える
     （スクリプト全体の終了コードには影響しない）。
   - 末尾の `in sync` / `out of sync` の行で、Claude と Codex が同じブロックに
     達しているかを確認し、`out of sync` ならその理由をユーザーへ伝える。

設置されるのは汎用ブロックのみ。並行編集禁止ファイル一覧や検証コマンドなど
リポジトリ固有のルールは、マーカーブロックの外に人手で追記する。
