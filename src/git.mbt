///|
/// 出力のprefix
/// ちゃんとしたロガーを導入しても良いかもしれない
const LOG_PREFIX = "git-remote-shareoj: "

///|
#derive(Debug)
suberror GitTransportError {
  UnknownCommand(String)
  EmptyCommand
  InvalidInvocation(String)
  VirtualRepoBroken(Error)
  ShareOJRejected(Error)
}

///|
#derive(Debug, @json.FromJson)
struct ShareOjJson {
  version : UInt32
  id : String
}

///|
async fn run_git(
  git_dir : @path.Path,
  args : Array[String],
  extra_env~ : Map[String, String] = {},
  cwd? : StringView,
  stdout~ : @process.ProcessOutput = Stderr,
) -> @process.ProcessResult {
  let env = extra_env.copy()
  env["GIT_DIR"] = git_dir.0
  @process.run("git", args, extra_env=env, cwd?, stdout~, stderr=Inherit, accepted_exit_code=e => {
    e == 0
  })
}

///|
async fn[T : Show] write_line(line : T) -> Unit {
  @stdio.stdout.write(@utf8.encode(line.to_string()))
  @stdio.stdout.write(b"\n")
}

///|
#derive(Debug)
pub struct GitTransport {
  remote : Remote
  remote_name : String
  branch_name : String
  git_dir : @path.Path
}

///|
pub async fn GitTransport::new(
  remote : Remote,
  remote_name : String,
  git_dir : @path.Path,
) -> GitTransport {
  let branch_name = run_git(
      git_dir,
      [
        "config",
        "--null",
        "--default",
        "main",
        "--get",
        "remote.\{remote_name}.shareojBranch",
      ],
      stdout=Collect,
    )
    .stdout_text()
    .strip_suffix("\u0000")
    .unwrap()
    .to_owned()
  let _ = run_git(
    git_dir,
    ["check-ref-format", "--branch", branch_name],
    stdout=Collect,
  )
  let _ = run_git(git_dir, ["check-ref-format", "refs/heads/\{branch_name}"])
  GitTransport::{ remote, remote_name, git_dir, branch_name, }
}

///|
pub async fn GitTransport::start(self : Self) -> Unit {
  while true {
    let commandline = (@stdio.stdin.read_until(b"\n").unwrap_or_default()
    |> @utf8.decode).split(" ")
    let command = commandline.next().unwrap_or_error(EmptyCommand)
    let args = commandline.map(StringView::to_owned).collect()

    match command {
      "capabilities" => self.capabilities()
      "list" => self.list_refs()
      "fetch" => {
        let batch = [FetchArgs::{ sha1: args[0], refname: args[1], }]
        while true {
          let line = (@stdio.stdin.read_until(b"\n").unwrap_or_default()
          |> @utf8.decode).trim()
          if line.is_empty() {
            break
          }
          let commandline = line.split(" ").collect()
          if commandline[0] != "fetch" {
            raise GitTransportError::InvalidInvocation(line.to_owned())
          }
          let fetch_args = FetchArgs::{
            sha1: commandline[1].to_owned(),
            refname: commandline[2].to_owned(),
          }
          batch.push(fetch_args)
        }
        self.fetch(batch)
      }
      "push" => {
        let commandlines = [args]
        while true {
          let line = (@stdio.stdin.read_until(b"\n").unwrap_or_default()
          |> @utf8.decode).trim()
          if line.is_empty() {
            break
          }
          let commandline = line.split(" ").collect()
          if commandline[0] != "push" {
            raise GitTransportError::InvalidInvocation(line.to_owned())
          }
          commandlines.push(
            commandline.iter().drop(1).map(StringView::to_owned).collect(),
          )
        }
        let batch = commandlines.map(commandline => {
          let (source, dst_refname) = commandline[0]
            .split_once(":")
            .unwrap_or_error(
              GitTransportError::InvalidInvocation(commandline.join(" ")),
            )
          PushArgs::{
            source: source.to_owned(),
            refname: dst_refname.to_owned(),
          }
        })
        self.push(batch)
      }
      "" => break
      _ => raise GitTransportError::UnknownCommand(command.to_owned())
    }
  }
}

///|
async fn GitTransport::capabilities(_self : Self) -> Unit {
  write_line("fetch")
  write_line("push")
  write_line("")
}

///|
async fn GitTransport::list_refs(self : Self) -> Unit {
  let internal_git_dir = self.prepare_internal_repo().join("repo.git")
  let refs = run_git(
    self.git_dir,
    ["ls-remote", "--symref", internal_git_dir.0],
    stdout=@process.ProcessOutput::Collect,
  )
  let stdout = refs.stdout_text()
  for line in stdout.split("\n") {
    if line.is_empty() {
      continue
    }
    let (value, name) = line
      .split_once("\t")
      .unwrap_or_error(
        GitTransportError::VirtualRepoBroken(
          Failure("Invalid ls-remote output: \{line}"),
        ),
      )
    if value.strip_prefix("ref: ") is Some(stripped) {
      write_line("@\{stripped} \{name}")
    } else {
      write_line("\{value} \{name}")
    }
  }

  write_line("")
}

