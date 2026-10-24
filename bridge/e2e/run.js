// End-to-end tests: the real bridge and eval-debugger debugging real Haxe, driven the way Zed drives them.
//
//   node e2e/run.js [test names...] [--haxe=PATH] [--hl=PATH] [--eval=PATH] [--hxcpp-debug-server=PATH]
//                   [--hashlink=PATH] [--js-debug=PATH] [--bridge=PATH] [--verbose]
//
// Without --haxe, the bridge picks Haxe as it would for a user (PATH here). eval-debugger,
// hxcpp-debug-server, hashlink-debugger and js-debug come from the releases src/lib.rs pins, downloaded
// into e2e/.adapters. Each test copies its project into a temporary folder with a space in its name, which
// eval-debugger can't handle by itself (see Eval.hx). The hxcpp tests need hxcpp (haxelib install hxcpp)
// and a C++ compiler; the HashLink tests need the HashLink VM (`hl` on PATH, or --hl) on x86-64.
"use strict";
const childProcess = require("child_process");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");

const args = process.argv.slice(2);
const option = (name) => args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
const verbose = args.includes("--verbose");
const only = args.filter((arg) => !arg.startsWith("--"));
const bridgeDir = path.join(__dirname, "..");

/** A DAP client speaking to the bridge over stdio, as Zed does. **/
class Client {
  constructor(bridge, cwd, bridgeArgs) {
    this.seq = 0;
    this.pending = new Map();
    this.events = [];
    this.waiters = [];
    this.buffer = Buffer.alloc(0);
    this.stderr = "";
    this.child = childProcess.spawn(process.execPath, [bridge, ...bridgeArgs], { cwd });
    this.child.stdout.on("data", (chunk) => this.receive(chunk));
    this.child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
      if (verbose) process.stderr.write(chunk);
    });
    this.exited = new Promise((resolve) => this.child.on("exit", resolve));
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const length = Number(/Content-Length:\s*(\d+)/i.exec(this.buffer.toString("ascii", 0, headerEnd))[1]);
      if (this.buffer.length < headerEnd + 4 + length) return;
      const message = JSON.parse(this.buffer.toString("utf8", headerEnd + 4, headerEnd + 4 + length));
      this.buffer = this.buffer.subarray(headerEnd + 4 + length);
      if (verbose) console.log("  <-", JSON.stringify(message).slice(0, 300));
      if (message.type === "response") {
        this.pending.get(message.request_seq)?.(message);
        this.pending.delete(message.request_seq);
      } else if (message.type === "event") {
        this.events.push(message);
        this.waiters = this.waiters.filter((waiter) => !waiter(message));
      }
    }
  }

  request(command, args, ms) {
    const seq = this.send(command, args);
    return within(new Promise((resolve) => this.pending.set(seq, resolve)), `response to ${command}`, ms);
  }

  /** Sends a request without waiting for its response. **/
  send(command, args) {
    const message = { seq: ++this.seq, type: "request", command, arguments: args };
    if (verbose) console.log("  ->", JSON.stringify(message).slice(0, 300));
    const body = Buffer.from(JSON.stringify(message), "utf8");
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
    return message.seq;
  }

  /** Resolves with the first event named `name` (already received or still to come). **/
  event(name, ms) {
    const seen = this.events.find((event) => event.event === name);
    if (seen) return Promise.resolve(seen);
    return within(new Promise((resolve) => {
      this.waiters.push((event) => event.event === name && (resolve(event), true));
    }), `${name} event`, ms);
  }

  /** Waits for the next `name` event, ignoring the ones already received. **/
  nextEvent(name, ms) {
    return within(new Promise((resolve) => {
      this.waiters.push((event) => event.event === name && (resolve(event), true));
    }), `${name} event`, ms);
  }

  /** Everything the program and the build wrote to the debug console so far. **/
  output() {
    return this.events.filter((event) => event.event === "output").map((event) => event.body.output).join("");
  }

  async close() {
    this.child.stdin.end();
    await within(this.exited, "bridge to exit").catch(() => this.child.kill());
  }
}

// hxcpp builds from scratch in each test, which can take minutes on a CI machine.
const buildTime = 10 * 60000;

function within(promise, what, ms = 60000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => (timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms))),
  ]).finally(() => clearTimeout(timer));
}

function check(condition, message) {
  if (!condition) throw new Error(message);
}

