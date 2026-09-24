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
| `hooks/orca-launch-gate.sh` | PreToolUse。このセッションでユーザーが Agent・Model・Effort の質問に回答するまで、子エージェントの起動をブロックする（Claude と Codex） |
| `hooks/orca-lib.sh` | ロール判定と設定読み込みの共通関数 |
| `commands/orca-init.md` | `/orca-init` スラッシュコマンド |
| `scripts/orca-init.sh` | worktree rules と Codex 用の起動ゲートを設置するスクリプト |
| `scripts/orca-worker-start.sh` | エージェントのヘッダーが画面に出てから子ターミナルでディスパッチワーカーを起動し、起動直後の競合では一度だけ再試行する |
| `scripts/orca-config.sh` | 有効なリポジトリ設定（`.orca-dev-ops.json`）を表示し、検証エラーを報告する |
| `scripts/orca-wait.sh` | コーディネーター用の待機。対応が必要なメッセージで起き、heartbeat と status だけのバッチは確認応答して status を保持する |
| `docs/config.ja.md` | リポジトリ設定ファイルのリファレンス |
| `templates/worktree-rules.md` | 設置される汎用ルールブロック |

フックは `${CLAUDE_PLUGIN_ROOT}` 経由で起動し、`orca-lib.sh` を自身の位置から解決する。
`~/.claude/settings.json` への記述は不要。
Codex のプラグインはフックを同梱できないため、Codex 向けの起動ゲートは `/orca-init` が
各リポジトリへ設置する（後述）。

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

あわせて Codex のコーディネーター向けに起動ゲートを設置する。`.codex/hooks/` に
`orca-launch-gate.sh` と `orca-lib.sh` のコピーを置き（実行のたびに更新）、
`.codex/hooks.json` に `PreToolUse` の `Bash` エントリを追加する。`hooks.json` が無ければ
新規作成し、エントリの無い既存ファイルは `--apply` を求めたうえで他のフックを残して
マージする。JSON が壊れている場合は報告のみで変更しない。Codex は次回起動時に、
新規または変更されたフックを信頼するかを一度だけユーザーに確認する。

設置されるのは汎用ブロックのみ。並行編集禁止ファイルの一覧や検証コマンドなど、
リポジトリ固有のルールはマーカーの外に人手で追記する。

## 設定

リポジトリのトップレベルに任意の `.orca-dev-ops.json` を置くと、起動モード（`ask`:
起動のたびに質問する。デフォルト。`auto`: 質問せず、決まったエージェント・モデル・
エフォートで起動する）、ワークツリー数と小さな変更の上限、コーディネーターの待機を
設定できる。ファイルはメインチェックアウトからのみ読み、不正な場合は警告を出して
無視する。ファイルが無ければ動作は変わらない。詳細は
[docs/config.ja.md](docs/config.ja.md) を参照。`scripts/orca-config.sh show` で
有効な設定を表示できる。

## 前提

- `orca` CLI が `PATH` 上にあること。
- `jq` が利用可能であること。

Orca とは: ワークツリーとエージェントのターミナルを管理するマルチエージェントアプリで、
本プラグインはその `orca` CLI を操作する。スキルは Orca 1.4.206 と 1.4.209 で動作確認している
（`skills/orca-dev-ops/SKILL.md` の「Known constraints」を参照）。

## アップグレード

プラグインの更新で worktree rules のテンプレートやフックが変わったら、それを使っている
すべてのリポジトリで `/orca-init` を実行し直す。置換されるのはマーカーブロックと Codex 用
フックのコピーのみで、マーカーの外の内容と他の Codex フックは保持される。

## 動作

- hooks が働くのは、`.claude/CLAUDE.md` または `AGENTS.md` にマーカーブロックが
  あるリポジトリだけ。マーカーが無いリポジトリは制限を受けない。スコープ内で
  ロールを判定できない場合は、書き込み系の操作をブロックする（fail closed）。
- 統合先（integration ref）は `scripts/orca-base-ref.sh` が返す値（Orca の
  base ref、無ければリモートの HEAD）を使う。判定できない場合は
  `orca repo set-base-ref` で設定する。
- 子は `orca orchestration worker-start --terminal` によるディスパッチワーカー
  として起動する。レビュー指摘の修正は新しい Dispatch として渡す。
- 起動モード `ask`（デフォルト。「設定」を参照）では、子を起動するたびに、コーディネーターは子のエージェント・モデル・エフォートについて
  1 問ずつ（ヘッダー `Agent`・`Model`・`Effort`）ユーザーに質問する。起動ゲートは
  セッションのトランスクリプトを読み、直前の成功した起動より後にその回答が揃うまで
  起動をブロックする。失敗した起動は質問し直さずに再試行できる。Claude に適用され、
  `/orca-init` を通じて Codex のコーディネーターにも適用される。
- 起動ゲートを除き、Codex のエージェントには Claude の hooks が適用されない。Codex の
  子エージェントでは、サンドボックスフラグと `AGENTS.md` のルールが唯一のガードになる。
- 最初の子を起動する前に、Claude と Codex それぞれで各リポジトリを一度は
  信頼済みにしておく。リポジトリは `/tmp` や `$TMPDIR` 配下に置かない
  （Codex のサンドボックスからも書き込み可能なため）。

## テストの実行

```sh
for t in tests/*.test.sh; do sh "$t"; done
```

## ライセンス

MIT。[LICENSE](LICENSE) を参照。
