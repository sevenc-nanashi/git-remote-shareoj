///|
#derive(Debug)
suberror GitTransportError {
  UnknownCommand(String)
  EmptyCommand
  InvalidInvocation(String)
  VirtualRepoBroken(Error)
}

///|
#derive(Debug, @json.FromJson)
struct ShareOjJson {
  version : UInt32
  id : String
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
  git_dir : @path.Path
}

///|
pub fn GitTransport::new(
  remote : Remote,
  remote_name : String,
  git_dir : @path.Path,
) -> GitTransport {
  GitTransport::{ remote, remote_name, git_dir, }
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
  let internal_git_dir = self.prepare_internal_repo().join(".git")
  let refs = @process.run(
    "git",
    ["ls-remote", "--symref", internal_git_dir.0],
    stdout=@process.ProcessOutput::Collect,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
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
  let internal_git_dir = self.prepare_internal_repo().join(".git")

  let _ = @process.run(
    "git",
    ["fetch", "--no-write-fetch-head", "--no-tags", "--", internal_git_dir.0] +
    args.iter().flat_map(arg => [arg.sha1, arg.refname].iter()).collect(),
    // NOTE: ここだけは元のGIT_DIRでfetchする
    extra_env={ "GIT_DIR": self.git_dir.0 },
    cwd=self.git_dir.0,
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )

  write_line("")
}

///|
async fn GitTransport::prepare_internal_repo(self : Self) -> @path.Path {
  let internal_repo_path = self.git_dir
    .join("shareoj-virtual-remote")
    .join(self.remote_name)
  if @fs.exists(internal_repo_path.0) {
    return internal_repo_path
  }

  let temporary_dir = @path.Path(internal_repo_path.0 + ".tmp")
  @fs.remove(temporary_dir.0, recursive=true, allow_missing=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }

  eprintln("Preparing internal repository at: \{temporary_dir}")
  errdefer (@fs.remove(temporary_dir.0, recursive=true, allow_missing=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  })

  @fs.mkdir(temporary_dir.dirname().0, recursive=true) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }

  let _ = @process.run(
    "shareoj",
    [
      "pull",
      "--api",
      self.remote.api_host.encode(),
      self.remote.id.to_string(),
      temporary_dir.0,
    ],
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )

  // NOTE: bare repoにしてもいいけど、結局pushするときのshareoj pushでcheckoutが必要なので、
  // 普通のrepoにしておく
  let _ = @process.run(
    "git",
    ["init", temporary_dir.0],
    extra_env={ "GIT_DIR": temporary_dir.join(".git").0 },
    cwd=temporary_dir.0,
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )

  // initial commit
  let _ = @process.run(
    "git",
    ["add", "-A"],
    extra_env={ "GIT_DIR": temporary_dir.join(".git").0 },
    cwd=temporary_dir.0,
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )
  let shareoj_json_path = temporary_dir.join(".shareoj.json")
  let shareoj_json : ShareOjJson = @fs.read_text(shareoj_json_path.0)
    |> @json.parse
    |> @json.from_json

  let _ = @process.run(
    "git",
    ["commit", "-m", "feat: initial commit (version: \{shareoj_json.version})"],
    extra_env={ "GIT_DIR": temporary_dir.join(".git").0 },
    cwd=temporary_dir.0,
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )
  let _ = @process.run(
    "git",
    [
      "tag",
      "-a",
      "-m",
      "Auto-generated by git-remote-shareoj",
      "v\{shareoj_json.version}",
    ],
    extra_env={ "GIT_DIR": temporary_dir.join(".git").0 },
    cwd=temporary_dir.0,
    stdout=@process.ProcessOutput::Stderr,
    stderr=@process.ProcessOutput::Inherit,
    accepted_exit_code=e => e == 0,
  )

  eprintln("Renaming temporary directory to: \{internal_repo_path}")
  @fs.rename(temporary_dir.0, internal_repo_path.0) catch {
    e => raise GitTransportError::VirtualRepoBroken(e)
  }

  internal_repo_path
}
