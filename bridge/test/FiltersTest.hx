import bridge.dap.BodylessResponses;
import bridge.dap.Filter.FilterContext;
import bridge.dap.Message;
import bridge.dap.VariableEdits;
import bridge.targets.EvalCompletions;
import bridge.targets.EvalScopes;
import bridge.targets.EvalThreads;
import js.lib.Promise;
import utest.Assert;
import utest.Async;

/** Workarounds for the debuggers' messages. **/
class FiltersTest extends utest.Test {
	function testHaxe5ThreadNumbersBecomeKeys(async:Async) {
		final filter = new EvalThreads();
		final requests = [];
		final request = threads(requests, [{id: 0, name: "Thread 1"}]);
		filter.fromDebugger(event("stopped", 1), request).then(function(message) {
			Assert.equals(0, message.body.threadId);
			Assert.same(["threads"], requests);
			// Once the bridge has seen the list, it doesn't ask again.
			return filter.fromDebugger(event("stopped", 1), request);
		}).then(function(message) {
			Assert.equals(0, message.body.threadId);
			Assert.equals(1, requests.length);
			async.done();
		});
	}

	function testHaxe4ThreadsPassThrough(async:Async) {
		final filter = new EvalThreads();
		filter.fromDebugger(response("threads", {threads: [{id: 0, name: "Thread 0"}]}), threads([], [])).then(function(_) {
			return filter.fromDebugger(event("stopped", 0), threads([], []));
		}).then(function(message) {
			Assert.equals(0, message.body.threadId);
			async.done();
		});
	}

	function testUnknownThreadsAreLeftAlone(async:Async) {
		new EvalThreads().fromDebugger(event("stopped", 7), threads([], [{id: 0, name: "Thread 1"}])).then(function(message) {
			Assert.equals(7, message.body.threadId);
			async.done();
		});
	}

	function testThreadEventsAreDropped(async:Async) {
		final requests = [];
		new EvalThreads().fromDebugger(event("thread", 2), threads(requests, [])).then(function(message) {
			Assert.isNull(message);
			Assert.equals(0, requests.length);
			async.done();
		});
	}

	function testBodylessResponsesLoseTheirBody(async:Async) {
		final filter = new BodylessResponses();
		filter.fromDebugger(response("configurationDone", {allThreadsContinued: false}), threads([], [])).then(function(message) {
			Assert.isFalse(Reflect.hasField(message, "body"));
			return filter.fromDebugger(response("continue", {allThreadsContinued: false}), threads([], []));
		}).then(function(message) {
			Assert.isFalse(message.body.allThreadsContinued);
			async.done();
		});
	}

	function testCompletionsAreTurnedOff(async:Async) {
		new EvalCompletions().fromDebugger(response("initialize", {supportsCompletionsRequest: true}), threads([], [])).then(function(message) {
			Assert.isFalse(message.body.supportsCompletionsRequest);
			async.done();
		});
	}

	function testEvalScopesAreMergedByName(async:Async) {
		final filter = new EvalScopes();
		final scopes = response("scopes", {
			scopes: [
				{name: "Captures", variablesReference: 5},
				{name: "Locals", variablesReference: 3, line: 5, endLine: 14},
				{name: "Locals", variablesReference: 4, line: 2, endLine: 15}
			]
		});
		final asked = [];
		final context = debugger(function(command, args) {
			asked.push(args.variablesReference);
			return response(command, {
				variables: args.variablesReference == 3 ? [variable("x", "2"), variable("inner", "\"i\"")] : [variable("x", "1")]
			});
		});
		filter.fromDebugger(scopes, context).then(function(message) {
			final merged:Array<Dynamic> = message.body.scopes;
			Assert.same(["Captures", "Locals"], merged.map(scope -> scope.name));
			Assert.equals(3, merged[1].variablesReference);
			Assert.equals(2, merged[1].line);
			Assert.equals(15, merged[1].endLine);
			// A scope of its own goes to eval-debugger as it is.
			return filter.fromZed(request(1, "variables", {variablesReference: 5}), context);
		}).then(function(message) {
			Assert.equals("request", message.type);
			return filter.fromZed(request(2, "variables", {variablesReference: 3}), context);
		}).then(function(message) {
			Assert.equals("response", message.type);
			Assert.equals(2, message.request_seq);
			Assert.same([3, 4], asked);
			final variables:Array<Dynamic> = message.body.variables;
			// The shadowed x is the one from the block starting on line 2.
			Assert.same(["x", "inner", "x - line 2"], variables.map(variable -> variable.name));
			return filter.fromZed(request(3, "setVariable", {variablesReference: 3, name: "x - line 2", value: "9"}), context);
		}).then(function(message) {
			Assert.same({variablesReference: 4, name: "x", value: "9"}, message.arguments);
			return filter.fromZed(request(4, "setVariable", {variablesReference: 7, name: "y", value: "9"}), context);
		}).then(function(message) {
			// An object's field: nothing to change.
			Assert.same({variablesReference: 7, name: "y", value: "9"}, message.arguments);
			async.done();
		});
	}

