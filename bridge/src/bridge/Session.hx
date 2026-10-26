package bridge;

import bridge.Plan;
import bridge.dap.Adapter;
import bridge.dap.Connection;
import bridge.dap.Filter;
import bridge.dap.Message;
import bridge.dap.NodeAdapter;
import bridge.dap.VariableEdits;
import bridge.targets.HxcppAdapter;
import bridge.targets.JsDebugAdapter;
import js.Node.process;
import js.lib.Promise;

/**
	One debug session. Zed talks DAP with the bridge over stdin and stdout. The bridge starts the debugger
	the plan picked and relays every message both ways, replacing only the arguments of `launch` with the
	ones the plan worked out. Without a plan (the project couldn't be resolved), the bridge answers Zed
	itself, so the reason shows up as the launch error.
**/
class Session {
	final zed:Connection;
	final plan:Null<Plan>;
	final error:String;
	var debugger:Null<Adapter>;
	var exiting = false;

	/** Zed asked for the session to end, or the debugger said it had ended. **/
	var finished = false;

	/** Sequence numbers of the messages the bridge sends Zed itself. **/
	var seq = 0;

	/** Sequence numbers of the bridge's own requests to the debugger, far above Zed's. **/
	var requestSeq = 1000000000;

	/** Answers to the bridge's own requests, which Zed never sees. **/
	final ownRequests:Map<Int, Message->Void> = [];

	/** The debugger's messages, each waiting for the ones before it to reach Zed. **/
	var queue:Promise<Any> = Promise.resolve(null);

	/** Zed's messages, each waiting for the ones before it to reach the debugger. **/
	var outgoing:Promise<Any> = Promise.resolve(null);

	/** The plan's filters, then the ones every debugger gets, from the debugger's side to Zed's. **/
	var filters:Array<Filter> = [];

	final context:FilterContext;

	public function new(plan:Null<Plan>, error:Null<String>) {
		this.plan = plan;
		this.error = error ?? "The Haxe debugger could not start.";
		zed = new Connection(process.stdin, process.stdout);
		zed.onMessage = fromZed;
		context = {request: requestDebugger, tell: tell};
		process.stdin.on("end", () -> exit(0));
		if (plan != null) {
			start(plan);
		}
	}

	function start(plan:Plan) {
		Log.info('starting the ${plan.target} debugger in ${plan.cwd}');
		final debugger:Adapter = switch plan.adapter {
			case Node(script): new NodeAdapter(script, plan.cwd);
			case OwnHxcpp: new HxcppAdapter();
			case JsDebug(script): new JsDebugAdapter(script, plan.cwd);
		};
		filters = plan.filters.concat([new VariableEdits()]);
		debugger.onMessage = function(message) {
			Log.message("debugger", message);
			if (message.type == "event" && message.event == "terminated") {
				finished = true;
			}
			final answer = message.type == "response" ? ownRequests.get(message.request_seq) : null;
			if (answer != null) {
				ownRequests.remove(message.request_seq);
				answer(message);
				return;
			}
			toZed(message, 0);
		};
		debugger.onClose = function(code, ended) {
			for (seq => answer in ownRequests) {
				answer({seq: 0, type: "response", request_seq: seq, success: false, message: "the debugger exited"});
			}
			ownRequests.clear();
			if (ended != null && !finished && !exiting) {
				// Otherwise Zed would only see the adapter gone, and the reason would stay in its adapter log.
				final why = unexpectedEnd(debuggerName(plan.target), ended);
				Log.info(why);
				tell({seq: 0, type: "event", event: "output", body: {category: "stderr", output: why}});
				tell({seq: 0, type: "event", event: "terminated"});
			}
			queue.then(_ -> exit(code));
		};
		this.debugger = debugger;
	}

	static function debuggerName(target:String):String {
		return switch target {
			case "eval": "eval-debugger";
			case "hl": "hashlink-debugger";
			case "js": "js-debug";
			case other: 'The $other debugger';
		}
	}

	/** What the debug console says when the debugger's process ends while the session is still going. **/
	static function unexpectedEnd(name:String, ended:ProcessEnd):String {
		final what = ended.code != null ? '$name stopped unexpectedly, with exit code ${ended.code}.' : ended.signal != null ? '$name stopped unexpectedly, killed by ${ended.signal}.' : '$name couldn\'t start.';
		return ended.errors == "" ? '$what\n' : '$what Its last error output:\n${ended.errors}\n';
	}

	/**
		Passes a message from the debugger, or a filter's answer to Zed, through the filters from `first`
		on, then sends it to Zed after the messages before it.
	**/
	function toZed(message:Message, first:Int) {
		queue = queue.then(_ -> adjust(message, first)).catchError(function(error) {
			Log.info('could not adjust a message from the debugger: $error');
			return message;
		}).then(function(adjusted) {
			if (adjusted != null) {
				zed.send(adjusted);
			}
		});
	}

