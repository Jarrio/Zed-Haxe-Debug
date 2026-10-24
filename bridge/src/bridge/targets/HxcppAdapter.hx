package bridge.targets;

import bridge.Build;
import bridge.dap.Adapter;
import bridge.dap.Message;
import bridge.targets.Hxcpp;
import bridge.util.Exec;
import bridge.util.ProcessTree;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import js.node.ChildProcess;
import js.node.Net;
import sys.FileSystem;

/**
	Debugs hxcpp programs. It builds the program with hxcpp-debug-server, runs it, waits for its debug
	server to connect, and then translates between Zed's DAP and that server's protocol (`HxcppServer`).

	vshaxe's hxcpp-debugger does the translating for VS Code (its `src/Adapter.hx`). This one also builds,
	keeps the program paused until Zed has sent the breakpoints (`configurationDone`), gives each session
	its own port, and stops the program when the session ends.
**/
@:access(bridge.util.Exec)
class HxcppAdapter implements Adapter {
	public var onMessage:Message->Void = _ -> {};
	public var onClose:Int->Void = _ -> {};

	static inline final connectSeconds = 30;

	var seq = 0;
	var program:Null<js.node.child_process.ChildProcess>;
	var listener:Null<js.node.net.Server>;
	var server:Null<HxcppServer>;
	var killed = false;
	var terminated = false;

	/** `setBreakpoints` requests that came before the program connected. **/
	final early:Array<Message> = [];

	var configured = false;
	var running = false;

	/** Threads Zed has been told about. The server reports a thread as started each time it resumes. **/
	final threads:Map<Int, Bool> = [];

	var stopped = false;

	/** What the next `pauseStop` means: a step finished, unless a pause was asked for. **/
	var pauseReason = "pause";

	/** The innermost frame of the current stop and its locals: the only locals the server can change. **/
	var topFrame:Null<Int>;

	var topLocals:Null<Int>;

	/**
		Where the values Zed has been shown since the program stopped come from, by variables reference:
		the frame, and the expression that reads the value (`point`, `point.x`, `list[0]`), which a frame's
		locals don't have. Fields and items change through an assignment the server's evaluator runs.
	**/
	final values:Map<Int, {frame:Int, expression:Null<String>}> = [];

	public function new() {}

