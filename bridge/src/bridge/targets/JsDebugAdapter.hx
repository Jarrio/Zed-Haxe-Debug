package bridge.targets;

import bridge.dap.Adapter;
import bridge.dap.Connection;
import bridge.dap.Message;
import bridge.util.ProcessTree;
import js.Node.process;
import js.lib.Promise;
import js.node.Buffer;
import js.node.Net;

/**
	js-debug (see `JavaScript`), presented to Zed as one session.

	js-debug is a TCP server. The session that gets `launch` only starts the program; the program is then
	debugged in a child session, which js-debug asks the client to open (`startDebugging`). Zed would open
	it as a second connection to the adapter, which works for an adapter Zed reaches over TCP, not for the
	bridge on stdin and stdout. So the bridge opens the child session itself, replays the breakpoints there,
	and from then on sends Zed's requests to it.
**/
class JsDebugAdapter implements Adapter {
	public var onMessage:Message->Void = _ -> {};
	public var onClose:Int->Void = _ -> {};

	static inline final startSeconds = 10;

	var serverProcess:Null<js.node.child_process.ChildProcess>;
	var port = 0;
	var root:Null<Connection>;
	var child:Null<Connection>;
	var childReady = false;
	var launched = false;
	var closed = false;
	var terminated = false;

	/** Zed's messages from before js-debug was listening. **/
	final early:Array<Message> = [];

	var initializeArguments:Dynamic = {};

	/** The last `setBreakpoints` for each file, and `setExceptionBreakpoints`, to replay in the child session. **/
	final breakpoints:Map<String, Dynamic> = [];

	var exceptionBreakpoints:Null<Dynamic>;

	/** Sequence numbers of the bridge's own requests to js-debug, and of reverse requests passed on to Zed. **/
	var seq = 1000000000;

	final own:Map<Int, Message->Void> = [];

	/** Reverse requests passed on to Zed, by the number Zed answers to: where they came from and their own number. **/
	final reverse:Map<Int, {connection:Connection, seq:Int}> = [];

	public function new(script:String, cwd:String) {
		freePort().then(function(free) {
			port = free;
			start(script, cwd);
		}, error -> fail('Couldn\'t find a free port for js-debug: $error'));
	}

	/** A port nothing listens on. js-debug says nothing about the port it picks when given 0. **/
	static function freePort():Promise<Int> {
		return new Promise(function(resolve, reject) {
			final probe = Net.createServer();
			probe.on("error", reject);
			probe.listen(0, "127.0.0.1", function() {
				final port:Int = (cast probe.address()).port;
				probe.close(() -> resolve(port));
			});
		});
	}

	function start(script:String, cwd:String) {
		// In a process group of its own, so that stopping it also stops the program it started.
		final server = ProcessTree.spawn(process.execPath, [script, Std.string(port), "127.0.0.1"], {cwd: cwd, windowsHide: true});
		this.serverProcess = server;
		var listening = false;
		final timer = haxe.Timer.delay(() -> if (!listening) fail('js-debug didn\'t start within $startSeconds seconds.'), startSeconds * 1000);
		server.stdout.on("data", function(chunk:Buffer) {
			if (!listening && chunk.toString().indexOf("listening") >= 0) {
				listening = true;
				timer.stop();
				connect(function(connection) {
					root = connection;
					connection.onMessage = fromRoot;
					for (message in early) {
						send(message);
					}
					early.resize(0);
				});
			}
		});
		server.stderr.on("data", (chunk:Buffer) -> process.stderr.write(chunk));
		server.on("error", (error:js.lib.Error) -> fail('Couldn\'t start js-debug: ${error.message}'));
		server.on("close", function(code:Null<Int>, _) {
			if (!closed) {
				Log.info('js-debug exited (code $code)');
				finish();
				close(code ?? 1);
			}
		});
	}

	function connect(connected:Connection->Void) {
		final socket = Net.connect(port, "127.0.0.1");
		socket.on("connect", () -> connected(new Connection(socket, socket)));
		socket.on("error", (error:js.lib.Error) -> Log.info('js-debug connection: ${error.message}'));
	}

	public function send(message:Message) {
		final root = root;
		if (root == null) {
			early.push(message);
			return;
		}
		if (message.type == "response") {
			// Zed's answer to a reverse request js-debug made.
			final origin = reverse.get(message.request_seq);
			if (origin != null) {
				reverse.remove(message.request_seq);
				message.request_seq = origin.seq;
				origin.connection.send(message);
			}
			return;
		}
		final target = childReady ? child : root;
		switch message.command {
			case "initialize":
				initializeArguments = message.arguments;
				root.send(message);
			case "launch":
				launched = true;
				root.send(message);
			case "disconnect" | "terminate" if (!launched):
				// The build failed, and js-debug doesn't answer before a launch.
				onMessage({
					seq: ++seq,
					type: "response",
					request_seq: message.seq,
					command: message.command,
					success: true
				});
				if (message.command == "disconnect") {
					close(0);
				}
			case "setBreakpoints":
				breakpoints.set(message.arguments.source.path, message.arguments);
				target.send(message);
			case "setExceptionBreakpoints":
				exceptionBreakpoints = message.arguments;
				target.send(message);
			case "disconnect" | "terminate":
				// The child session ends with the program; Zed's answer comes from the session it started.
				final child = child;
				if (child != null) {
					request(child, message.command, message.arguments);
				}
				root.send(message);
			case _:
				target.send(message);
		}
	}

