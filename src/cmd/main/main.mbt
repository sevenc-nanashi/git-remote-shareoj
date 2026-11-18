///|
/// Entry point for the CLI or runnable program in this template.
/// Keep main focused; move logic into the library package.
/// Run with `moon run cmd/main` from the project root.
async fn main {
  try {
    let argv = @env.args()
    if argv.length() < 3 {
      println("git-remote-shareoj \{VERSION}")
      eprintln("Usage: git-remote-shareoj <remote> <url>")
      @env.exit(1)
    }
    let remote_name = argv[1]
    let url = argv[2]
    let remote = @lib.Remote::parse_url(url)

    let git_dir = match @env.get_env_var("GIT_DIR") {
      Some(dir) => dir
      None => {
        eprintln("GIT_DIR environment variable is not set.")
        @env.exit(1)
      }
    }
    let git_dir = @path.Path(git_dir).resolve()

    let git_transport = @lib.GitTransport::new(remote, remote_name, git_dir)
    git_transport.start()
  } catch {
    e => {
      eprintln("git-remote-shareoj: \{@debug.to_string(e)}")
      @env.exit(1)
    }
  }
}