/** The line holding `// BREAK <name>`, 1-based. **/
function breakLine(file, name) {
  const index = fs.readFileSync(file, "utf8").split("\n").findIndex((line) => line.includes(`// BREAK ${name}`));
  check(index >= 0, `no BREAK ${name} in ${file}`);
  return index + 1;
}

const copies = [];

/** Copies e2e/projects/<name> into a new temporary folder whose name has a space. **/
function copyProject(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "haxe debug e2e "));
  fs.cpSync(path.join(__dirname, "projects", name), dir, { recursive: true });
  copies.push(dir);
  return dir;
}

async function start(env, project, config) {
  const dir = copyProject(project);
  if (env.haxe) config = { ...config, haxePath: env.haxe };
  const trace = option("trace") ? ["--trace", path.resolve(option("trace"))] : [];
  const server = env.hxcppDebugServer ? ["--hxcpp-debug-server", env.hxcppDebugServer] : [];
  const hashlink = env.hashlink ? ["--hashlink", env.hashlink] : [];
  const jsDebug = env.jsDebug ? ["--js-debug", env.jsDebug] : [];
  const client = new Client(env.bridge, dir, ["--config", JSON.stringify(config), "--project", "{}", "--eval", env.eval, ...server, ...hashlink, ...jsDebug, ...trace]);
  const init = await client.request("initialize", { adapterID: "Haxe", linesStartAt1: true, columnsStartAt1: true, pathFormat: "path" });
  check(init.success, `initialize failed: ${init.message}`);
  return { dir, client, config, capabilities: init.body };
}

/** Launches, sets one breakpoint, runs to it and returns the top stack frame and its variables by name. **/
async function runToBreakpoint({ client, config }, file, line) {
  const launched = client.request("launch", config, buildTime);
  await client.event("initialized");
  const set = await client.request("setBreakpoints", { source: { path: file }, breakpoints: [{ line }] }, buildTime);
  if (!set.success) {
    // Probably because the launch failed, which says why.
    const launch = await launched;
    check(launch.success, `launch failed: ${launch.message}`);
  }
  check(set.success, `setBreakpoints failed: ${set.message}`);
  await client.request("configurationDone", {});
  const launch = await launched;
  check(launch.success, `launch failed: ${launch.message}`);
  const stopped = await client.event("stopped");
  // Zed asks for the threads after every stop, and eval-debugger only knows thread ids it has listed.
  const threads = (await client.request("threads", {})).body.threads;
  const threadId = stopped.body.threadId ?? threads[0].id;
  const frame = (await client.request("stackTrace", { threadId })).body.stackFrames[0];
  const scopes = (await client.request("scopes", { frameId: frame.id })).body.scopes;
  const variables = {};
  for (const scope of scopes) {
    for (const variable of (await client.request("variables", { variablesReference: scope.variablesReference })).body.variables) {
      variables[variable.name] = variable.value;
    }
  }
  return { threadId, frame, variables, stopped };
}