	function fromRoot(message:Message) {
		if (consume(message, root)) {
			return;
		}
		if (message.type == "request" && message.command == "startDebugging") {
			answer(root, message);
			if (child == null) {
				startChild(message.arguments);
			}
			return;
		}
		if (message.type == "event" && message.event == "terminated") {
			// With a program session, its own `terminated` comes after the program's last output.
			if (child == null) {
				finish();
			}
			return;
		}
		if (message.type == "response" && message.command == "disconnect") {
			onMessage(message);
			close(0);
			return;
		}
		onMessage(message);
	}

	function fromChild(message:Message) {
		if (consume(message, child)) {
			return;
		}
		if (message.type == "request" && message.command == "startDebugging") {
			// A worker or child process of the program: not debugged here.
			answer(child, message);
			return;
		}
		if (message.type == "event") {
			switch message.event {
				case "initialized":
					// Zed had the root session's.
					return;
				case "terminated":
					finish();
					return;
				case _:
			}
		}
		onMessage(message);
	}

	/** Opens the program's session as js-debug asked, and gives it Zed's configuration. **/
	function startChild(arguments:Dynamic) {
		connect(function(connection) {
			child = connection;
			var initialized:Void->Void = () -> {};
			final ready = new Promise<Any>(function(resolve, _) {
				initialized = () -> resolve(null);
			});
			connection.onMessage = function(message) {
				if (message.type == "event" && message.event == "initialized") {
					initialized();
				}
				fromChild(message);
			};
			request(connection, "initialize", initializeArguments).then(function(_) {
				final launched = request(connection, arguments.request, arguments.configuration);
				return ready.then(_ -> Promise.all([
					for (args in breakpoints)
						request(connection, "setBreakpoints", args)
				])).then(_ -> exceptionBreakpoints == null ? Promise.resolve(null) : request(connection, "setExceptionBreakpoints", exceptionBreakpoints))
					.then(_ -> request(connection, "configurationDone", {}))
					.then(_ -> launched);
			}).then(function(response:Message) {
				if (!response.success) {
					Log.info('js-debug\'s program session didn\'t start: ${response.message}');
				}
				childReady = true;
			});
		});
	}

	/** Sends a request of the bridge's own, whose answer Zed doesn't see. **/
	function request(connection:Connection, command:String, arguments:Dynamic):Promise<Message> {
		return new Promise(function(resolve, _) {
			final message:Message = {seq: ++seq, type: "request", command: command, arguments: arguments};
			own.set(message.seq, resolve);
			Log.message("bridge (to js-debug)", message);
			connection.send(message);
		});
	}

	/** Takes the answers to the bridge's own requests, and passes js-debug's other reverse requests on to Zed. **/
	function consume(message:Message, connection:Connection):Bool {
		if (message.type == "response") {
			final handler = own.get(message.request_seq);
			if (handler != null) {
				own.remove(message.request_seq);
				handler(message);
				return true;
			}
			return false;
		}
		if (message.type == "request" && message.command != "startDebugging") {
			final forwarded = ++seq;
			reverse.set(forwarded, {connection: connection, seq: message.seq});
			message.seq = forwarded;
			onMessage(message);
			return true;
		}
		return false;
	}

	function answer(connection:Connection, request:Message) {
		connection.send({
			seq: ++seq,
			type: "response",
			request_seq: request.seq,
			command: request.command,
			success: true
		});
	}

	/** Tells Zed the session is over, once. **/
	function finish() {
		if (!terminated) {
			terminated = true;
			onMessage({seq: ++seq, type: "event", event: "terminated"});
		}
	}

	function fail(reason:String) {
		Log.info(reason);
		for (message in early) {
			if (message.type == "request") {
				onMessage({
					seq: ++seq,
					type: "response",
					request_seq: message.seq,
					command: message.command,
					success: false,
					message: reason
				});
			}
		}
		early.resize(0);
		close(1);
	}

	function close(code:Int) {
		if (closed) {
			return;
		}
		closed = true;
		kill();
		onClose(code);
	}

	public function kill() {
		if (serverProcess != null) {
			ProcessTree.kill(serverProcess);
		}
	}
}
