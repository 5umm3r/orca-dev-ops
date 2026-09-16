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

   - `0` — 作成・更新・変更なしのいずれか。出力をそのままユーザーへ報告して終了。
   - `2` — `.claude/CLAUDE.md` が存在し、マーカーブロックが無い。既存ファイルを
     読み、手書きの worktree ルールが既にあるかを確認する。重複や矛盾があれば
     その箇所を指摘し、追記してよいかユーザーに確認する。承認後に
     `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh" --apply` を実行する。
   - `64`–`66` — 引数不正・git リポジトリ外・テンプレート欠落。原因を報告して終了。

3. スクリプトが `AGENTS.md` を通常ファイルとして検出した旨を出力した場合は、
   Codex の子エージェントが同じルールを読めるよう、そのファイルにも同じブロックが
   必要であることをユーザーへ伝える。

設置されるのは汎用ブロックのみ。並行編集禁止ファイル一覧や検証コマンドなど
リポジトリ固有のルールは、マーカーブロックの外に人手で追記する。