	/** Passes a message from the debugger through the filters from `first` on; null when one drops it. **/
	function adjust(message:Message, first:Int):Promise<Null<Message>> {
		var result:Promise<Null<Message>> = Promise.resolve(message);
		for (index in first...filters.length) {
			final filter = filters[index];
			result = result.then(adjusted -> adjusted == null ? Promise.resolve(null) : filter.fromDebugger(adjusted, context));
		}
		return result;
	}

	/**
		Passes a message from Zed through the filters, from Zed's side, and resolves with the message for
		the debugger, or null when a filter answered it.
	**/
	function adjustFromZed(message:Message):Promise<Null<Message>> {
		function through(index:Int, message:Message):Promise<Null<Message>> {
			if (index < 0) {
				return Promise.resolve(message);
			}
			return filters[index].fromZed(message, context).then(function(result) {
				if (message.type == "request" && result.type == "response") {
					toZed(result, index + 1);
					return null;
				}
				return through(index - 1, result);
			});
		}
		return through(filters.length - 1, message);
	}

	/** Sends the debugger a request of the bridge's own. Without an answer in 5 seconds, resolves with a failure. **/
	function requestDebugger(command:String, arguments:Dynamic):Promise<Message> {
		return new Promise(function(resolve, _) {
			final request:Message = {seq: ++requestSeq, type: "request", command: command, arguments: arguments};
			ownRequests.set(request.seq, resolve);
			haxe.Timer.delay(function() {
				if (ownRequests.remove(request.seq)) {
					resolve({seq: 0, type: "response", request_seq: request.seq, command: command, success: false, message: "no answer"});
				}
			}, 5000);
			Log.message("bridge", request);
			debugger.send(request);
		});
	}

	function fromZed(message:Message) {
		Log.message("zed", message);
		if (message.type == "request" && ["disconnect", "terminate", "restart"].contains(message.command)) {
			finished = true;
		}
		final debugger = debugger;
		if (debugger == null) {
			answer(message);
			return;
		}
		outgoing = outgoing.then(_ -> adjustFromZed(message)).catchError(function(error) {
			Log.info('could not adjust a message from Zed: $error');
			return message;
		}).then(function(adjusted:Null<Message>) {
			if (adjusted != null) {
				toDebugger(adjusted, debugger);
			}
		});
	}

	/** Sends the debugger a message from Zed, building the program first when it's `launch`. **/
	function toDebugger(message:Message, debugger:Adapter) {
		if (message.type == "request" && message.command == "launch") {
			final prelaunch = plan.prelaunch;
			if (prelaunch != null) {
				prelaunch.run(text -> send({seq: 0, type: "event", event: "output", body: {category: "console", output: text}}))
					.then(function(arguments) {
						launch(message, arguments, debugger);
					}, function(error:Dynamic) {
						respond(message, null, Std.string(error));
						send({seq: 0, type: "event", event: "terminated"});
					});
				return;
			}
			launch(message, plan.arguments, debugger);
			return;
		}
		debugger.send(message);
	}

	/** Sends the debugger `launch` with the arguments the plan worked out. **/
	function launch(request:Message, arguments:Dynamic, debugger:Adapter) {
		request.arguments = arguments;
		Log.message("bridge (launch as sent to the debugger)", request);
		debugger.send(request);
	}

	/** Without a debugger, `initialize` succeeds so that Zed goes on to `launch`, which fails with the reason. **/
	function answer(request:Message) {
		if (request.type != "request") {
			return;
		}
		switch request.command {
			case "initialize":
				respond(request, {supportsConfigurationDoneRequest: true});
			case "launch" | "attach":
				respond(request, null, error);
				send({seq: 0, type: "event", event: "terminated"});
			case "disconnect" | "terminate":
				respond(request);
				exit(0);
			case _:
				respond(request, null, "No debugger is running.");
		}
	}

	/** Answers `request`: successfully with `body`, or with the `failure` message. **/
	function respond(request:Message, ?body:Dynamic, ?failure:String) {
		final response:Message = {
			seq: 0,
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
		send(response);
	}

	/** Sends Zed a message of a filter's, after the messages already on their way. **/
	function tell(message:Message) {
		queue = queue.then(function(_) {
			send(message);
			return null;
		});
	}

	function send(message:Message) {
		message.seq = ++seq;
		Log.message("bridge", message);
		zed.send(message);
	}

	function exit(code:Int) {
		if (exiting) {
			return;
		}
		exiting = true;
		Build.stopAll();
		debugger?.kill();
		// Let stdout drain first, or Zed may miss the last messages.
		process.stdout.write("", () -> process.exit(code));
	}
}
