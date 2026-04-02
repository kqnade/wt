# wt — worktree manager spec

## 概要

dotfiles に置く Shell 関数。`source wt.sh` するだけで動く。  
ha のシンプルさ + gtr の AI 起動をいいとこ取りしたツール。

---

## ディレクトリ規則

```
{ghq_root}/{host}/{user}/{repo}@{branch}
```

例:

```
~/ghq/github.com/kqnade/vrcgo/          ← ベースリポジトリ（ghq 管理）
~/ghq/github.com/kqnade/vrcgo@feature-x/ ← worktree
~/ghq/github.com/kqnade/vrcgo@fix-123/   ← worktree
```

- `@` 区切りで worktree を識別
- ghq は一切ラップしない。`wt ls` で worktree だけ列挙する
- ブランチ名のスラッシュは `-` に置換する（`feat/x` → `repo@feat-x`）
  - スラッシュをそのまま使うと `repo@feat/` という親ディレクトリが残り `wt del` 後に空ディレクトリが残る
  - `feat/x` と `feat-x` が同時に存在するケースは現実的にほぼない

---

## コマンド一覧

### `wt new [branch] [--ai] [--no-ai]`

worktree を作成する。

```
wt new feature-x        # 作成のみ
wt new feature-x --ai   # 作成 + claude 起動
wt new                   # branch 名省略 → wip-$RANDOM
```

処理順:
1. ベースリポジトリのルートを取得（`git rev-parse --show-toplevel`）
2. `git check-ref-format --branch "$branch"` でブランチ名を検証（無効な場合はエラー終了）
3. `{ghq_root}/{host}/{user}/{repo}@{branch}` のパスを組み立てる
4. 同名 worktree / ブランチが既に存在する場合はエラーで終了（上書き・スキップはしない）
5. `git worktree add "$wt_path" -b "$branch"` を実行
6. hooks の `post-new` を実行
7. `--ai` または config で `wt.ai=true` の場合 `claude` を起動

### `wt cd`

fzf で worktree を選んで移動する。

```
wt cd           # fzf で選択
wt cd feature-x # 直接指定
```

- `wt ls --full-path` をソースに fzf を起動
- ベースリポジトリ（`@` なし）も候補に含める
- 直接指定の場合のマッチングロジック（3段階）:
  1. **完全一致** → 即座に移動
  2. **1件のみ前方一致** → 移動
  3. **複数件前方一致** → エラー終了（候補一覧を表示）

### `wt ls [--full-path]`

worktree 一覧を表示する。

```
wt ls              # 相対名を表示（feature-x, fix-123, ...）
wt ls --full-path  # フルパスを表示
```

**スコープ: 現在のリポジトリに限定する**

- `git worktree list --porcelain` で現在のリポジトリに紐づく worktree を取得（これが真実の源泉）
- `--full-path` なしの場合はパスの basename から `{repo}@` プレフィックスを除いてブランチ名として表示
- `ghq root` 配下の `*@*` グロブに依存しない。ghq 管理外のリポジトリでも動作する
- 複数 ghq root の問題も回避できる
- マーク: 現在地が worktree なら `*`、ベースリポジトリなら `[base]` を表示

### `wt del [-f]`

現在の worktree とブランチを削除する。

```
wt del     # 確認あり
wt del -f  # 強制削除
```

- ベースリポジトリから実行した場合はエラー
- hooks の `pre-del` を実行。非ゼロ終了でキャンセル
- `-f` は `git worktree remove --force` と `git branch -D` の**両方を強制**する
- `-f` なしの場合は `git worktree remove` → `git branch -d`（未マージはエラー）

### `wt home`

ベースリポジトリに戻る。

```
wt home
```

- ベースパスの取得: `git rev-parse --git-common-dir` は worktree 内で相対パス（`../.git` 等）を返すことがある
- `realpath` で絶対パスに解決してから `dirname` する（`_wt_base` ヘルパーを参照）

### `wt use`

現在の worktree の HEAD をベースリポジトリに checkout する。  
（dev server をベースで1つ走らせたまま worktree の変更を確認するユースケース）

```
wt use
```

- 現在の worktree のブランチ名を取得: `git branch --show-current`
- ベースパスを `_wt_base` で取得し `git -C "$(_wt_base)" checkout "$branch"` を実行
- ベースが dirty な場合はエラーにする

### `wt extract`

現在のブランチを worktree に切り出す。  
（ベースで作業中のブランチを worktree に移してベースを別の作業に使いたいとき）

```
wt extract
```

- 実行前に現在のベースが dirty でないか確認（dirty ならエラー終了）
- 現在のブランチ名を取得
- `wt new {branch}` を実行
- ベースをデフォルトブランチに戻す
  - デフォルトブランチの取得: `git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||'`
  - origin が未設定の場合は `wt.default-branch` 設定にフォールバック、それもなければエラー

### `wt clean [--dry-run]`

merged / gone な worktree をまとめて削除する。

