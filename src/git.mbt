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
  Conflict(Error)
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
