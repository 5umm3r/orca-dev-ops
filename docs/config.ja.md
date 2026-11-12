[English](config.md) | 日本語

# リポジトリ設定（`.orca-dev-ops.json`）

リポジトリごとに、任意の設定ファイルで orca-dev-ops のワークフローを調整できる。
ファイルが無ければ、すべてのフックとスクリプトは設定導入前とまったく同じに動く。
実装はタスク用ワークツリーの子エージェントが行い（ワークフローモード `worktree`）、
コーディネーターは起動のたびに子のエージェント・モデル・エフォートを質問し、
タスク用ワークツリーは同時に 3 つまで、メインチェックアウトでのドキュメント以外の
直接編集は 2 ファイル・20 行まで、コーディネーターの待機は 590000 ms で終わる。

## 置き場所

ファイルはリポジトリのトップレベルに置く `.orca-dev-ops.json`。フックやスクリプトが
リンクされた（子の）ワークツリー内で動く場合も、常に**メインチェックアウト**から読む。
メインチェックアウトは `git worktree list` の先頭エントリとして git が示すもの。
子ワークツリー内のコピーは無視されるため、子が自分のコピーを書き換えて自分の制限を
緩めることはできない。さらにガードは、子が自分のコピーを Write・Edit することも
ブロックする。

ファイルは他のリポジトリファイルと同様にコミットする。メインチェックアウトでの変更は
次のフック呼び出しから反映され、再起動は要らない。ただしコーディネーターの
セッション開始時のコンテキストは開始時に一度だけ書かれるため、変更後は
`scripts/orca-config.sh show`（後述）で有効な値を確かめる。

## エディターでの補完（`$schema`）

プラグインには、このファイル用の JSON Schema
[`schemas/orca-dev-ops.schema.json`](../schemas/orca-dev-ops.schema.json)
（draft 2020-12）が含まれる。すべてのキーについて型・許される値・デフォルト値・
英語の説明を持ち、どの階層でも未知のキーを拒否し、後述の条件付きの規則
（`semi-auto`・`auto` には `agent`・`model`・`effort` が要る、`escalate` には
`semi-auto` か `auto` が要る、`top` には `escalate` が要る）も表現している。
スキーマとローダーは同じファイルを受け付けるように作られており、テストでは
有効・不正のサンプルファイル群を両方に通し、どのファイルでも判定が一致することを
確かめている。

トップレベルの `"$schema"` キーでエディターにスキーマを指定する。

```json
"$schema": "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json"
```

`$schema` を読むエディター（VS Code、JetBrains の IDE、JSON の言語サーバーを使う
その他のエディター）では、編集中にキーの補完、ホバーでの説明表示、不正な値の
指摘が使える。URL はプラグインの `main` ブランチ上のスキーマなので、常に最新の
リリースに追従する。バージョンを固定したい場合は、ローカルのコピーを `$schema` に
指定する。ローダーは空でない文字列であれば `$schema` の値を問わず受け付け、それ以外には
使わない。有効な設定には含めず、`scripts/orca-config.sh show` も表示しない。
JSON にはコメントが無く、ローダー（jq）もコメントを拒否するため、その役目は
スキーマの説明が担う。JSONC は使わない。

## `/orca-init` による作成

メインチェックアウトに `.orca-dev-ops.json` が無い場合、`/orca-init` は先頭に
`$schema`、続けてデフォルト値を持つすべてのキー（下の表の値）を書いてこのファイルを
作成し、`created: <パス>` と表示する。`--apply` は不要。リンクされたワークツリーから
実行した場合も、ファイルはメインチェックアウトに作成する。`launch.agent`・
`launch.model`・`launch.effort` にはデフォルト値が無いため書き込まない。

```json
{
  "$schema":  "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json",
  "workflow": { "mode": "worktree" },
  "launch":   { "mode": "ask" },
  "limits":   { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 }
}
```

