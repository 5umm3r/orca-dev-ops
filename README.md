# orca-dev-ops

Orca を使った複数デバイス開発のマスターセッション手順を、Claude Code プラグイン
として配布するリポジトリ。Mac mini をハブとし、MacBook と Orca モバイルをクライアント、
実装を Claude / Codex の子ワークツリーに委ねる分業を前提とする。

## 構成

| パス | 役割 |
|---|---|
| `skills/orca-dev-ops/SKILL.md` | マスターセッションの手順本体 |
| `skills/orca-dev-ops/references/orca-operations-plan.md` | 設計の根拠。ルールが不明瞭なときのみ読む |
| `hooks/orca-role-context.sh` | SessionStart。master / child のどちらかをセッションへ通知 |
| `hooks/orca-role-guard.sh` | PreToolUse。master の直接編集と child のコミットを禁止 |
| `hooks/orca-child-control.sh` | PostToolUse。`orca worktree create` 後に制御手順を注入 |
| `hooks/orca-lib.sh` | ロール判定の共通関数 |
| `commands/orca-init.md` | `/orca-init` スラッシュコマンド |
| `scripts/orca-init.sh` | worktree rules 設置スクリプト |
| `templates/worktree-rules.md` | 設置される汎用ルールブロック |

フックは `${CLAUDE_PLUGIN_ROOT}` 経由で起動し、`orca-lib.sh` を自身の位置から解決する。
`~/.claude/settings.json` への記述は不要。ロール判定キャッシュは
`${XDG_CACHE_HOME:-~/.cache}/orca-dev-ops/repos` に置かれる。

## インストール

```
/plugin marketplace add <このリポジトリの URL>
/plugin install orca-dev-ops@orca-dev-ops
```

## リポジトリへの適用

対象リポジトリで `/orca-init` を実行すると、`.claude/CLAUDE.md` に子ワークツリー向けの
汎用ルールブロックを設置し、`AGENTS.md` をそこへリンクする。

- ファイルが無い場合: 新規作成
- マーカーブロックがある場合: ブロック内のみ置換（プラグイン更新時の再配布用）
- マーカーが無い既存ファイル: 差分を提示し、`--apply` の確認を求める

設置されるのは汎用ブロックのみ。並行編集禁止ファイル一覧や検証コマンドなど
リポジトリ固有のルールは、マーカーの外に人手で追記する。

## 前提

- `orca` CLI がパス上にあること
- `jq` が利用可能であること