```
wt clean           # 確認しながら削除
wt clean --dry-run # 削除対象の表示のみ（初回は必ずこちらで確認推奨）
```

- `git worktree list --porcelain` でステータスを取得
- 削除対象の優先順位:
  1. `prunable` フラグが立っているもの（git が不要と判断済み）
  2. `gh` が使える場合: `gh pr list --state merged --json headRefName` でマージ済みブランチ名を取得して照合
  3. `gh` がない場合、または PR を経由せず直接マージされたケース: `git branch --merged {default_branch}` で検出（ローカルブランチとしてマージ済みかを確認）
- 上記いずれも「漏れ」はありうる。**`--dry-run` で確認してから実行することを強く推奨**

### `wt copy <path>`

ベースリポジトリから現在の worktree にファイル／ディレクトリをコピーする。

```
wt copy .env
wt copy .claude/
```

### `wt link <path>`

ベースリポジトリから現在の worktree にシンボリックリンクを張る。

```
wt link .envrc
wt link .claude/
```

### `wt invoke <hook>`

hooks を手動実行する。

```
wt invoke post-new   # セットアップのやり直し（link/copy 忘れたとき）
wt invoke pre-del    # 削除前チェックの確認
```

- hooks が実行される環境（カレントディレクトリ、環境変数）は自動実行時と同じ
- `WT_BRANCH` は現在のブランチ名が自動でセットされる

---

## 内部ヘルパー関数

複数コマンドで共通して使う処理をまとめる。

```sh
# ベースリポジトリのパスを返す
_wt_base() {
  command -v realpath > /dev/null 2>&1 || { echo "error: realpath required" >&2; return 1; }
  dirname "$(realpath "$(git rev-parse --git-common-dir)")"
}

# 現在が worktree 内かどうか判定（ベースなら false）
_wt_in_worktree() {
  [[ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]]
}

# ブランチ名をディレクトリ名に変換（スラッシュ → ハイフン）
_wt_branch_to_dir() {
  echo "${1//\//-}"
}

# デフォルトブランチを返す（origin/HEAD → 設定値 の順）
_wt_default_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' \
    || git config wt.default-branch 2>/dev/null \
    || { echo "error: cannot detect default branch" >&2; return 1; }
}
```

---

## hooks

`.wt/hooks/` はベースリポジトリのルート直下に置く。worktree 内の `.wt/hooks/` は参照しない（ベース側だけが正）。

| hook | タイミング |
|---|---|
| `pre-new` | `wt new` の前。非ゼロ終了でキャンセル |
| `post-new` | `wt new` の後 |
| `pre-del` | `wt del` の前。非ゼロ終了でキャンセル |
| `pre-mv` | `wt mv` の前（将来） |

hooks には環境変数 `WT_BRANCH` でブランチ名が渡される。

例: `.wt/hooks/post-new`
```sh
#!/bin/sh
wt link .envrc
wt copy .env
wt link .claude/
direnv allow .
```

---

## 設定

フォーマットは git config 形式（INI）。`git config -f ~/.config/wt/config wt.ai` で読めるため git config との親和性が高い。

優先度: git config local（`.git/config`）> `~/.config/wt/config` > git config global

| キー | デフォルト | 説明 |
|---|---|---|
| `wt.ai` | `false` | `wt new` 時に自動で AI を起動するか |
| `wt.ai-cmd` | `claude` | 起動する AI コマンド |
| `wt.root` | `$(ghq root)` | worktree の親ディレクトリ |
| `wt.default-branch` | （自動検出）| デフォルトブランチ名。`git symbolic-ref refs/remotes/origin/HEAD` が失敗したときのフォールバック |
| `wt.confirm` | `true` | `false` にすると `wt del` 等の確認プロンプトをスキップ（CI 環境向け） |

`~/.config/wt/config` の例:
```ini
[wt]
  ai = false
  ai-cmd = claude
  default-branch = main
  confirm = true
```

---

## 実装方針

- **対象シェル**: zsh（bash 互換も意識するが zsh 優先）
- **ファイル構成**: 単一ファイル `wt.sh`。dotfiles の `source` だけで完結
- **依存**: `git`, `fzf`（`wt cd` のみ）, `gh`（`wt clean` のオプション機能）, `realpath`
- **インストール**: sheldon / zinit / 手動 source のどれでも動く

```toml
# sheldon の場合
[plugins.wt]
github = "kqnade/dotfiles"
use = ["zsh/wt.sh"]
```

---

## 実装フェーズ

### Phase 1（最小動作）
- `wt new`, `wt cd`, `wt ls`, `wt del`, `wt home`

### Phase 2（ha 相当）
- `wt use`, `wt extract`, `wt copy`, `wt link`, hooks

### Phase 3（gtr 相当）
- AI 起動（`--ai`）, `wt clean`, 設定ファイル

---

## やらないこと

- ghq のラップ・オーバーライド
- GUI
- 独自 DB / 状態管理（`git worktree list` が真実の源泉）
- Windows ネイティブ対応（WSL2 で十分）