書き込まれる値は作成時点のデフォルト値である。後のプラグインのバージョンでデフォルト値が
変わってもファイルは更新されず、書き込まれた値が引き続き適用される。プラグインの
デフォルト値に従わせるには、そのキー（またはファイル）を削除するか、値を編集する。
`--no-settings` を付けると作成しない（既存のファイルの検証は行う）。書き込みに失敗した
場合は標準エラー出力に報告し、終了コードは変えない。

## 既存のファイル: `/orca-init` は報告し、`--settings=` で変更する

既存のファイルは検証し、デフォルトでは変更しない。不正なファイルは報告する
（標準エラー出力に `INVALID SETTINGS: ...`）。有効なファイルについては、新しい
プラグインで追加された設定と、リセットで失われる値もあわせて報告する。

- `settings: missing key <キー> (default <値>)`: デフォルト値を持つキーのうち、
  ファイルに無いもの。リーフ単位で示す（例: `limits.smallChangeLines`）。書かなくても
  デフォルト値が適用されるが、追加すると現在の値で固定される。`$schema` もこの形で
  報告する（`settings: missing key $schema (default "<URL>")`）。動作は何も変わらず、
  上のエディターでの補完が使えるようになるだけである。独自の `$schema` を持つファイルは、
  不足として報告しない。
- `settings: missing key <キー> (suggested <値>)`: デフォルト値の無いキーのうち、
  追加してもファイルが有効なままになる推奨値があるもの。現在は 2 つある。
  `launch.escalate` は、ファイルの `launch.mode` が `"semi-auto"` または `"auto"` で、
  `launch.agent` が `"claude"` のときに
  `{"model": "claude-opus-5-5", "effort": "high"}` を提示する。`launch.top` は、
  同じ条件に加えてファイルにすでに `launch.escalate` があるときに
  `{"model": "claude-fable-5-2", "effort": "high"}` を提示する。そのため
  `escalate` の無いファイルでは、1 回目の `--settings=add` で `escalate` が追加され、
  `top` が提示されるのは次の実行からになる。費用の高い段階は、必ず別に選ぶことになる。
- `settings: available key <キー> (no default; set by hand, see docs/config.md)`:
  デフォルト値の無いキーのうち、ファイルに無く、適用できる推奨値も無いもの
  （`launch.agent`・`launch.model`・`launch.effort`、条件を満たさない場合の
  `launch.escalate` と `launch.top`）。自動では追加しない。
- `settings: reset would change <キー> (<現在の値> -> <新しい値または removed>)`:
  `--settings=reset` で変わる、または消えるファイル内の値すべて。

不足しているキーが 1 つ以上あると、次のどちらかを付けて再実行するよう案内する
（`/orca-init` はどちらにするかをユーザーに確認する。`--no-settings` とは併用できない）。

- `--settings=add`: すべての `missing key` を表示された値で追加し、既存の値は
  変えない（`updated: <パス> (added: ...)`、不足が無ければ `up to date: <パス>`）。
  追加した値は作成時の値と同じく固定され、後でデフォルト値が変わっても更新されない。
  書き換えたファイルは先頭が `$schema` で、`workflow`・`launch`・`limits` の順に並ぶ。
  ファイル独自の `$schema` はそのまま残す。不正なファイルは変更しない。置き換えられるのは
  リセットだけである。
- `--settings=reset`: ファイルを同じ場所の `.orca-dev-ops.json.bak` にコピーしてから、
  新規作成時とまったく同じ内容のデフォルト値を書き込む（`reset: <パス> (backup:
  <bak>)`）。プラグインの `$schema` の URL と、`workflow.mode` の `"worktree"` も含む。
  不正なファイルにも使える。`.bak` ファイルがすでにあると何も変更しない
  （`SETTINGS NOT RESET: ...`）。先にバックアップを移動しておく。

