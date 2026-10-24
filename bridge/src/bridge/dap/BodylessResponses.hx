package bridge.dap;

import bridge.dap.Filter;
import js.lib.Promise;

/**
	Drops the body of responses the protocol defines without one. Zed reads those responses strictly and
	fails on any body ("invalid type: map, expected unit"); eval-debugger, for one, answers
	`configurationDone` with `{"allThreadsContinued": false}`.
**/
class BodylessResponses extends Filter {
	static final commands = [
		"attach", "launch", "configurationDone", "disconnect", "terminate", "restart", "next", "stepIn", "stepOut", "stepBack",
		"reverseContinue", "restartFrame", "goto", "pause", "terminateThreads", "cancel"
	];

	public function new() {
		super();
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "response" && message.body != null && commands.contains(message.command)) {
			Reflect.deleteField(message, "body");
		}
		return Promise.resolve(message);
	}
}
