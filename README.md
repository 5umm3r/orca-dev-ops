# orca-dev-ops

Orca(Orca CLI) を使った複数デバイス開発のマスターセッション手順を、Claude Code プラグイン  
として配布するリポジトリ。計画を親ワークツリー、実装を Claude / Codex の任意の子ワークツリーに委ねる分業を前提とする。

## 構成


| パス                                                       | 役割                                           |
| -------------------------------------------------------- | -------------------------------------------- |
| `skills/orca-dev-ops/SKILL.md`                           | マスターセッションの手順本体                               |
| `skills/orca-dev-ops/references/orca-operations-plan.md` | 設計の根拠。ルールが不明瞭なときのみ読む                         |
| `hooks/orca-role-context.sh`                             | SessionStart。master / child のどちらかをセッションへ通知   |
| `hooks/orca-role-guard.sh`                               | PreToolUse。master の直接編集と child のコミットを禁止      |
| `hooks/orca-child-control.sh`                            | PostToolUse。`orca worktree create` 後に制御手順を注入 |
| `hooks/orca-lib.sh`                                      | ロール判定の共通関数                                   |
| `commands/orca-init.md`                                  | `/orca-init` スラッシュコマンド                       |
| `scripts/orca-init.sh`                                   | worktree rules 設置スクリプト                       |
| `templates/worktree-rules.md`                            | 設置される汎用ルールブロック                               |


フックは `${CLAUDE_PLUGIN_ROOT}` 経由で起動し、`orca-lib.sh` を自身の位置から解決する。
`~/.claude/settings.json` への記述は不要。

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

## v2.0.0 への移行

- プラグインを更新したら、ガード対象にしたい各リポジトリで `/orca-init` を
  実行し直す。スコープの判定は「`.claude/CLAUDE.md` または `AGENTS.md` に
  マーカーブロックがあるか」のみになった。マーカーが無いリポジトリはもう
  制限を受けない。逆にスコープ内でロールが判定できない場合、以前は無制限に
  動いていたが、今は書き込み系の操作をブロックする（fail closed）。
- 統合先（integration ref）は `scripts/orca-base-ref.sh` が返す値（Orca の
  base ref、無ければリモートの HEAD）を使う。判定できない場合は
  `orca repo set-base-ref` で設定する。
- 子は `orca orchestration worker-start --terminal` によるディスパッチワーカー
  として起動する。レビュー指摘の修正は新しい Dispatch として渡す。
- Codex の子エージェントには Claude の hooks が適用されない。サンドボックス
  フラグと `AGENTS.md` のルールが唯一のガードになる。