どちらも一時ファイルに書き、結果がフックと同じ検査に通った場合だけファイルを置き換える。
通らなければファイルは変更せず、理由を標準エラー出力に表示する（`SETTINGS NOT
UPDATED: ...` または `SETTINGS NOT RESET: ...`）。どちらも終了コードは変えない。
書き換えたファイルは上と同じ、セクションごとに 1 行のレイアウトになる。

## 全項目の例

```json
{
  "$schema":  "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json",
  "workflow": { "mode": "worktree" },
  "launch":   { "mode": "auto", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium",
                "escalate": { "model": "claude-opus-5-5", "effort": "high" },
                "top":      { "model": "claude-fable-5-2", "effort": "high" } },
  "limits":   { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 }
}
```

どのキーも省略でき、省略したキーはデフォルト値になる。`{}` はファイルが無いのと同じ。
この例のように `"mode": "auto"` の場合、タスクがエスカレーション基準に当てはまれば、
コーディネーターは質問せずにエスカレート先の段階で起動し、より厳しい最上位の基準に
当てはまれば最上位の段階で起動する。先にユーザーに `Model` の質問へ答えてもらうには
`"semi-auto"` にする。`"workflow": { "mode": "direct" }` にすると、代わりに
コーディネーター自身がメインチェックアウトで実装し、子は起動しない。`launch` と
`limits` はそのまま有効で、元に戻すと再び適用される。

## キー

### `$schema`

| キー | 型 | デフォルト | 動作 |
| --- | --- | --- | --- |
| `$schema` | 空でない文字列 | プラグインのスキーマの URL（`/orca-init` が書き込む） | エディター向けのみ（「エディターでの補完」を参照）。ローダーは値を使わない |

### `workflow`

| キー | 型 | デフォルト | 動作 |
| --- | --- | --- | --- |
| `workflow.mode` | `"worktree"` または `"direct"` | `"worktree"` | 実装をどこで行うか（後述） |

`worktree`（デフォルト）は、この文書のほかの部分と `orca-dev-ops` スキルが説明する
ワークフローである。子エージェントが Orca のタスク用ワークツリーで実装し、
コーディネーターは計画・レビュー・統合を担う。コーディネーター自身のメイン
チェックアウトでの直接編集は、後述の `limits` の範囲に収める。

`direct` は、子ワークツリーを使わず、コーディネーター自身に実装させたいリポジトリ向けで
ある。

- ロールガードは、コーディネーターが自分のメインチェックアウト内のどのファイルでも、
  どのツール（Write・Edit・NotebookEdit）でも、どの大きさでも編集することを許可する。
  小さな変更の上限と Write のブロックはそこでは適用しない。リンクされたワークツリーや、
  別のリポジトリのメインチェックアウトの編集は従来どおり。
- コーディネーターは、リポジトリの検証を通してから base ref に直接コミットし、
  プッシュする（スキルの規則。ガードはコミットを検査しない）。
- `orca worktree create` はブロックし、拒否メッセージで `workflow.mode` を示す。
  `git worktree add`・`remove` の直接実行は従来どおりブロックする。
- コーディネーターのセッションコンテキストは、子ワークツリーについての行の代わりに
  そのことを伝える。子のセッション、起動ゲート、子のルールは変わらない。

`launch` と `limits` は `direct` と一緒でも有効で、元に戻すときのために値を保つ。
モードを変えるのはユーザーだけで、`workflow.mode` を編集して切り替える。
コーディネーターが自分で編集することはない（ガードの拒否メッセージもそう伝える）。
`direct` に切り替える前に、既存のタスク用ワークツリーを統合して削除しておく。残った
ワークツリーは子のルールのままで、コーディネーターはそこを編集できない。切り替えても
セッション開始時のコンテキストは更新されないため、`scripts/orca-config.sh show` で
有効なモードを確かめる。

### `launch`

