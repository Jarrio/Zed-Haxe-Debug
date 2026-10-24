package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.lib.Promise;

/**
	Haxe 5's eval ends its debugger thread on a `completions` request ("Thread_local_storage.Not_set"),
	and then nothing answers any more. Zed sends one for every key typed in the debug console, so the
	bridge tells Zed this debugger has no completions.
**/
class EvalCompletions implements Filter {
	public function new() {}

	public function fromDebugger(message:Message, request:Requester):Promise<Null<Message>> {
		if (message.type == "response" && message.command == "initialize" && message.body != null) {
			message.body.supportsCompletionsRequest = false;
		}
		return Promise.resolve(message);
	}
}
