package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.lib.Promise;

/**
	Haxe 5's eval gives each thread two numbers. `threads` lists a thread under its key in the compiler's
	table of threads (0 for the main thread) and names it after its own thread number ("Thread 1"), but
	stop and thread events carry that number, while requests such as `stackTrace` only accept the key.
	So an event's thread is looked up by name and rewritten to its key. In Haxe 4 the name holds the key,
	so nothing changes.

	Thread events are dropped. Haxe 5's eval starts a short-lived thread to print each value Zed asks for,
	and every thread event makes Zed fetch the threads, stack and variables again, which starts more
	threads. Zed lists the threads again whenever the program stops, which is when they matter.
**/
class EvalThreads extends Filter {
	/** Keys of the threads, by name, from the latest thread list. **/
	final keys:Map<String, Int> = [];

	public function new() {
		super();
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "response" && message.command == "threads" && message.success == true) {
			learn(message);
		}
		if (message.type == "event" && message.event == "thread") {
			return Promise.resolve(null);
		}
		final threadId:Null<Int> = message.type == "event" ? message.body?.threadId : null;
		if (threadId == null) {
			return Promise.resolve(message);
		}
		final name = 'Thread $threadId';
		if (keys.exists(name)) {
			message.body.threadId = keys.get(name);
			return Promise.resolve(message);
		}
		// A thread the bridge hasn't seen listed yet (the first stop, or a new thread).
		return context.request("threads", {}).then(function(response) {
			learn(response);
			if (keys.exists(name)) {
				message.body.threadId = keys.get(name);
			}
			return message;
		});
	}

	function learn(response:Message) {
		final threads:Null<Array<{id:Int, name:String}>> = response.body?.threads;
		if (threads == null) {
			return;
		}
		keys.clear();
		for (thread in threads) {
			keys.set(thread.name, thread.id);
		}
	}
}