| キー | 型 | デフォルト | 動作 |
| --- | --- | --- | --- |
| `launch.mode` | `"ask"`、`"semi-auto"`、`"auto"` のいずれか | `"ask"` | 子のエージェント・モデル・エフォートの決め方（後述） |
| `launch.agent` | `"claude"` または `"codex"` | 未設定 | 子のエージェント |
| `launch.model` | 空白を含まない空でない文字列 | 未設定 | エージェント固有のモデル値。Claude は `--model`、Codex は `-m` / `--model` |
| `launch.effort` | 空白を含まない空でない文字列 | 未設定 | エージェント固有のエフォート値。Claude は `--effort`、Codex は `-c model_reasoning_effort=<値>` |
| `launch.escalate` | オブジェクト `{model, effort}` | 未設定 | 同じエージェントでの 2 つ目の起動段階。`launch.mode` が `"semi-auto"` または `"auto"` のときだけ有効。`model` と `effort` は空白を含まない空でない文字列（後述） |
| `launch.top` | オブジェクト `{model, effort}` | 未設定 | 同じエージェントでの 3 つ目の、最上位の起動段階。`launch.escalate` と一緒のときだけ有効（したがって `"semi-auto"` または `"auto"` のときだけ）。形式は `launch.escalate` と同じ（後述） |

`ask`（デフォルト）では起動ゲートは従来どおり。子を起動するたびに、コーディネーターは
ヘッダー `Agent`・`Model`・`Effort` の質問を 1 問ずつユーザーに出し、起動ゲートは
直前の成功した起動より後のトランスクリプトに回答が揃うまで起動をブロックする。
このモードでの `launch.agent`・`launch.model`・`launch.effort` は、それらの質問の
「(Recommended)」の選択肢にすぎず、ゲートの拒否メッセージがその値を示す。

`semi-auto` と `auto` では質問が無くなる（`semi-auto` は `launch.escalate` と
`launch.top` のための `Model` の質問だけを残し、`auto` は何も質問しない）。ユーザーはエージェント・モデル・エフォートを
このファイルで一度だけ決め、`launch.agent`・`launch.model`・`launch.effort` は必須に
なる（3 つが揃わない `semi-auto` や `auto` はファイル全体が不正になる）。通常の段階では
起動ゲートはトランスクリプトを読まず、コマンド内のすべての起動を解析し、3 つの値が
すべて設定と一致する場合だけ許可する。

- `orca terminal create --command "<値>"`: `<値>` 内の各 `claude` または `codex`
  コマンド。Claude は `--model <m>` と `--effort <e>`。Codex は `-m <m>` または
  `--model <m>` と、`-c model_reasoning_effort=<e>` または
  `--config model_reasoning_effort=<e>`。`--flag=value` の書き方も使え、同じフラグが
  複数あれば最後のものが有効になる。
- `orca orchestration worker-start --agent <a> --model <m> --effort <e>`
  （`--terminal` なし）。

値が異なる場合や、コマンドが値を指定していない場合は、期待する値を示すメッセージで
拒否する。値は書かれたとおりに比較し、スキルのグレードからエフォートへの対応表は
`semi-auto` と `auto` では使わない。`launch.escalate` が無ければ `semi-auto` と `auto`
の動作は同じで、違いはエスカレート先と最上位の段階を誰が選ぶかだけである（後述）。

#### `launch.escalate`

`launch.escalate` は任意の `{model, effort}` で、`semi-auto` と `auto` に 2 つ目の
段階を加える。エージェントは共通で、`launch.agent` を使う。`escalate` に `agent` キーは
無い。それ以外の `launch.mode` で `escalate` を書くと、ファイル全体が不正になる。

- 通常の起動は `launch.model` と `launch.effort` を使い、質問は出さない。
- エスカレート先の段階は、エスカレーション基準のどれかに当てはまるタスク向けである。
  基準は、(a) 設計上の判断が残っている、または仕様があいまい。(b) 変更が複数の
  モジュールにまたがる、またはフックや起動ゲートのような安全機構の意味を変える。
  (c) 長く複数段階にわたる検証ループが見込まれる。(d) 同じ子が通常のモデルで 2 回の
  手戻り Dispatch を必要とした。基準に当てはまらないタスクは通常の値で起動する。