///|
#derive(Debug)
struct FetchArgs {
  sha1 : String
  refname : String
}

///|
async fn GitTransport::fetch(self : Self, args : Array[FetchArgs]) -> Unit {
  let internal_git_dir = self.prepare_internal_repo().join("repo.git")

  let _ = run_git(
    self.git_dir,
    ["fetch", "--no-write-fetch-head", "--no-tags", "--", internal_git_dir.0] +
    args.iter().flat_map(arg => [arg.sha1, arg.refname].iter()).collect(),
    cwd=self.git_dir.0,
  )

  write_line("")
}

///|
priv struct PushArgs {
  source : String
  refname : String
}

///|
async fn GitTransport::push(self : Self, args : Array[PushArgs]) -> Unit {
  for arg in args {
    if arg.refname != "refs/heads/\{self.branch_name}" {
      write_line("error \{arg.refname} only \{self.branch_name} can be pushed")
      continue
    }
    let (source, force) = match arg.source.strip_prefix("+") {
      Some(source) => (source.to_owned(), true)
      None => (arg.source, false)
    }
    if source.is_empty() {
      write_line("error \{arg.refname} \{self.branch_name} cannot be deleted")
      continue
    }
    try {
      self.push_branch(source, force~)
      write_line("ok \{arg.refname}")
    } catch {
      e => {
        eprintln(LOG_PREFIX + "\{@debug.to_string(e)}")
        write_line("error \{arg.refname} push failed; see stderr")
      }
    }
  }
  write_line("")
}

///|
async fn GitTransport::push_branch(
  self : Self,
  source : String,
  force~ : Bool,
) -> Unit {
  let internal_repo = self.prepare_internal_repo()
  let internal_git_dir = internal_repo.join("repo.git")
  let temporary_dir = @path.Path(internal_repo.0 + ".push")

  // 同じ内部リポジトリへのpushを並行実行しない。
  @fs.mkdir(temporary_dir.0, allow_existing=false)
  defer @fs.remove(temporary_dir.0, recursive=true)

  let candidate = temporary_dir.join("tree")
  @fs.mkdir(candidate.0)
  let resolved = run_git(
    self.git_dir,
    ["rev-parse", "--verify", "--end-of-options", "\{source}^{commit}"],
    cwd=self.git_dir.0,
    stdout=Collect,
  )
  let commit = resolved.stdout_text().trim().to_owned()
  let old = run_git(
      internal_git_dir,
      ["rev-parse", "refs/heads/\{self.branch_name}"],
      stdout=Collect,
    )
    .stdout_text()
    .trim()
    .to_owned()
  // 参照を更新せずにオブジェクトだけ取り込む。
  let _ = run_git(internal_git_dir, [
    "fetch",
    "--no-write-fetch-head",
    "--no-tags",
    "--",
    self.git_dir.0,
    commit,
  ])
  if !force {
    let _ = run_git(internal_git_dir, [
      "merge-base", "--is-ancestor", old, commit,
    ])
  }
  let checkout_env = {
    "GIT_INDEX_FILE": temporary_dir.join("index").0,
    "GIT_WORK_TREE": candidate.0,
  }
  for
    command in [
      ["read-tree", commit],
      ["checkout-index", "--all", "--prefix=\{candidate.0}/"],
    ] {
    let _ = run_git(
      internal_git_dir,
      command,
      extra_env=checkout_env,
      cwd=internal_repo.0,
    )
  }
  let metadata = candidate.join(".shareoj.json")

  // pushする
  @fs.remove(metadata.0, allow_missing=true)
  @fs.write_text(
    metadata.0,
    @fs.read_text(internal_repo.join(".shareoj.json").0),
  )

  let push_result = @process.run(
    "shareoj",
    ["push", "--api", self.remote.api_host.encode(), "."],
    cwd=candidate.0,
    stdout=Collect,
    stderr=DuplicateStdout,
  )
  @fs.write_text(
    internal_repo.join(".shareoj.json").0,
    @fs.read_text(metadata.0),
  )

  eprintln(LOG_PREFIX + "shareoj says:")
  let mut output = push_result.stdout_text()
  let lines = output.split("\n").collect()
  if lines.last() == Some("") {
    let _ = lines.pop()
  }
  for line in lines {
    eprintln(LOG_PREFIX + "| \{line}")
  }
  if push_result.exit_code != 0 {
    if output.contains("tests require paired input/output files") {
      eprintln(
        LOG_PREFIX +
        "hint: you might have to remove `*.out` from your global gitignore, or add `!*.out` to your repository's `.gitignore`",
      )
    }

    guard re"version conflict: local ([0-9]+), remote ([0-9]+)".execute(output)
      is Some(conflict_info) else {
      raise GitTransportError::ShareOJRejected(
        Failure("shareoj push failed with exit code \{push_result.exit_code}"),
      )
    }

    let old_version : UInt32 = conflict_info.group(1).unwrap()
      |> @string.from_str
    let new_version : UInt32 = conflict_info.group(2).unwrap()
      |> @string.from_str
    if !force {
      eprintln(
        LOG_PREFIX + "hint: use force push to override the remote version.",
      )
      raise GitTransportError::ShareOJRejected(
        Failure("version conflict: local \{old_version}, remote \{new_version}"),
      )
    }

    eprintln(LOG_PREFIX + "force push: overriding the remote version.")
    let force_push_result = @process.run(
      "shareoj",
      [
        "push",
        "--api",
        self.remote.api_host.encode(),
        "--expect-version",
        new_version.to_string(),
        ".",
      ],
      cwd=candidate.0,
      stdout=Collect,
      stderr=DuplicateStdout,
    )
    @fs.write_text(
      internal_repo.join(".shareoj.json").0,
      @fs.read_text(metadata.0),
    )

    eprintln(LOG_PREFIX + "shareoj says:")
    output = force_push_result.stdout_text()
    let lines = output.split("\n").collect()
    if lines.last() == Some("") {
      let _ = lines.pop()
    }
    for line in lines {
      eprintln(LOG_PREFIX + "| \{line}")
    }

    if force_push_result.exit_code != 0 {
      raise GitTransportError::ShareOJRejected(
        Failure(
          "shareoj push failed with exit code \{force_push_result.exit_code}",
        ),
      )
    }
  }

  let _ = run_git(internal_git_dir, [
    "update-ref",
    "refs/heads/\{self.branch_name}",
    commit,
    old,
  ])

  let new_shareoj_json : ShareOjJson = @json.parse(
      @fs.read_text(internal_repo.join(".shareoj.json").0),
    )
    |> @json.from_json
  let new_version = new_shareoj_json.version

  let _ = run_git(
    internal_git_dir,
    [
      "tag",
      "-a",
      "-m",
      "Auto-generated by git-remote-shareoj",
      "v\{new_version}",
    ],
    cwd=self.git_dir.0,
  )
  eprintln(LOG_PREFIX + "created tag v\{new_version} for the new version.")
}