const tests = {
  async interp(env) {
    const session = await start(env, "interp", { request: "launch" });
    const file = path.join(session.dir, "src", "Main.hx");
    const line = breakLine(file, "main");
    const { threadId, frame, variables } = await runToBreakpoint(session, file, line);
    check(frame.line === line, `stopped at line ${frame.line}, expected ${line}`);
    check(variables.greeting === '"hello"', `greeting is ${variables.greeting}`);
    check(variables.sum === "5", `sum is ${variables.sum}`);
    // Haxe 5 reports a thread for every value it prints; each one would make Zed fetch everything again.
    check(!session.client.events.some((event) => event.event === "thread"), "thread events reached the client");
    // When the program ends right away, Haxe may exit before eval-debugger answers `continue`; Zed only
    // needs `terminated`.
    session.client.send("continue", { threadId });
    await session.client.event("terminated");
    await session.client.request("disconnect", {});
    await session.client.close();
  },

  async evaluate(env) {
    const session = await start(env, "interp", { request: "launch" });
    const file = path.join(session.dir, "src", "Main.hx");
    const { threadId, frame } = await runToBreakpoint(session, file, breakLine(file, "main"));
    const result = await session.client.request("evaluate", { expression: "sum * 2", frameId: frame.id, context: "repl" });
    check(result.success && result.body.result === "10", `sum * 2 gave ${JSON.stringify(result.body ?? result.message)}`);
    session.client.send("continue", { threadId });
    await session.client.event("terminated");
    await session.client.request("disconnect", {});
    await session.client.close();
  },

  // Zed asks for completions while you type in the debug console.
  async completions(env) {
    const session = await start(env, "interp", { request: "launch" });
    const file = path.join(session.dir, "src", "Main.hx");
    const { threadId, frame } = await runToBreakpoint(session, file, breakLine(file, "main"));
    // Haxe 5's eval breaks on completions, so the bridge turns them off there (see EvalCompletions.hx).
    // Haxe 4.2 and 4.3 answer "No completion point found", which is their business.
    if (session.capabilities.supportsCompletionsRequest) {
      const completions = await session.client.request("completions", { frameId: frame.id, text: "gr", column: 2 });
      if (completions.success) {
        check(completions.body.targets.some((target) => target.label === "greeting"), `no greeting in ${JSON.stringify(completions.body)}`);
      }
    }
    // Whatever the answer, the debugger must still respond afterwards.
    const result = await session.client.request("evaluate", { expression: "greeting", frameId: frame.id, context: "repl" });
    check(result.success && result.body.result === '"hello"', `greeting gave ${JSON.stringify(result.body ?? result.message)}`);
    session.client.send("continue", { threadId });
    await session.client.event("terminated");
    await session.client.request("disconnect", {});
    await session.client.close();
  },

  async macro(env) {
    const session = await start(env, "macro", { request: "launch", target: "eval" });
    const file = path.join(session.dir, "src", "Macros.hx");
    const line = breakLine(file, "macro");
    const { threadId, frame, variables } = await runToBreakpoint(session, file, line);
    check(frame.line === line, `stopped at line ${frame.line}, expected ${line}`);
    check(variables.value === "42", `value is ${variables.value}`);
    // When the program ends right away, Haxe may exit before eval-debugger answers `continue`; Zed only
    // needs `terminated`.
    session.client.send("continue", { threadId });
    await session.client.event("terminated");
    await session.client.request("disconnect", {});
    await session.client.close();
    check(!fs.existsSync(path.join(session.dir, "bin", "main.js")), "debugging macros wrote the JS output");
  },

  async hxcpp(env) {
    const session = await start(env, "hxcpp", { request: "launch", args: ["one", "two"] });
    const { client, dir } = session;
    const file = path.join(dir, "src", "Main.hx");
    const line = breakLine(file, "main");
    const { threadId, frame, variables, stopped } = await runToBreakpoint(session, file, line);
    check(stopped.body.reason === "breakpoint", `the first stop was a ${stopped.body.reason}`);
    check(frame.line === line, `stopped at line ${frame.line}, expected ${line}`);
    check(variables.greeting === '"hello"', `greeting is ${variables.greeting}`);
    check(variables.sum === "5", `sum is ${variables.sum}`);
    const result = await client.request("evaluate", { expression: "sum * 2", frameId: frame.id, context: "repl" });
    check(result.success && result.body.result === "10", `sum * 2 gave ${JSON.stringify(result.body ?? result.message)}`);
    const unknown = await client.request("evaluate", { expression: "nosuch", frameId: frame.id, context: "repl" });
    check(!unknown.success && /nosuch/.test(unknown.message), `nosuch gave ${JSON.stringify(unknown)}`);
    // A step stops on the next line.
    const stepped = client.nextEvent("stopped");
    await client.request("next", { threadId });
    check((await stepped).body.reason === "step", "the step didn't stop as a step");
    const top = (await client.request("stackTrace", { threadId })).body.stackFrames[0];
    check(top.line === line + 1, `the step stopped at line ${top.line}, expected ${line + 1}`);
    await client.request("continue", { threadId });
    const exited = await client.event("exited");
    check(exited.body.exitCode === 0, `exit code ${exited.body.exitCode}`);
    await client.event("terminated");
    const output = client.output();
    check(output.includes("hello 5"), `no "hello 5" in the output: ${output}`);
    check(output.includes("args one,two"), `the program didn't get its arguments: ${output}`);
    check(output.includes(`cwd ${dir}${path.sep}`), `the program didn't run in the project folder: ${output}`);
    await client.request("disconnect", {});
    await client.close();
  },

  // Breakpoints set while the program runs, and the program killed when the session ends.
  async hxcppStepIn(env) {
    const session = await start(env, "hxcpp", { request: "launch" });
    const { client, dir } = session;
    const file = path.join(dir, "src", "Main.hx");
    const { threadId } = await runToBreakpoint(session, file, breakLine(file, "main") - 1);
    const stepped = client.nextEvent("stopped");
    await client.request("stepIn", { threadId });
    await stepped;
    const frames = (await client.request("stackTrace", { threadId })).body.stackFrames;
    check(frames[0].name === "Main.add" && frames[0].line === breakLine(file, "add"), `stepped into ${JSON.stringify(frames[0])}`);
    check(frames[1].name === "Main.main", `the caller is ${JSON.stringify(frames[1])}`);
    // hxcpp's own frames have no source file.
    check(frames.slice(2).every((frame) => !frame.source), `frames below main: ${JSON.stringify(frames.slice(2))}`);
    await client.request("disconnect", {});
    await client.close();
  },

  async hxcppBuildError(env) {
    const { client, config } = await start(env, "hxcpp", { request: "launch", haxeArgs: ["-cp", "src", "-main", "Missing", "--cpp", "bin"] });
    const launch = await client.request("launch", config, buildTime);
    check(!launch.success && /The build failed/.test(launch.message) && /Missing/.test(launch.message), `unexpected launch result: ${JSON.stringify(launch)}`);
    await client.event("terminated");
    await client.request("disconnect", {});
    await client.close();
  },

  async hashlink(env) {
    const session = await start(env, "hashlink", { request: "launch", args: ["one", "two"], ...(env.hl ? { hl: env.hl } : {}) });
    const { client, dir } = session;
    const file = path.join(dir, "src", "Main.hx");
    const line = breakLine(file, "main");
    const { threadId, frame, variables } = await runToBreakpoint(session, file, line);
    check(frame.line === line, `stopped at line ${frame.line}, expected ${line}`);
    check(variables.greeting === '"hello"', `greeting is ${variables.greeting}`);
    check(variables.sum === "5", `sum is ${variables.sum}`);
    const result = await client.request("evaluate", { expression: "sum * 2", frameId: frame.id, context: "repl" });
    check(result.success && result.body.result === "10", `sum * 2 gave ${JSON.stringify(result.body ?? result.message)}`);
    const stepped = client.nextEvent("stopped");
    await client.request("next", { threadId });
    await stepped;
    const top = (await client.request("stackTrace", { threadId })).body.stackFrames[0];
    check(top.line === line + 1, `the step stopped at line ${top.line}, expected ${line + 1}`);
    await client.request("continue", { threadId });
    const exited = await client.event("exited");
    check(exited.body.exitCode === 0, `exit code ${exited.body.exitCode}`);
    await client.event("terminated");
    const output = client.output();
    check(output.includes("hello 5"), `no "hello 5" in the output: ${output}`);
    check(output.includes("args one,two"), `the program didn't get its arguments: ${output}`);
    check(output.includes(`cwd ${dir}${path.sep}`), `the program didn't run in the project folder: ${output}`);
    await client.request("disconnect", {});
    await client.close();
  },

  async hashlinkBuildError(env) {
    const { client, config } = await start(env, "hashlink", { request: "launch", haxeArgs: ["-cp", "src", "-main", "Missing", "--hl", "bin/main.hl"] });
    const launch = await client.request("launch", config, buildTime);
    check(!launch.success && /The build failed/.test(launch.message) && /Missing/.test(launch.message), `unexpected launch result: ${JSON.stringify(launch)}`);
    await client.event("terminated");
    await client.request("disconnect", {});
    await client.close();
  },

  async javascript(env) {
    const session = await start(env, "javascript", { request: "launch", args: ["one", "two"] });
    const { client, dir } = session;
    const file = path.join(dir, "src", "Main.hx");
    const line = breakLine(file, "main");
    const { threadId, frame, variables } = await runToBreakpoint(session, file, line);
    // The source maps lead back to the Haxe code.
    check(frame.source.path === file && frame.line === line, `stopped at ${frame.source.path}:${frame.line}, expected ${file}:${line}`);
    check(variables.greeting === "'hello'", `greeting is ${variables.greeting}`);
    check(variables.sum === "5", `sum is ${variables.sum}`);
    // The console takes JavaScript.
    const result = await client.request("evaluate", { expression: "sum * 2", frameId: frame.id, context: "repl" });
    check(result.success && result.body.result === "10", `sum * 2 gave ${JSON.stringify(result.body ?? result.message)}`);
    const stepped = client.nextEvent("stopped");
    await client.request("next", { threadId });
    await stepped;
    const top = (await client.request("stackTrace", { threadId })).body.stackFrames[0];
    check(top.source.path === file && top.line === line + 1, `the step stopped at ${top.source?.path}:${top.line}, expected line ${line + 1}`);
    await client.request("continue", { threadId });
    await client.event("terminated");
    const output = client.output();
    check(output.includes("hello 5"), `no "hello 5" in the output: ${output}`);
    check(output.includes("args one,two"), `the program didn't get its arguments: ${output}`);
    check(output.includes(`cwd ${dir}`), `the program didn't run in the project folder: ${output}`);
    await client.request("disconnect", {});
    await client.close();
  },

  async javascriptBuildError(env) {
    const { client, config } = await start(env, "javascript", { request: "launch", haxeArgs: ["-cp", "src", "-main", "Missing", "--js", "bin/main.js"] });
    const launch = await client.request("launch", config, buildTime);
    check(!launch.success && /The build failed/.test(launch.message) && /Missing/.test(launch.message), `unexpected launch result: ${JSON.stringify(launch)}`);
    await client.event("terminated");
    await client.request("disconnect", {});
    await client.close();
  },

  async unsupported(env) {
    const { client, config } = await start(env, "macro", { request: "launch", haxeArgs: ["-cp", "src", "-main", "Main", "--python", "bin/main.py"] });
    const launch = await client.request("launch", config);
    check(!launch.success, "launch of a Python build succeeded");
    check(/python builds isn't supported yet/.test(launch.message), `unexpected message: ${launch.message}`);
    await client.event("terminated");
    await client.request("disconnect", {});
    await client.close();
  },
};

/** eval-debugger's index.js from the vshaxe release src/lib.rs pins. **/
async function pinnedEval() {
  const version = /const VSHAXE_VERSION: &str = "([^"]+)"/.exec(fs.readFileSync(path.join(bridgeDir, "..", "src", "lib.rs"), "utf8"))[1];
  const dir = path.join(__dirname, ".adapters", `vshaxe-${version}`);
  const entry = "extension/eval-debugger/bin/index.js";
  const indexJs = path.join(dir, entry);
  if (!fs.existsSync(indexJs)) {
    fs.mkdirSync(dir, { recursive: true });
    const vsix = path.join(dir, "vshaxe.vsix");
    console.log(`downloading vshaxe ${version}`);
    await download(`https://open-vsx.org/api/nadako/vshaxe/${version}/file/nadako.vshaxe-${version}.vsix`, vsix);
    // Windows' tar reads zip files; elsewhere unzip does.
    const [command, extract] = process.platform === "win32" ? ["tar", ["-xf", vsix, "-C", dir, entry]] : ["unzip", ["-o", "-q", vsix, entry, "-d", dir]];
    childProcess.execFileSync(command, extract, { stdio: "inherit" });
  }
  return indexJs;
}

