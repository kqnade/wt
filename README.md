# wt — git worktree manager

`source` するだけで動く git worktree 管理シェル関数。  
シンプルな操作性と AI 起動機能を兼ね備えた、dotfiles 向けワンファイルツール。

## インストール

```sh
# dotfiles に置いて source するだけ
source /path/to/wt.sh

# sheldon の場合
[plugins.wt]
github = "kqnade/wt"
use = ["wt.sh"]

# zinit の場合
zinit snippet "https://raw.githubusercontent.com/kqnade/wt/main/wt.sh"
```

## 依存

| ツール | 必須 | 用途 |
|--------|------|------|
| `git` | ✅ | すべての操作 |
| `realpath` | ✅ | ベースパス解決 |
| `fzf` | `wt cd` のみ | 対話選択 |
| `gh` | `wt clean` のみ | マージ済み PR の検出 |

## テスト

```sh
zsh tests/wt_test.zsh
```

## ディレクトリ規則

```
{ghq_root}/{host}/{user}/{repo}/          ← ベースリポジトリ
{ghq_root}/{host}/{user}/{repo}@feature-x/ ← worktree
{ghq_root}/{host}/{user}/{repo}@fix-123/   ← worktree
```

ブランチ名のスラッシュはハイフンに置換されます（`feat/x` → `repo@feat-x`）。

## コマンド

### `wt new [branch] [--prompt] [--cd] [--ai|--no-ai]`

新しい worktree を作成します。

```sh
wt new feature-x        # ブランチ指定して作成
wt new feature-x --ai   # 作成後に AI（claude）を起動
wt new                   # ブランチ名省略 → wip-$RANDOM
wt new --prompt --cd     # ブランチ名を入力して、作成先へ移動
```

`--prompt` の入力プロンプトは stderr に出力されます。空入力や EOF は作成せずエラーになります。
`--cd` は `wt.sh` を source した現在のシェルを、作成した worktree へ移動します。

### `wt path [branch]` / `wt home-path`

連携ツール向けに、装飾なしの絶対パスだけを stdout へ出力します。

```sh
wt path issue/123  # 指定ブランチの worktree
wt path            # 現在いる worktree
wt home-path       # canonical base checkout（base/worktree のどちらからでも同じ）
```

### `wt cd [branch]`

worktree へ移動します。

```sh
wt cd              # fzf で選択
wt cd feature-x    # 完全一致
wt cd feat         # 前方一致（1件のみなら移動、複数なら候補表示）
```

### `wt ls [--full-path]`

現在のリポジトリの worktree 一覧を表示します。

```sh
wt ls              # ブランチ名のみ（現在地に * / [base] マーク）
wt ls --full-path  # フルパスを表示
```

### `wt del [-f]`

現在の worktree とブランチを削除します（worktree 内から実行）。

```sh
wt del    # 確認プロンプトあり
wt del -f # git worktree remove --force + git branch -D（両方強制）
```

### `wt home`

ベースリポジトリに戻ります。

```sh
wt home
```

### `wt use`

現在の worktree のブランチをベースリポジトリに反映します。  
dev server をベースで動かしたまま worktree の変更内容を確認するユースケース向け。

```sh
wt use
```

> ベースは detached HEAD 状態になります（git の同ブランチ複数 checkout 制約のため）。

### `wt extract`

現在のブランチを worktree に切り出します。  
ベースで作業中のブランチを worktree に移し、ベースを別の作業に使いたいときに便利。

```sh
wt extract
```

### `wt copy <path> [...]`

ベースリポジトリから現在の worktree へファイル／ディレクトリをコピーします。

```sh
wt copy .env
wt copy .claude/
```

### `wt link <path> [...]`

ベースリポジトリから現在の worktree へシンボリックリンクを張ります。

```sh
wt link .envrc
wt link .claude/
```

### `wt invoke <hook>`

hooks を手動実行します（セットアップのやり直しなどに）。

```sh
wt invoke post-new
```

### `wt clean [--dry-run]`

マージ済み・不要な worktree をまとめて削除します。

```sh
wt clean --dry-run  # 削除対象の確認（初回は必ずこちらから）
wt clean            # 確認しながら削除
```

## hooks

ベースリポジトリの `.wt/hooks/` に実行可能ファイルを置くと自動実行されます。

| hook | タイミング |
|------|-----------|
| `pre-new` | `wt new` 実行前（非ゼロ終了でキャンセル） |
| `post-new` | `wt new` / `wt extract` 実行後 |
| `pre-del` | `wt del` 実行前（非ゼロ終了でキャンセル） |

`WT_BRANCH` 環境変数でブランチ名が渡されます。

```sh
# .wt/hooks/post-new の例
#!/bin/sh
wt link .envrc
wt copy .env
wt link .claude/
direnv allow .
```

## 設定

git config 形式（INI）。優先度: ローカル git config > `~/.config/wt/config` > グローバル git config

```ini
# ~/.config/wt/config
[wt]
  ai = false          # wt new 時に AI を自動起動するか
  ai-cmd = claude     # 起動する AI コマンド
  default-branch = main
  confirm = true      # false にすると確認プロンプトをスキップ
```

```sh
# リポジトリ単位で設定する場合
git config wt.ai true
git config wt.ai-cmd claude
```