///|
async fn GitTransport::prepare_internal_repo(self : Self) -> @path.Path {
  let api_hash = @sha2.hash(
      @utf8.encode(self.remote.api_host.encode()),
      kind=Sha256,
    )
    |> @hex.encode
  let internal_repo_path = self.git_dir
    .join("shareoj-virtual-remote")
    .join(api_hash)
    .join(self.remote.id.to_string())
  if @fs.exists(internal_repo_path.0) {
    let internal_git_dir = internal_repo_path.join("repo.git")
    let current_branch = run_git(
        internal_git_dir,
        ["symbolic-ref", "HEAD"],
        stdout=Collect,
      )
      .stdout_text()
      .trim()
      .strip_prefix("refs/heads/")
      .unwrap()
      .to_owned()
    if current_branch != self.branch_name {
      let _ = run_git(internal_git_dir, [
        "branch",
        "-m",
        "--",
        current_branch,
        self.branch_name,
      ])
    }
    return internal_repo_path
  }

  let temporary_dir = @path.Path(internal_repo_path.0 + ".tmp")
  @fs.remove(temporary_dir.0, recursive=true, allow_missing=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }

  eprintln(LOG_PREFIX + "preparing internal repository")
  errdefer (@fs.remove(temporary_dir.0, recursive=true, allow_missing=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  })

  @fs.mkdir(temporary_dir.0, recursive=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }

  let worktree = temporary_dir.join("tree")
  let internal_git_dir = temporary_dir.join("repo.git")
  let _ = @process.run(
    "shareoj",
    [
      "pull",
      "--api",
      self.remote.api_host.encode(),
      self.remote.id.to_string(),
      worktree.0,
    ],
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  ) catch {
    e => raise GitTransportError::ShareOJRejected(e)
  }

  let _ = run_git(
    internal_git_dir,
    ["init", "--bare", "--initial-branch", self.branch_name, internal_git_dir.0],
    cwd=worktree.0,
  )

  // initial commit
  let _ = run_git(
    internal_git_dir,
    ["add", "-A"],
    extra_env={ "GIT_WORK_TREE": worktree.0 },
    cwd=worktree.0,
  )
  let shareoj_json_path = worktree.join(".shareoj.json")
  let shareoj_json : ShareOjJson = @fs.read_text(shareoj_json_path.0)
    |> @json.parse
    |> @json.from_json

  let _ = run_git(
    internal_git_dir,
    ["commit", "-m", "feat: initial commit (version: \{shareoj_json.version})"],
    extra_env={ "GIT_WORK_TREE": worktree.0 },
    cwd=worktree.0,
  )
  let _ = run_git(
    internal_git_dir,
    [
      "tag",
      "-a",
      "-m",
      "Auto-generated by git-remote-shareoj",
      "v\{shareoj_json.version}",
    ],
    extra_env={ "GIT_WORK_TREE": worktree.0 },
    cwd=worktree.0,
  )

  @fs.rename(shareoj_json_path.0, temporary_dir.join(".shareoj.json").0)
  @fs.remove(worktree.0, recursive=true)

  @fs.rename(temporary_dir.0, internal_repo_path.0) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }
  eprintln(
    LOG_PREFIX + "internal repository prepared at: \{internal_repo_path}",
  )

  internal_repo_path
}
