///|
async fn GitTransport::list_refs(self : Self) -> Unit {
  self.with_internal_repo(repo => {
    let refs = run_git(
      self.git_dir,
      ["ls-remote", "--symref", repo.git_dir.0],
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
  })
}

///|
#derive(Debug)
struct FetchArgs {
  sha1 : String
  refname : String
}

///|
async fn GitTransport::fetch(self : Self, args : Array[FetchArgs]) -> Unit {
  self.with_internal_repo(repo => {
    let internal_git_dir = repo.git_dir

    let _ = run_git(
      self.git_dir,
      ["fetch", "--no-write-fetch-head", "--no-tags", "--", internal_git_dir.0] +
      args.iter().flat_map(arg => [arg.sha1, arg.refname].iter()).collect(),
      cwd=self.git_dir.0,
    )

    write_line("")
  })
}