	public function send(message:Message) {
		if (message.type != "request") {
			return;
		}
		final args:Dynamic = message.arguments ?? {};
		switch message.command {
			case "initialize":
				respond(message, {
					supportsConfigurationDoneRequest: true,
					supportsConditionalBreakpoints: true,
					supportsCompletionsRequest: true,
					supportsSetVariable: true,
					supportsTerminateRequest: true
				});
				event("initialized");
			case "launch":
				launch(message, message.arguments);
			case "setBreakpoints":
				if (server == null) {
					early.push(message);
				} else {
					setBreakpoints(message);
				}
			case "setExceptionBreakpoints":
				respond(message);
			case "configurationDone":
				configured = true;
				respond(message);
				run();
			case "threads":
				if (server == null) {
					respond(message, {threads: []});
				} else {
					forward(message, "threads", null, function(result:Array<Dynamic>) {
						return {threads: [for (thread in result) {id: thread.id, name: thread.id == 0 ? "Main thread" : 'Thread ${thread.id}'}]};
					});
				}
			case "stackTrace":
				forward(message, "stackTrace", {threadId: args.threadId}, function(result:Array<Dynamic>) {
					// The server leaves out its own frames by their file name, which a build with full paths in
					// its positions (`-D absolute-path`, as Ceramic's) doesn't match.
					var first = 0;
					while (first < result.length && isDebuggerFrame(result[first])) {
						first++;
					}
					final frames = [for (frame in result.slice(first)) stackFrame(frame)];
					topFrame = frames.length > 0 ? frames[0].id : null;
					final start:Int = args.startFrame ?? 0;
					final levels:Int = args.levels ?? 0;
					return {stackFrames: frames.slice(start, levels > 0 ? start + levels : frames.length), totalFrames: frames.length};
				});
			case "scopes":
				final frameId:Int = args.frameId;
				forward(message, "getScopes", {frameId: frameId}, function(result:Array<Dynamic>) {
					for (scope in result) {
						if (frameId == topFrame && scope.name == "Locals") {
							topLocals = scope.id;
						}
						if (scope.name == "Locals" || scope.name == "Members") {
							values.set(scope.id, {frame: frameId, expression: scope.name == "Members" ? "this" : null});
						}
					}
					return {scopes: [for (scope in result) {name: scope.name, variablesReference: scope.id, expensive: false}]};
				});
			case "variables":
				final params:Dynamic = {variablesReference: args.variablesReference};
				if (args.start != null) {
					params.start = args.start;
				}
				if (args.count != null) {
					params.count = args.count;
				}
				final parent = values.get(args.variablesReference);
				forward(message, "getVariables", params, function(result:Array<Dynamic>) {
					if (parent != null) {
						for (info in result) {
							final expression = member(parent.expression, info.name);
							if (info.variablesReference != null && info.variablesReference > 0 && expression != null) {
								values.set(info.variablesReference, {frame: parent.frame, expression: expression});
							}
						}
					}
					return {variables: [for (info in result) variable(info)]};
				});
			case "evaluate":
				if (!stopped) {
					respond(message, null, "The program is running. Pause it to evaluate expressions.");
				} else {
					final frameId:Int = args.frameId ?? topFrame;
					forward(message, "evaluate", {expr: args.expression, frameId: frameId}, function(info:Dynamic) {
						if (info.variablesReference != null && info.variablesReference > 0) {
							final path = ~/^[A-Za-z_][\w.]*$/.match(args.expression) ? args.expression : '(${args.expression})';
							values.set(info.variablesReference, {frame: frameId, expression: path});
						}
						final body = variable(info);
						body.result = body.value;
						Reflect.deleteField(body, "value");
						Reflect.deleteField(body, "name");
						return body;
					});
				}
			case "setVariable":
				final target = values.get(args.variablesReference);
				final assigned = target?.expression == null ? null : member(target.expression, args.name);
				if (args.variablesReference == topLocals) {
					forward(message, "setVariable", {expr: args.name, value: args.value}, (result:Dynamic) -> {value: Std.string(result.value)});
				} else if (assigned != null) {
					forward(message, "evaluate", {expr: '$assigned = ${args.value}', frameId: target.frame}, function(info:Dynamic) {
						final body = variable(info);
						Reflect.deleteField(body, "name");
						return body;
					});
				} else if (target != null && target.expression == null) {
					respond(message, null, "hxcpp can only change the local variables of the innermost frame.");
				} else {
					respond(message, null, 'hxcpp can\'t change ${args.name} from the variables list. An assignment in the debug console may work.');
				}
			case "completions":
				if (!stopped) {
					respond(message, {targets: []});
				} else {
					forward(message, "completions", {frameId: args.frameId, text: args.text, column: args.column}, function(result:Array<Dynamic>) {
						return {targets: [for (item in result) {label: item.label, type: "variable"}]};
					});
				}
			// Answered before the server is asked: it can report the next stop before it answers, and Zed
			// must get the answer first.
			case "continue":
				resumed();
				respond(message, {allThreadsContinued: true});
				tell("continue", {threadId: args.threadId});
			case "next" | "stepIn" | "stepOut":
				pauseReason = "step";
				resumed();
				respond(message);
				tell(message.command, {});
			case "pause":
				pauseReason = "pause";
				// The server answers once every thread has stopped, which a thread blocked in native code can
				// put off indefinitely.
				respond(message);
				tell("pause", {});
			case "terminate":
				respond(message);
				if (program != null) {
					ProcessTree.kill(program);
				} else {
					finish();
				}
			case "disconnect":
				respond(message);
				kill();
				onClose(0);
			case other:
				respond(message, null, 'The hxcpp debugger doesn\'t support "$other".');
		}
	}

	public function kill() {
		if (killed) {
			return;
		}
		killed = true;
		Build.stopAll();
		if (program != null) {
			ProcessTree.kill(program);
		}
		server?.close();
		listener?.close();
	}

	function launch(request:Message, launch:HxcppLaunch) {
		final built:Promise<Any> = launch.build == null ? Promise.resolve(null) : Build.run(launch.build, text -> output("console", text));
		built.then(_ -> start(launch)).then(function(_) {
			respond(request);
			for (message in early) {
				setBreakpoints(message);
			}
			early.resize(0);
			run();
		}).catchError(function(error:Dynamic) {
			respond(request, null, Std.string(error));
			for (message in early) {
				respond(message, null, "The program didn't start.");
			}
			early.resize(0);
			kill();
			finish();
		});
	}

