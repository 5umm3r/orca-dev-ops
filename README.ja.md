[English](README.md) | 日本語

# orca-dev-ops

Orca（Orca CLI）を使った複数デバイス開発のマスターセッション手順を、Claude Code
プラグインとして配布するリポジトリ。計画を親ワークツリーで行い、実装を Claude または
Codex の子ワークツリーに委ねる分業を前提とする。

## 構成

| パス | 役割 |
| --- | --- |
| `skills/orca-dev-ops/SKILL.md` | マスターセッションの手順本体 |
| `hooks/orca-role-context.sh` | SessionStart。master / child のどちらかをセッションへ通知する |
| `hooks/orca-role-guard.sh` | PreToolUse。master の直接編集と child のコミットを禁止する |
| `hooks/orca-child-control.sh` | PostToolUse。`orca worktree create` 後に制御手順を注入する |
| `hooks/orca-lib.sh` | ロール判定の共通関数 |
| `commands/orca-init.md` | `/orca-init` スラッシュコマンド |
| `scripts/orca-init.sh` | worktree rules を設置するスクリプト |
| `scripts/orca-worker-start.sh` | エージェントのヘッダーが画面に出てから子ターミナルでディスパッチワーカーを起動し、起動直後の競合では一度だけ再試行する |
| `templates/worktree-rules.md` | 設置される汎用ルールブロック |

フックは `${CLAUDE_PLUGIN_ROOT}` 経由で起動し、`orca-lib.sh` を自身の位置から解決する。
`~/.claude/settings.json` への記述は不要。

## インストール

```
/plugin marketplace add https://github.com/5umm3r/orca-dev-ops
/plugin install orca-dev-ops@orca-dev-ops
```

## リポジトリへの適用

対象リポジトリで `/orca-init` を実行すると、`.claude/CLAUDE.md` に子ワークツリー向けの
汎用ルールブロックを設置し、`AGENTS.md` をそこへリンクする。

- ファイルが無い場合: 新規作成する。
- マーカーブロックがある場合: ブロック内のみ置換する（プラグイン更新時の再配布用）。
- マーカーが無い既存ファイルの場合: 差分を提示し、`--apply` の確認を求める。

設置されるのは汎用ブロックのみ。並行編集禁止ファイルの一覧や検証コマンドなど、
リポジトリ固有のルールはマーカーの外に人手で追記する。

## 前提

- `orca` CLI が `PATH` 上にあること。
- `jq` が利用可能であること。

Orca とは: ワークツリーとエージェントのターミナルを管理するマルチエージェントアプリで、
本プラグインはその `orca` CLI を操作する。スキルは Orca 1.4.206 で動作確認している
（`skills/orca-dev-ops/SKILL.md` の「Known constraints」を参照）。

## アップグレード

プラグインの更新で worktree rules のテンプレートが変わったら、それを使っている
すべてのリポジトリで `/orca-init` を実行し直す。置換されるのはマーカーブロックのみで、
マーカーの外の内容は保持される。

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
- 最初の子を起動する前に、Claude と Codex それぞれで各リポジトリを一度は
  信頼済みにしておく。リポジトリは `/tmp` や `$TMPDIR` 配下に置かない
  （Codex のサンドボックスからも書き込み可能なため）。

## テストの実行

```sh
for t in tests/*.test.sh; do sh "$t"; done
```

## ライセンス

MIT。[LICENSE](LICENSE) を参照。