/** hashlink-debugger's adapter.js from the release src/lib.rs pins. **/
async function pinnedHashLink() {
  const version = /const HASHLINK_DEBUGGER_VERSION: &str = "([^"]+)"/.exec(fs.readFileSync(path.join(bridgeDir, "..", "src", "lib.rs"), "utf8"))[1];
  const dir = path.join(__dirname, ".adapters", `hashlink-debugger-${version}`);
  const adapter = path.join(dir, "extension", "adapter.js");
  if (!fs.existsSync(adapter)) {
    fs.mkdirSync(dir, { recursive: true });
    const vsix = path.join(dir, "hashlink.vsix");
    console.log(`downloading hashlink-debugger ${version}`);
    await download(`https://github.com/vshaxe/hashlink-debugger/releases/download/${version}/haxe-hl-${version}.vsix`, vsix);
    const [command, extract] = process.platform === "win32" ? ["tar", ["-xf", vsix, "-C", dir, "extension"]] : ["unzip", ["-o", "-q", vsix, "extension/*", "-d", dir]];
    childProcess.execFileSync(command, extract, { stdio: "inherit" });
  }
  return adapter;
}

/** js-debug's dapDebugServer.js from the release src/lib.rs pins. **/
async function pinnedJsDebug() {
  const version = /const JS_DEBUG_VERSION: &str = "([^"]+)"/.exec(fs.readFileSync(path.join(bridgeDir, "..", "src", "lib.rs"), "utf8"))[1];
  const dir = path.join(__dirname, ".adapters", `js-debug-${version}`);
  const server = path.join(dir, "js-debug", "src", "dapDebugServer.js");
  if (!fs.existsSync(server)) {
    fs.mkdirSync(dir, { recursive: true });
    const archive = path.join(dir, "js-debug.tar.gz");
    console.log(`downloading js-debug ${version}`);
    await download(`https://github.com/microsoft/vscode-js-debug/releases/download/${version}/js-debug-dap-${version}.tar.gz`, archive);
    childProcess.execFileSync("tar", ["-xzf", archive, "-C", dir], { stdio: "inherit" });
  }
  return server;
}