	/** Runs the program and resolves once its debug server has connected. **/
	function start(launch:HxcppLaunch):Promise<Any> {
		if (killed) {
			return Promise.reject("The session ended.");
		}
		final name = Path.withoutDirectory(launch.program);
		final launcher = launch.launcher == true;
		final env = Build.environment(launch.env);
		// A launcher, such as `haxelib run lime test`, is found on PATH, through cmd.exe for a .cmd on Windows.
		final start = launcher ? Exec.prepare(launch.program, launch.args, {cwd: launch.cwd, env: env}) : {file: launch.program, args: launch.args, verbatim: false};
		if (start == null || (!launcher && !FileSystem.exists(launch.program))) {
			return Promise.reject(launcher ? '${launch.program} was not found.' : launch.build == null ? '${launch.program} doesn\'t exist.' : 'The build didn\'t make ${launch.program}. If it writes the program elsewhere, set "program" in the debug configuration.');
		}
		return new Promise(function(resolve, reject) {
			final listener = Net.createServer();
			this.listener = listener;
			listener.on("error", (error:js.lib.Error) -> reject('Couldn\'t wait for the program on port ${launch.port}: ${error.message}'));
			listener.listen(launch.port, "127.0.0.1", function() {
				final port:Int = (cast listener.address()).port;
				env.set("HXCPP_DEBUG_HOST", "127.0.0.1");
				env.set("HXCPP_NO_COLOR", "1");
				env.set("HXCPP_DEBUG_PORT", Std.string(port));
				var connected = false;
				// A launcher builds first, which can take minutes: it has as long as it runs.
				final timer = launcher ? null : haxe.Timer.delay(function() {
					reject('$name didn\'t connect to the debugger within $connectSeconds seconds. Was it built with -debug and hxcpp-debug-server?');
				}, connectSeconds * 1000);
				listener.once("connection", function(socket:js.node.net.Socket) {
					connected = true;
					timer?.stop();
					listener.close();
					final server = new HxcppServer(socket);
					server.onNotification = notification;
					server.onClose = function() {
						// When the program exits, its exit code comes with the process's own "close".
						if (program == null) {
							finish();
						}
					};
					this.server = server;
					resolve(null);
				});
				if (launcher) {
					output("console", 'Running: ${Build.commandLine(launch.program, launch.args)}\n');
				}
				final child = ProcessTree.spawn(start.file, start.args, {
					cwd: launch.cwd,
					env: env,
					windowsHide: true,
					windowsVerbatimArguments: start.verbatim
				});
				program = child;
				final lastLines = [];
				child.stdout.setEncoding("utf8");
				child.stderr.setEncoding("utf8");
				function show(category:String, text:String) {
					// Until the program connects, a launcher's output is its build's.
					final shown = launcher ? Build.plain(text) : text;
					output(launcher && !connected ? "console" : category, shown);
					if (!connected) {
						lastLines.push(shown);
					}
				}
				child.stdout.on("data", (text:String) -> show("stdout", text));
				child.stderr.on("data", (text:String) -> show("stderr", text));
				child.on("error", function(error:js.lib.Error) {
					timer?.stop();
					reject('Couldn\'t start ${launch.program}: ${error.message}');
				});
				child.on("close", function(code:Null<Int>, signal:Null<String>) {
					program = null;
					timer?.stop();
					if (!connected) {
						if (launcher) {
							final lines = [for (line in lastLines.join("").split("\n")) if (StringTools.trim(line) != "") StringTools.trim(line)];
							reject('${Build.commandLine(launch.program, launch.args)} ended (${Build.exitStatus(code, signal)}) without starting a program that connected to the debugger${lines.length > 0 ? ": " + lines.slice(-3).join("\n") : "."}');
						} else {
							reject('$name exited (${Build.exitStatus(code, signal)}) before connecting to the debugger. Was it built with -debug and hxcpp-debug-server?');
						}
						return;
					}
					event("exited", {exitCode: code ?? 1});
					finish();
				});
			});
		});
	}

	/** Lets the program run, once it's connected and Zed has sent the breakpoints. **/
	function run() {
		final server = server;
		if (server == null || !configured || running) {
			return;
		}
		running = true;
		tell("continue", {threadId: 0});
	}

	function setBreakpoints(request:Message) {
		final args:Dynamic = request.arguments;
		final requested:Array<Dynamic> = args.breakpoints ?? [];
		final breakpoints = [
			for (breakpoint in requested) {
				final params:Dynamic = {line: breakpoint.line};
				if (breakpoint.condition != null) {
					params.condition = breakpoint.condition;
				}
				params;
			}
		];
		forward(request, "setBreakpoints", {file: args.source.path, breakpoints: breakpoints}, function(result:Array<Dynamic>) {
			// One id per breakpoint, -1 where it couldn't be set. Older servers leave out the ones that failed.
			final ids = result != null && result.length == requested.length ? result : null;
			return {breakpoints: [for (i in 0...requested.length) breakpoint(requested[i], ids == null ? null : ids[i])]};
		});
	}

	static function breakpoint(requested:Dynamic, id:Null<Int>):Dynamic {
		if (id != null && id >= 0) {
			return {verified: true, id: id, line: requested.line};
		}
		return {
			verified: false,
			line: requested.line,
			message: requested.condition != null ? "The condition doesn't parse, or no code from this file is loaded." : "No code from this file is loaded."
		};
	}

