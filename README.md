# Haxe debugger for Zed

Breakpoints, stepping, variables and the debug console for Haxe in Zed.

| Target | Debugger | Status |
|---|---|---|
| `--interp`, `--run`, and macros of any build | [eval-debugger](https://github.com/vshaxe/eval-debugger) | works |
| hxcpp (`--cpp`) | [hxcpp-debug-server](https://github.com/Jarrio/hxcpp-debugger) | works |
| HashLink | [hashlink-debugger](https://github.com/vshaxe/hashlink-debugger) | next |

Between Zed and the debuggers sits a **bridge written in Haxe** (`bridge/`), which:

- picks the hxml to debug and the debugger its output needs
- picks the Haxe to run, the same way [Zed-Haxe](https://github.com/Jarrio/Zed-Haxe) does: `.haxerc`
  through lix or haxe-manager, else `haxe` on your PATH
- for eval, runs vshaxe's eval-debugger, the one VS Code uses, unmodified, and works around the places
  where it and Zed don't agree (see "Known issues")
- for hxcpp, builds the program with hxcpp-debug-server, runs it, and talks to the debug server inside
  it, doing the job of the adapter in vshaxe's VS Code extension

## Requirements

- Haxe 4.0 or newer
- A Haxe language extension: [Zed-Haxe](https://github.com/Jarrio/Zed-Haxe) or the `haxe` extension in
  Zed's registry
- For hxcpp: the hxcpp haxelib and a C++ compiler, as for any hxcpp build

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
| `target` | `"eval"` or `"hxcpp"`. Without it, the build's output decides: `--interp` and `--run` use eval, `--cpp` uses hxcpp. `"eval"` on a build for another target debugs its macros and writes no output. |
| `cwd` | Folder to run Haxe and the hxcpp program in. Default: the project folder. |
| `program` | hxcpp: the program to run. Without `hxml` and `haxeArgs`, nothing is built, so it must already be a `-debug` build with `-lib hxcpp-debug-server`. |
| `args`, `env` | hxcpp: the program's arguments, and environment variables added to Zed's. |
| `port` | hxcpp: the port the program's debug server connects to (see "hxcpp" below). |
| `stopOnEntry` | eval: pause before the first line runs. |
| `haxePath` | Haxe executable to use. |
| `mergeScopes`, `showGeneratedVariables` | eval-debugger's own options, as in VS Code. |

Without `hxml`, `haxeArgs` and `program`, the debugger uses the hxml Zed-Haxe has selected, else one that
runs with `--interp` or `--run`, else the only one. Zed-Haxe's `project` settings (`haxePath`,
`haxeResolvers`, `root`, `target` under `lsp.haxe-language-server.settings`) apply here too. Of an hxml
with several compilations (`--next`), the first that eval or hxcpp can debug is the one debugged.

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

The bridge doesn't build cppia scripts, but it can debug a script in a host built for debugging. Build
the host (`-D scriptable`) as an hxcpp debug build with hxcpp-debug-server, build the script with
`-debug`, then name both:

```json
{
  "label": "Debug script.cppia",
  "adapter": "Haxe",
  "request": "launch",
  "program": "bin/host/Host-debug",
  "args": ["bin/script.cppia"]
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

## How it works

`src/lib.rs` is a thin Rust layer: it downloads vshaxe's extension from Open VSX (eval-debugger has no
releases of its own) and hxcpp-debug-server from GitHub, then has Zed run `node bridge.js`. The bridge
reads the debug configuration and picks the debugger.

- eval: it starts eval-debugger and relays DAP messages between it and Zed, rewriting the `launch`
  request and fixing the replies Zed can't use (`bridge/src/bridge/targets/Eval*.hx`).
- hxcpp: it answers Zed itself (`targets/HxcppAdapter.hx`). It builds the program, waits for its debug
  server to connect over TCP, and turns each DAP request into a request to that server
  (`targets/HxcppServer.hx`).

## Development

The bridge needs Haxe 4.3.7 (so that `bridge/bin/bridge.js`, which is committed, builds byte for byte):

```sh
cd bridge
haxelib newrepo && haxelib install install.hxml
haxe build.hxml       # bin/bridge.js
haxe test.hxml        # unit tests
node e2e/run.js       # the real bridge debugging real Haxe programs; --haxe=PATH picks the Haxe
```

The end-to-end tests skip hxcpp when it isn't installed. `--hxcpp-debug-server=PATH` tests a checkout
of the library instead of the version `src/lib.rs` pins.

Then install the folder as a dev extension, or rebuild it from Zed's extensions page. To try bridge
changes without rebuilding the extension, point Zed at your build:

```json
"dap": { "Haxe": { "binary": "/path/to/haxe-debug/bridge/bin/bridge.js" } }
```

Add `"traceFile": "/some/file.log"` to a debug configuration to log every message the bridge relays.

## License

MIT. eval-debugger, vshaxe and hxcpp-debugger are MIT-licensed too.