- `semi-auto`: 決めるのはユーザーである。`launch.agent` を `escalate` のモデルと
  エフォートそのままで起動する場合は、直前の成功した起動より後のトランスクリプトに、
  ヘッダー `Model` の回答済みの質問があるときだけ許可する（トランスクリプトの判定は
  `ask` と同じで、対象は `Model` のみ。`Agent` と `Effort` の質問は要らない）。回答が
  無ければ拒否する。起動が失敗しても回答を探す区間はリセットされないため、再試行に
  新しい質問は要らない。コーディネーターがこの `Model` の質問を出すのは、タスクが
  基準に当てはまる場合だけ。選択肢は、エスカレート先のモデルを先頭に
  「(Recommended)」付きで、次に通常のモデルを置く。コーディネーターが自分でモデルを
  上げることはない。
- `auto`: 決めるのはコーディネーターで、質問は出さない。同じ基準を自分で当てはめ、
  どれかに当てはまればエスカレート先の段階で起動する。ゲートは、`launch.agent` を
  `escalate` のモデルとエフォートそのままで起動する場合、トランスクリプトを読まずに
  許可する。コーディネーターは、選んだ段階と基準をワークツリーのコメントと起動の
  報告に記録する。
- 制限: `semi-auto` でゲートが確かめるのは `Model` の質問に回答があったことで、
  どの選択肢が選ばれたかではない。通常のモデルを選んだ回答と、エスカレート先を
  選んだ回答を区別できない。`auto` ではゲートがどちらの段階も許可するため、基準に
  当てはまるかどうかはコーディネーターの判断に委ねられる。

移行: v1.11.0 から、`"mode": "auto"` と `escalate` を持つファイルでは、コーディネーターが
基準に当てはまると判断したときに、質問せずエスカレート先の段階で起動する。従来の動作
（エスカレート先で起動する前に毎回 `Model` の質問をする）を続けるには
`"mode": "semi-auto"` にする。

#### `launch.top`

`launch.top` は任意の `{model, effort}` で、`launch.escalate` の上に 3 つ目の、最上位の
段階を加える。例は `{"model": "claude-fable-5-2", "effort": "high"}`（Fable 5.2 の
料金は Opus 5.5 の 2 倍）。形式と規則は `escalate` と同じで（`model` と `effort` だけを
持ち、エージェントは `launch.agent`）、`launch.escalate` もあるときだけ有効である。
`escalate` は `launch.mode` が `"semi-auto"` または `"auto"` のときだけ有効なので、
`top` も同じ条件になる。

- 最上位の段階を選ぶ基準は、エスカレーション基準より厳しい。上の (a)〜(d) にだけ
  当てはまるタスクはエスカレート先の段階のままで、最上位の段階には次のどれかが要る。
  (e) 同じ子がエスカレート先の段階で 2 回の手戻り Dispatch を必要とした。(f) 安全機構
  （フック、起動ゲート、ガード）の意味を変える変更で、その設計上の判断が残っている。
  つまり (a) と (b) の安全機構の部分の両方に当てはまる。(g) 結果をテストで確かめにくく、
  誤りの代償が大きい。並行処理、権限の境界、データ移行など。
- ゲートはエスカレート先の段階とまったく同じに扱う。`launch.agent` を `top` のモデルと
  エフォートそのままで起動する場合、`auto` ではトランスクリプトを読まずに許可し、
  `semi-auto` では直前の成功した起動より後に `Model` の質問への回答があるときだけ
  許可する。この `Model` の質問はエスカレート先と共通である。(e)〜(g) に当てはまる
  ときの選択肢は、最上位のモデルを先頭に「(Recommended)」付きで、次にエスカレート先の
  モデル、最後に通常のモデルを置く。(a)〜(d) にだけ当てはまるときの選択肢は上と同じ。