/** Why the HashLink tests can't run here, or null when they can. **/
function hashlinkMissing(hl) {
  // hashlink-debugger's native module is built for x86-64 only.
  if (process.arch !== "x64") return `hashlink-debugger needs x86-64, this is ${process.arch}`;
  try {
    childProcess.execFileSync(hl ?? "hl", ["--version"], { stdio: "ignore" });
    return null;
  } catch {
    return "the HashLink VM isn't installed (hl on PATH, or --hl)";
  }
}

/** hxcpp-debug-server from the commit src/lib.rs pins. **/
async function pinnedHxcppDebugServer() {
  const lib = fs.readFileSync(path.join(bridgeDir, "..", "src", "lib.rs"), "utf8");
  const repository = /const HXCPP_DEBUGGER_REPOSITORY: &str = "([^"]+)"/.exec(lib)[1];
  const commit = /const HXCPP_DEBUGGER_COMMIT: &str = "([^"]+)"/.exec(lib)[1];
  const dir = path.join(__dirname, ".adapters", `hxcpp-debugger-${commit}`);
  // GitHub's archives hold everything in one folder, named after the repository and the commit.
  const server = path.join(dir, `${repository.split("/")[1]}-${commit}`, "hxcpp-debug-server");
  if (!fs.existsSync(server)) {
    fs.mkdirSync(dir, { recursive: true });
    const zip = path.join(dir, "archive.zip");
    console.log(`downloading ${repository} at ${commit}`);
    await download(`https://github.com/${repository}/archive/${commit}.zip`, zip);
    const [command, extract] = process.platform === "win32" ? ["tar", ["-xf", zip, "-C", dir]] : ["unzip", ["-o", "-q", zip, "-d", dir]];
    childProcess.execFileSync(command, extract, { stdio: "inherit" });
  }
  return server;
}