	function testEditedValuesReplaceStaleOnes(async:Async) {
		final filter = new VariableEdits();
		final context = debugger((_, _) -> null);
		filter.fromZed(request(1, "setVariable", {variablesReference: 3, name: "sum", value: "7"}), context).then(function(_) {
			return filter.fromDebugger(answer(1, "setVariable", {value: "7", type: "Int"}), context);
		}).then(function(_) {
			return filter.fromZed(request(2, "variables", {variablesReference: 3}), context);
		}).then(function(_) {
			// The debugger answers with the value from when the program stopped.
			return filter.fromDebugger(answer(2, "variables", {variables: [variable("sum", "5"), variable("greeting", "\"hello\"")]}), context);
		}).then(function(message) {
			final variables:Array<Dynamic> = message.body.variables;
			Assert.same(["7", "\"hello\""], variables.map(variable -> variable.value));
			// Once the program moves on, the debugger's values are current again.
			return filter.fromZed(request(3, "next", {threadId: 0}), context);
		}).then(function(_) {
			return filter.fromZed(request(4, "variables", {variablesReference: 3}), context);
		}).then(function(_) {
			return filter.fromDebugger(answer(4, "variables", {variables: [variable("sum", "5")]}), context);
		}).then(function(message) {
			Assert.equals("5", message.body.variables[0].value);
			async.done();
		});
	}

	function testRefusedEditsAreReported(async:Async) {
		final filter = new VariableEdits();
		final told:Array<Message> = [];
		final context:FilterContext = {request: (_, _) -> null, tell: message -> told.push(message)};
		filter.fromZed(request(1, "setVariable", {variablesReference: 3, name: "x", value: "1"}), context).then(function(_) {
			final refused:Message = {seq: 1, type: "response", request_seq: 1, command: "setVariable", success: false, message: "not here"};
			return filter.fromDebugger(refused, context);
		}).then(function(message) {
			Assert.isFalse(message.success);
			Assert.equals(1, told.length);
			Assert.equals("Couldn't change x: not here\n", told[0].body.output);
			// Success without a value: nothing changed.
			return filter.fromZed(request(2, "setVariable", {variablesReference: 3, name: "s", value: "\"bye\""}), context);
		}).then(function(_) {
			return filter.fromDebugger({seq: 2, type: "response", request_seq: 2, command: "setVariable", success: true}, context);
		}).then(function(_) {
			Assert.equals("Couldn't change s: the debugger can't make the value \"bye\"\n", told[1].body.output);
			async.done();
		});
	}

	static function request(seq:Int, command:String, args:Dynamic):Message {
		return {seq: seq, type: "request", command: command, arguments: args};
	}

	static function answer(requestSeq:Int, command:String, body:Dynamic):Message {
		return {seq: 100 + requestSeq, type: "response", request_seq: requestSeq, command: command, success: true, body: body};
	}

	static function variable(name:String, value:String):Dynamic {
		return {name: name, value: value, variablesReference: 0};
	}

	/** A context whose requests `answer` responds to. **/
	static function debugger(answer:(command:String, args:Dynamic) -> Message):FilterContext {
		return {request: (command, args) -> Promise.resolve(answer(command, args)), tell: _ -> {}};
	}

	static function event(name:String, threadId:Int):Message {
		return {seq: 1, type: "event", event: name, body: {reason: "breakpoint", threadId: threadId}};
	}

	static function response(command:String, body:Dynamic):Message {
		return {seq: 1, type: "response", request_seq: 1, command: command, success: true, body: body};
	}

	/** Answers `threads` requests with `list`, recording each request's command. **/
	static function threads(requests:Array<String>, list:Array<{id:Int, name:String}>):FilterContext {
		return debugger(function(command, _) {
			requests.push(command);
			return response("threads", {threads: list});
		});
	}
}