- `auto` では、コーディネーターはワークツリーのコメントに `tier:top reason:(<記号>)`
  を記録する（ほかに `tier:escalate ...` と `tier:default`）。
- ゲートの拒否メッセージは、2 つ目の段階の後に 3 つ目の段階とそのフラグを示す。
- 上の制限はここにも当てはまる。`semi-auto` で、ユーザーが 3 つのモデルのどれを
  選んだかはゲートには分からない。

v1.14.0 から `top` を受け付ける。`top` の無いファイルの動作は従来とまったく同じで、
3 つ目の段階は存在せず、その値での起動は拒否する。

### `limits`

| キー | 型 | デフォルト | 動作 |
| --- | --- | --- | --- |
| `limits.maxWorktrees` | 1 以上の整数 | `3` | コーディネーターが `orca worktree create` を実行する時点で、リポジトリが持てるタスク用ワークツリー（リンクされたワークツリー。メインチェックアウトは除く）の最大数 |
| `limits.smallChangeFiles` | 0 以上の整数 | `2` | メインチェックアウトでの直接編集: 未コミットの変更を持つドキュメント以外のファイルの最大数 |
| `limits.smallChangeLines` | 0 以上の整数 | `20` | メインチェックアウトでの直接編集: それらのファイルの変更行数の上限 |

ロールガードは `orca worktree list --repo path:<メインチェックアウト> --json` で
ワークツリーを数え、数が上限に達していれば `orca worktree create` をブロックする。
Orca が応答しない場合や、途中で打ち切られた一覧を返した場合もブロックする
（fail closed）。

小さな変更の上限は、メインチェックアウトでのコーディネーターの Edit に
適用され、既存の未コミットの変更と未追跡ファイルも数に含める。ドキュメント
（`*.md`、`docs/`、`references/`、`.claude/`）は数えず、それ以外のファイルへの
Write は引き続きブロックする。`0` にするとドキュメント以外の直接編集をすべて
ブロックする。`workflow.mode` が `"direct"` の場合、コーディネーター自身の
メインチェックアウトにはこれらの上限をどれも適用せず、`orca worktree create` は
数える前にブロックする。

### `monitor`（非推奨。1.12.0 から無視される）

1.12.0 より前のバージョンでは、`monitor.wakeOnStatus` と `monitor.timeoutMs` で
コーディネーターのフォアグラウンド待機（`scripts/orca-wait.sh`）を設定していた。
1.12.0 でこのスクリプトは削除された。Orca 1.4.246 では、ワーカーが報告すると Orca が
コーディネーター自身のターミナルへ `check` コマンドを入力して起こす
（`skills/orca-dev-ops/SKILL.md` の「Communication and state」を参照）ため、
設定する項目は残っていない。

既存のファイルが有効なままになるよう、このセクションは引き続き受け付け、値も従来どおり
検証する（`wakeOnStatus` は true か false、`timeoutMs` は 0 より大きい整数）。
有効な設定には含めず、`/orca-init` はもう書き込まない。`--settings=add` はそのまま残し、
`--settings=reset` は削除する。このセクションを持つ有効なファイルには、設定の警告
`monitor is ignored since 1.12.0; remove it from <path>.` を、コーディネーターの
セッション開始時のコンテキスト、起動ゲートとロールガードのすべての拒否メッセージ、
`scripts/orca-config.sh show`（stderr に `orca-config: warning: ...`、終了コード 0）、
`/orca-init`（`settings: warning: ...`）で出す。このセクションは削除する。
将来のメジャーバージョンでは未知のキーとして拒否する。

## 検証とフォールバック

ファイルは読むたびに全体を検証する。次の場合は不正とみなす。

- JSON として正しくない、空である、複数の JSON 値を含む、またはトップレベルが
  オブジェクトでない。
- 上に挙げていないキーがある（どの階層でも。非推奨の `monitor` セクションは上に挙げており、受け付ける）。
- 値の型が違う、または範囲外である。
- `$schema` が空でない文字列でない（`$schema must be a non-empty string`）。
- `workflow` がオブジェクトでない、または `workflow.mode` が `"worktree"` でも
  `"direct"` でもない。
