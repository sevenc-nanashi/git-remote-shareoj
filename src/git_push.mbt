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
  @fs.mkdir(temporary_dir.0, allow_existing=false) catch {
    e => raise GitTransportError::Conflict(e)
  }
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