function hxcppInstalled() {
  try {
    // From a temporary folder, as the tests run: bridge/ has a local haxelib repository without hxcpp.
    childProcess.execFileSync("haxelib", ["path", "hxcpp"], { cwd: os.tmpdir(), stdio: "ignore", shell: process.platform === "win32" });
    return true;
  } catch {
    return false;
  }
}

function download(url, file, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location && redirects > 0) {
        response.resume();
        resolve(download(new URL(response.headers.location, url).href, file, redirects - 1));
      } else if (response.statusCode !== 200) {
        reject(new Error(`GET ${url}: ${response.statusCode}`));
      } else {
        response.pipe(fs.createWriteStream(file)).on("finish", resolve).on("error", reject);
      }
    }).on("error", reject);
  });
}

async function main() {
  const hxcpp = hxcppInstalled();
  const noHashLink = hashlinkMissing(option("hl"));
  const env = {
    haxe: option("haxe"),
    hl: option("hl"),
    eval: option("eval") ?? (await pinnedEval()),
    hxcppDebugServer: option("hxcpp-debug-server") ?? (hxcpp ? await pinnedHxcppDebugServer() : undefined),
    hashlink: option("hashlink") ?? (noHashLink ? undefined : await pinnedHashLink()),
    jsDebug: option("js-debug") ?? (await pinnedJsDebug()),
    bridge: option("bridge") ?? path.join(bridgeDir, "bin", "bridge.js"),
  };
  let failed = 0;
  for (const [name, test] of Object.entries(tests)) {
    if (only.length > 0 && !only.includes(name)) continue;
    if (name.startsWith("hxcpp") && !hxcpp) {
      console.log(`skip ${name}: hxcpp isn't installed (haxelib install hxcpp)`);
      continue;
    }
    if (name.startsWith("hashlink") && noHashLink) {
      console.log(`skip ${name}: ${noHashLink}`);
      continue;
    }
    try {
      await test(env);
      console.log(`ok ${name}`);
    } catch (error) {
      failed++;
      console.log(`FAIL ${name}: ${error.message}`);
    }
  }
  for (const dir of copies) fs.rmSync(dir, { recursive: true, force: true });
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