- `launch.mode` が `"semi-auto"` または `"auto"` なのに `launch.agent`・`launch.model`・
  `launch.effort` が揃っていない。
- `launch.escalate` が `model` と `effort` だけを持つオブジェクトでない、どちらかの値が
  空白を含まない空でない文字列でない、または `launch.mode` が `"semi-auto"` でも
  `"auto"` でもない。
- `launch.top` が `model` と `effort` だけを持つオブジェクトでない、どちらかの値が
  空白を含まない空でない文字列でない、または `launch.escalate` が無い
  （`launch.top is only valid together with escalate`）。

不正なファイルは全体を無視し、そこからは何も採用しない。最も厳しい動作である、
上限付きのワークフローモード `worktree` と launch mode `ask` を含め、組み込みの
デフォルト値を使う。問題は次の場所で報告する。

- 開始時のコーディネーターのセッションコンテキスト。
- 起動ゲートとロールガードのすべての拒否メッセージ。
- `scripts/orca-config.sh show`（終了コード 3）と `/orca-init`。

## 1.15.0 への移行（`workflow`、`$schema`）

1.15.0 で `workflow` セクションと `$schema` キーが加わった。どちらも無いファイルの動作は
従来とまったく同じ（ワークフローモード `worktree`）。`/orca-init` はこれらを不足している
キーとして報告し、`--settings=add` で追加できる。

- プラグインを更新したら、プラグインを使うすべてのリポジトリで `/orca-init` を
  実行し直す。設定の報告に加えて、Codex の起動ゲートが使うローダーのコピー
  `.codex/hooks/orca-lib.sh` も更新される。古いコピーは `workflow` や `$schema` を
  持つファイルを不正とみなすため、Codex のコーディネーターは launch mode `ask` に
  戻ってしまう。
- 別のデバイスにある古いプラグインも同じで、`workflow` と `$schema` を未知のキーとして
  扱い、ファイル全体を無視して組み込みのデフォルト値（デフォルトの上限付きの
  ワークツリーモードと launch mode `ask`）を使い、設定の警告を出す。どちらかのキーを
  追加する前、または `--settings=add` を実行する前に、そのリポジトリで作業する
  すべてのデバイスのプラグインを更新しておく。

## 設定できないもの

一部のルールは好みではなくワークフローの不変条件であり、ローダーはそれらのキーを
すべて拒否する。

- Codex のサンドボックス・承認ポリシー・追加の書き込み可能ディレクトリ・ネットワークの
  各フラグと、Claude の `--dangerously-skip-permissions`: 子をワークツリー内に留め、
  確認なしで動かすためのもの。任意にすると、1 つの設定だけで子が触れられる範囲を
  広げられてしまう。
- 信頼の確認プロンプト: リポジトリを信頼するかはユーザーが一度だけ下す全体的な判断で、
  コーディネーターが下すものではない。
- base ref の判定: 統合先は常に `scripts/orca-base-ref.sh` から得る。推測した、
  あるいは設定したブランチ名は使わない。
- fast-forward のみの統合と `--force` のルール: 履歴の消失や書き換えを防ぐためのもの。

## 設定の確認

```sh
sh scripts/orca-config.sh show [<path>]
```

プラグインから実行する（Claude では `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-config.sh" show`）。
有効な設定（ファイルをデフォルト値に重ねたもの。`workflow.mode` を含み、`$schema` と
`monitor` は含まない）を JSON として標準出力に出し、
標準エラー出力に読み込み元のファイルと、不正な場合はその理由を、有効なファイルでは設定の警告（`monitor` の非推奨通知）を出す。終了コードは、
0 が正常またはファイルなし、3 が不正（デフォルト値を出力）、64 が使い方の誤り、
65 が git リポジトリでない場合。コーディネーターはセッションごとに一度、最初の起動の
前に実行する。
