package bridge;

import bridge.Plan;
import bridge.dap.Adapter;
import bridge.dap.Connection;
import bridge.dap.Filter;
import bridge.dap.Message;
import bridge.dap.NodeAdapter;
import bridge.targets.HxcppAdapter;
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

	/** Sequence numbers of the messages the bridge sends Zed itself. **/
	var seq = 0;

	/** Sequence numbers of the bridge's own requests to the debugger, far above Zed's. **/
	var requestSeq = 1000000000;

	/** Answers to the bridge's own requests, which Zed never sees. **/
	final ownRequests:Map<Int, Message->Void> = [];

	/** The debugger's messages, each waiting for the ones before it to reach Zed. **/
	var queue:Promise<Any> = Promise.resolve(null);

	public function new(plan:Null<Plan>, error:Null<String>) {
		this.plan = plan;
		this.error = error ?? "The Haxe debugger could not start.";
		zed = new Connection(process.stdin, process.stdout);
		zed.onMessage = fromZed;
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
		};
		debugger.onMessage = function(message) {
			Log.message("debugger", message);
			final answer = message.type == "response" ? ownRequests.get(message.request_seq) : null;
			if (answer != null) {
				ownRequests.remove(message.request_seq);
				answer(message);
				return;
			}
			queue = queue.then(_ -> adjust(message, plan.filters)).catchError(function(error) {
				Log.info('could not adjust a message from the debugger: $error');
				return message;
			}).then(function(adjusted) {
				if (adjusted != null) {
					zed.send(adjusted);
				}
			});
		};
		debugger.onClose = function(code) {
			for (seq => answer in ownRequests) {
				answer({seq: 0, type: "response", request_seq: seq, success: false, message: "the debugger exited"});
			}
			ownRequests.clear();
			queue.then(_ -> exit(code));
		};
		this.debugger = debugger;
	}

	/** Passes a message from the debugger through each filter in turn; null when one drops it. **/
	function adjust(message:Message, filters:Array<Filter>):Promise<Null<Message>> {
		var result:Promise<Null<Message>> = Promise.resolve(message);
		for (filter in filters) {
			result = result.then(adjusted -> adjusted == null ? Promise.resolve(null) : filter.fromDebugger(adjusted, requestDebugger));
		}
		return result;
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
		final debugger = debugger;
		if (debugger == null) {
			answer(message);
			return;
		}
		if (message.type == "request" && message.command == "launch") {
			message.arguments = plan.arguments;
			Log.message("bridge (launch as sent to the debugger)", message);
		}
		debugger.send(message);
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
		debugger?.kill();
		// Let stdout drain first, or Zed may miss the last messages.
		process.stdout.write("", () -> process.exit(code));
	}
}