	function notification(method:String, params:Dynamic) {
		// The server pauses the program inside its own startup code until it's told to continue (`run`).
		if (!running && StringTools.endsWith(method, "Stop")) {
			return;
		}
		switch method {
			case "breakpointStop":
				stop("breakpoint", params.threadId);
			case "pauseStop":
				stop(pauseReason, params.threadId);
			case "exceptionStop":
				stop("exception", 0, params.text);
			case "threadStart":
				final id:Int = params.threadId;
				if (!threads.exists(id)) {
					threads.set(id, true);
					event("thread", {reason: "started", threadId: id});
				}
			case "ThreadExit":
				final id:Int = params.threadId;
				if (threads.remove(id)) {
					event("thread", {reason: "exited", threadId: id});
				}
			case other:
				Log.info('unknown notification from the debug server: $other');
		}
	}

	function stop(reason:String, threadId:Int, ?text:String) {
		stopped = true;
		pauseReason = "pause";
		final body:Dynamic = {reason: reason, threadId: threadId, allThreadsStopped: true};
		if (text != null) {
			body.text = text;
			body.description = text;
		}
		event("stopped", body);
	}

	function resumed() {
		stopped = false;
		topFrame = null;
		topLocals = null;
		values.clear();
	}

	/** Tells Zed the session is over, once. **/
	function finish() {
		if (!terminated) {
			terminated = true;
			event("terminated");
		}
	}

	/** Sends the debug server a request whose answer Zed doesn't wait for. **/
	function tell(method:String, params:Dynamic) {
		server?.request(method, params).catchError(error -> Log.info('$method failed: $error'));
	}

	/** Sends `request` to the debug server and answers Zed with `body` of its result, or with its error. **/
	function forward(request:Message, method:String, params:Dynamic, ?body:Dynamic->Dynamic) {
		final server = server;
		if (server == null) {
			respond(request, null, "The program isn't running.");
			return;
		}
		server.request(method, params)
			.then(result -> body == null ? null : body(result))
			.then(result -> respond(request, result), (error:Dynamic) -> respond(request, null, Std.string(error)));
	}

	static function isDebuggerFrame(info:Dynamic):Bool {
		final name:String = info.name ?? "";
		return StringTools.startsWith(name, "hxcpp.debug.jsonrpc.") || StringTools.startsWith(name, "cpp.vm.Debugger.");
	}

	static function stackFrame(info:Dynamic):Dynamic {
		final frame:Dynamic = {
			id: info.id,
			name: info.name,
			line: info.line,
			column: 1
		};
		// hxcpp's own frames, such as `__hxcpp_main`, are in the file "?".
		if (info.source != null && Path.withoutDirectory(info.source) != "?") {
			frame.source = {name: Path.withoutDirectory(info.source), path: info.source};
		} else {
			frame.presentationHint = "subtle";
		}
		return frame;
	}

	/**
		The expression for `name` in the value `parent` reads: a field, an array item or a map entry (the
		server shows a StringMap's keys quoted). Without a parent, the local `name`. Null when there's none.
	**/
	static function member(parent:Null<String>, name:String):Null<String> {
		final identifier = ~/^[A-Za-z_]\w*$/.match(name);
		if (parent == null) {
			return identifier ? name : null;
		}
		if (~/^-?\d+$/.match(name) || StringTools.startsWith(name, '"')) {
			return '$parent[$name]';
		}
		return identifier ? '$parent.$name' : null;
	}

	static function variable(info:Dynamic):Dynamic {
		final variable:Dynamic = {
			name: info.name,
			value: Std.string(info.value),
			type: info.type,
			variablesReference: info.variablesReference ?? 0
		};
		if (info.indexedVariables != null) {
			variable.indexedVariables = info.indexedVariables;
		}
		if (info.namedVariables != null) {
			variable.namedVariables = info.namedVariables;
		}
		return variable;
	}

	function respond(request:Message, ?body:Dynamic, ?failure:String) {
		final response:Message = {
			seq: ++seq,
			type: "response",
			request_seq: request.seq,
			command: request.command,
			success: failure == null
		};
		if (body != null) {
			response.body = body;
		}
		if (failure != null) {
			response.message = failure;
		}
		onMessage(response);
	}

	function event(name:String, ?body:Dynamic) {
		final message:Message = {seq: ++seq, type: "event", event: name};
		if (body != null) {
			message.body = body;
		}
		onMessage(message);
	}

	function output(category:String, text:String) {
		event("output", {category: category, output: text});
	}
}
