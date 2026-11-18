# git-remote-shareoj

ShareOJの問題をGitのプロトコルで扱えるようにするためのremote helper。

## インストール

```bash
packslip install github.com/sevenc-nanashi/git-remote-shareoj --pin ps1_6zqt7bajcjad62rqyrestvo2rm
```

## 使い方

- リポジトリURLは`shareoj://<api_host>/<path>#<problem_uuid>`または`shareoj://<api_host>/<path>/<problem_uuid>`の形。
  - `<api_host>`はShareOJのAPIのホスト名。基本的には`api.share-oj.net`。
    - `https://`固定。
  - `<path>`は自由に設定できる省略可能なパス。
  - `<problem_uuid>`は問題のUUID。`#`があればその後ろ、なければパスの末尾から取得する。
  - 例：
    - `shareoj://api.share-oj.net/f503617a-e823-4d4a-a553-cc5fcd27355d`
    - `shareoj://api.share-oj.net/sevenc-nanashi/holiday_or_holic_die#f503617a-e823-4d4a-a553-cc5fcd27355d`

- ブランチ名はデフォルトで`main`。`remote.<remote>.shareojBranch`で変更できる。
- pushは設定したブランチのみ。
  - それ以外のブランチは拒否される。
  - pushする際は、push対象のコミットの内容がそのまま問題として登録される。
  - Web側で更新されていた場合（versionの不一致）、pushは拒否される。
    - force-pushでWeb側の内容を上書きできる。
- タグ`v{revision}`で、過去の`push`の内容を参照できる。
- pullは基本的に意味がない。

## 仕組み

- `.git/shareoj-virtual-remote/<api_hostのURLのハッシュ>/<problem_uuid>`に、仮想的なリモートリポジトリを作る。
  - 基本的にgitの操作はそのリポジトリに対して行われる。
- 初期化時に`shareoj pull`し、仮想リポジトリを作る。
  - そこで設定したブランチとinitial commitを作り、`.shareoj.json`からバージョンを取得してタグを作る。
- `push`では、内部のリポジトリを更新する前に、一時ディレクトリにpushしようとしている内容を展開して`shareoj push .`する。
  - conflict以外の理由で失敗している場合はpushを拒否する。
  - conflictで失敗している場合はforce-pushでない限りpushを拒否する。
  - 成功した場合は内部のリポジトリを更新する。

### 制約

- ShareOJ CLIの都合上、過去のリビジョンの内容を取得することはできない。
  - このhelperはpush時にタグを作っているので、このhelperで行った操作だけは過去のリビジョンの内容を取得できる。
- 未完成のものをpushできない。

## ライセンス

MIT License。
