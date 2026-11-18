// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "sevenc-nanashi/git-remote-shareoj"

version = "0.2.0"

source = "src"

readme = "README.mbt.md"

repository = ""

license = "MIT"

keywords = [ ]

preferred_target = "native"

description = ""

import {
  "moonbitstack/moonurl@0.3.0",
  "moonbitstack/moonuuid@0.2.0",
  "moonbitstack/mooncrypt@0.5.0",
  "moonbitlang/async@0.22.9",
}
