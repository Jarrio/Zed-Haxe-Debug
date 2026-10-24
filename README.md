# Haxe debugger for Zed

Breakpoints, stepping, variables and the debug console for Haxe in Zed.

| Target | Debugger | Status |
|---|---|---|
| `--interp`, `--run`, and macros of any build | [eval-debugger](https://github.com/vshaxe/eval-debugger) | works |
| hxcpp (`--cpp`) | [hxcpp-debug-server](https://github.com/Jarrio/hxcpp-debugger) | works |
| cppia (`--cppia`), in a host built for debugging | hxcpp-debug-server | works with libhxcpp (see "cppia") |
| HashLink (`--hl`) | [hashlink-debugger](https://github.com/vshaxe/hashlink-debugger) | works |
| JavaScript (`--js`), run by Node | [js-debug](https://github.com/microsoft/vscode-js-debug), as in Zed's own JavaScript support | works, with breakpoints in the Haxe code |

Between Zed and the debuggers sits a **bridge written in Haxe** (`bridge/`), which:

- picks the hxml to debug and the debugger its output needs
- picks the Haxe to run, the same way [Zed-Haxe](https://github.com/Jarrio/Zed-Haxe) does: `.haxerc`
  through lix or haxe-manager, else `haxe` on your PATH
- for eval, runs vshaxe's eval-debugger, the one VS Code uses, unmodified, and works around the places
  where it and Zed don't agree (see "Known issues")
- for hxcpp, builds the program with hxcpp-debug-server, runs it, and talks to the debug server inside
  it, doing the job of the adapter in vshaxe's VS Code extension
- for HashLink, builds the program and runs vshaxe's hashlink-debugger, unmodified
- for JavaScript, builds with source maps and runs Microsoft's js-debug, which follows them back to
  the Haxe code

## Requirements

- Haxe 4.0 or newer
- A Haxe language extension: [Zed-Haxe](https://github.com/Jarrio/Zed-Haxe) or the `haxe` extension in
  Zed's registry
- For hxcpp: the hxcpp haxelib and a C++ compiler, as for any hxcpp build
- For HashLink: the HashLink VM, on x86-64 (hashlink-debugger's native module is built for x86-64
  only). On macOS, `hl` must be codesigned for debugging (`make codesign_osx` when building HashLink).
- For JavaScript: Node

## Setting up

There is no release yet. To try it, clone this repository and run "zed: install dev extension" on it.

Zed only offers to debug tasks in languages that name a debugger. Until Zed-Haxe does that itself, add
this to your Zed settings:

```json
"languages": {
  "Haxe": { "debuggers": ["Haxe"] },
  "HXML": { "debuggers": ["Haxe"] }
}
```

## Debugging

Open the debugger (F4 by default). Zed-Haxe's `haxe: <file>.hxml` tasks are listed there, ready to
debug. Or describe a session in `.zed/debug.json`:

```json
[
  {
    "label": "Debug build.hxml",
    "adapter": "Haxe",
    "request": "launch",
    "hxml": "build.hxml"
  }
]
```

| Field | Meaning |
|---|---|
| `hxml` | The hxml to build, relative to `cwd`. |
| `haxeArgs` | Haxe arguments, instead of `hxml`. |
| `target` | `"eval"`, `"hxcpp"`, `"cppia"`, `"hl"` or `"js"`. Without it, the build's output decides: `--interp` and `--run` use eval, `--cpp` hxcpp, `--cppia` cppia, `--hl` HashLink, `--js` JavaScript. `"eval"` on a build for another target debugs its macros and writes no output. |
| `cwd` | Folder to run Haxe and the program in. Default: the project folder. |
| `program` | hxcpp: the program to run. Without `hxml` and `haxeArgs`, nothing is built, so it must already be a `-debug` build with `-lib hxcpp-debug-server`. cppia: the host (see "cppia"). HashLink: the `.hl` file, if not the build's. JavaScript: the `.js` file, if not the build's; without `hxml` and `haxeArgs`, one already built, with its source maps. |
| `args`, `env` | hxcpp, cppia, HashLink and JavaScript: the program's arguments, and environment variables added to Zed's. |
| `port` | hxcpp and cppia: the port the program's debug server connects to (see "hxcpp" below). HashLink: the port the debugger talks to the VM on (default 6112). |
| `hl` | HashLink: the VM to run the program with. Default: `hl` on your PATH. |
| `runtimeExecutable` | JavaScript: the Node to run the program with. Default: `node` on your PATH, else the one Zed runs. |
| `stopOnEntry` | eval and JavaScript: pause before the first line runs. |
| `haxePath` | Haxe executable to use. |
| `mergeScopes`, `showGeneratedVariables` | eval-debugger's own options, as in VS Code. |

Without `hxml`, `haxeArgs` and `program`, the debugger uses the hxml Zed-Haxe has selected, else one that
runs with `--interp` or `--run`, else the only one. Zed-Haxe's `project` settings (`haxePath`,
`haxeResolvers`, `root`, `target` under `lsp.haxe-language-server.settings`) apply here too. Of an hxml
with several compilations (`--next`), the first that a debugger here supports is the one debugged.

### hxcpp

The bridge builds the hxml with `-debug` and hxcpp-debug-server added and any `--cmd` left out, then
runs `<--cpp folder>/<main class>-debug`. The build's output shows in the debug console, and a build
error ends the session with the compiler's first lines.

hxcpp-debug-server is a Haxe library compiled into the program, which connects back to the debugger
when it starts. The extension downloads it from [a fork of vshaxe/hxcpp-debugger](https://github.com/Jarrio/hxcpp-debugger)
with fixes that the haxelib release (1.2.4, from 2020) lacks: Haxe 4.0 and Haxe 5 support, errors
instead of `null` for console expressions it can't evaluate, and a port chosen when the program starts,
so that two sessions don't collide. A build that has `-lib hxcpp-debug-server` keeps its own copy, and
the program then connects to port 6972, or to the one `-D HXCPP_DEBUG_PORT` sets.

Tested with:

| hxcpp | Haxe |
|---|---|
| 4.3.2, the haxelib release | 4.0.5, 4.1.5, 4.2.5, 4.3.7 |
| [libhxcpp](https://github.com/openfl/libhxcpp) (main, October 2026) | 4.3.7 |
| git master (October 2026) | 4.3.7, 5.0.0-preview.1 |

Haxe 5 needs hxcpp from git: it refuses 4.3.2 as out of date.

### cppia

A cppia script runs in a host, which has to be built for debugging: an hxcpp `-debug` build with
`-D scriptable` and hxcpp-debug-server. Name it in `program`. The bridge builds the script's hxml with
`-debug` and runs the host with the script's path, unless `args` says otherwise:

```json
{
  "label": "Debug script.cppia",
  "adapter": "Haxe",
  "request": "launch",
  "hxml": "script.hxml",
  "program": "bin/host/Host-debug"
}
```

Breakpoints in the script take effect when the host loads it, which needs hxcpp to call the debug
server back at that point:

- With libhxcpp, on Haxe 4.3.7, breakpoints, stepping, locals and the console work.
- With hxcpp master and the Haxe 5 preview, breakpoints stop in the right place, but locals read as 0
  and the program exits with code 1 after you continue.
- With hxcpp 4.3.2, or git hxcpp on Haxe 4, breakpoints in a script never take effect.

Until the script is loaded, Zed shows its breakpoints as unverified, and they stay that way after they
take effect.

### HashLink

The bridge builds the hxml with `-debug` and any `--cmd` left out, then hands hashlink-debugger the
`.hl` file and the build's class paths, which it needs to find the files the program's debug
information names. It runs the program with `hl` from your PATH, or the one `hl` names.

Tested with HashLink 1.16, the stable release, on Haxe 4.0.5, 4.1.5, 4.2.5, 4.3.7 and the 5.0.0
preview. With the HashLink nightly of October 2026, which calls itself 2.0.0, the program stops at
breakpoints but hashlink-debugger 2.0.0 reads its variables wrong. HashLink/C builds (`--hl main.c`)
don't run in the VM, so they can't be debugged here.

### JavaScript

The bridge builds the hxml with `-debug -D js-source-map` and any `--cmd` left out, then runs the
program with Node under js-debug, the debugger Zed's own JavaScript support uses. js-debug follows the
source maps, so breakpoints go in the `.hx` files, and frames, stepping and the program's output point
there too. Variables and the debug console are JavaScript's: the console takes JavaScript expressions,
and names are the ones Haxe generated, which are mostly the Haxe ones.

js-debug runs the program in a session of its own, which it asks the editor to open. The bridge opens
it itself, so Zed shows one session, as for the other targets.

Tested with Haxe 4.0.5, 4.1.5, 4.2.5, 4.3.7, the 5.0.0 preview and the nightly of October 2026.
Browser JavaScript isn't supported yet; Zed's own
JavaScript adapter can debug it, given `"pauseForSourceMap": false` and
`"__workspaceFolder": "$ZED_WORKTREE_ROOT"`, without which breakpoints in `.hx` files don't take effect.

## Known issues

- Haxe 5's eval reports threads under two different numbers and starts a thread for every value it
  shows. The bridge matches the numbers up and hides those threads from Zed.
- Haxe 5's eval stops answering after a completion request, so the bridge turns off debug console
  completions with Haxe 5. Haxe 4.2 and 4.3 answer the completion requests Zed sends with "No
  completion point found"; 4.0 and 4.1 complete.
- Debug console expressions are Haxe, but eval doesn't compile them; it runs them against the paused
  program's values. Locals, fields, operators, indexing, method and static calls, and `new` work. These
  don't:
  - static extensions through `using` (`name.startsWith("h")`)
  - an abstract's methods and operators (`map["b"]`; `map.get("b")` works)
  - lambdas, array comprehensions, `switch` and `cast`
  - functions that dead code elimination removed
  - assignment (`x = 1` changes nothing)
  - string interpolation (`'$name'` comes back as the text `$name`)

  For an expression it can't evaluate, eval answers `null` instead of an error, so a `null` result
  doesn't always mean the value is null.
- eval-debugger runs Haxe through a shell without quoting its arguments. The bridge runs it from the
  project folder so that the folder's path isn't one of them, but a space in an hxml argument still
  breaks.
- hxcpp's console expressions are Haxe too, run by an interpreter in the debug server. It handles more
  than eval: lambdas, array comprehensions, `switch`, and `map["b"]` work. These don't:
  - static extensions through `using`, and `cast`
  - functions that dead code elimination removed ("Null Function Pointer")
  - string interpolation (`'$name'` comes back as the text `$name`)

  A field that doesn't exist reads as `null`.
- hxcpp can change only the local variables of the innermost frame, and stepping always steps the main
  thread.
- The Haxe 5 nightly of October 2026 can't build any program that uses `sys.thread.Thread.current()`
  against hxcpp master of the same month, and the debug server uses it.
- A debug build with hxcpp-debug-server doesn't exit when it runs without the debugger: the server
  waits for one to attach.
- HashLink reports a finished step as a stop at a breakpoint.

## How it works

`src/lib.rs` is a thin Rust layer: it downloads vshaxe's extension from Open VSX (eval-debugger has no
releases of its own), and hxcpp-debug-server, hashlink-debugger and js-debug from GitHub, then has Zed
run `node bridge.js`. The bridge reads the debug configuration and picks the debugger.

- eval: it starts eval-debugger and relays DAP messages between it and Zed, rewriting the `launch`
  request and fixing the replies Zed can't use (`bridge/src/bridge/targets/Eval*.hx`).
- hxcpp and cppia: it answers Zed itself (`targets/HxcppAdapter.hx`). It builds the program, waits for
  its debug server to connect over TCP, and turns each DAP request into a request to that server
  (`targets/HxcppServer.hx`).
- HashLink: it builds the program, asking Haxe for the class paths with a small macro on the way
  (`targets/HashLink.hx`), then starts hashlink-debugger and relays DAP messages as for eval.
- JavaScript: it builds the program, starts js-debug's server, and relays DAP messages over TCP,
  opening the program's session itself (`targets/JsDebugAdapter.hx`).

## Development

The bridge needs Haxe 4.3.7 (so that `bridge/bin/bridge.js`, which is committed, builds byte for byte):

```sh
cd bridge
haxelib newrepo && haxelib install install.hxml
haxe build.hxml       # bin/bridge.js
haxe test.hxml        # unit tests
node e2e/run.js       # the real bridge debugging real Haxe programs; --haxe=PATH picks the Haxe
```

The end-to-end tests skip hxcpp when it isn't installed, and HashLink when `hl` isn't on PATH (`--hl=PATH`
names one). `--hxcpp-debug-server=PATH` tests a checkout of the library instead of the version
`src/lib.rs` pins.

Haxe 5 needs hxcpp from git. To test with it without changing the hxcpp your other projects use, install
it in a local repository in this folder, and point the tests at it (they build in temporary folders,
outside its reach):

```sh
haxelib newrepo
haxelib git hxcpp https://github.com/HaxeFoundation/hxcpp
(cd .haxelib/hxcpp/git/tools/hxcpp && haxe compile.hxml)   # hxcpp's build tool, once
HAXELIB_PATH=$PWD/.haxelib node bridge/e2e/run.js --haxe=/path/to/haxe5/haxe
```

Then install the folder as a dev extension, or rebuild it from Zed's extensions page. To try bridge
changes without rebuilding the extension, point Zed at your build:

```json
"dap": { "Haxe": { "binary": "/path/to/haxe-debug/bridge/bin/bridge.js" } }
```

Add `"traceFile": "/some/file.log"` to a debug configuration to log every message the bridge relays.

## License

MIT. eval-debugger, vshaxe, hxcpp-debugger, hashlink-debugger and js-debug are MIT-licensed too.
