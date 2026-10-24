import bridge.dap.BodylessResponses;
import bridge.dap.Filter.Requester;
import bridge.dap.Message;
import bridge.targets.EvalCompletions;
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

	static function event(name:String, threadId:Int):Message {
		return {seq: 1, type: "event", event: name, body: {reason: "breakpoint", threadId: threadId}};
	}

	static function response(command:String, body:Dynamic):Message {
		return {seq: 1, type: "response", request_seq: 1, command: command, success: true, body: body};
	}

	/** Answers `threads` requests with `list`, recording each request's command. **/
	static function threads(requests:Array<String>, list:Array<{id:Int, name:String}>):Requester {
		return function(command, _) {
			requests.push(command);
			return Promise.resolve(response("threads", {threads: list}));
		};
	}
}
