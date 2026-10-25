package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.Node.process;
import js.lib.Promise;

/**
	A HashLink program killed by a signal ends with no exit code and no word why, which looks like the
	debugger crashing. The bridge says what happened, unless the session was being stopped, which ends
	the VM the same way. On Linux the usual cause is a breakpoint that a thread other than the main one
	reaches: HashLink's debugger traces only the main thread, so the trap ends the program.
**/
class HashLinkSignal extends Filter {
	/** Zed asked for the session to end, so the VM is stopped on purpose. **/
	var stopping = false;

	public function new() {
		super();
	}

	override public function fromZed(message:Message, context:FilterContext):Promise<Message> {
		if (message.type == "request" && ["disconnect", "terminate", "restart"].contains(message.command)) {
			stopping = true;
		}
		return Promise.resolve(message);
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (!stopping && message.type == "event" && message.event == "exited" && message.body?.exitCode == null) {
			final why = process.platform == "linux"
				? " It crashed, or a thread other than the main one reached a breakpoint: on Linux, HashLink's debugger only follows the main thread, and a breakpoint in another one ends the program."
				: " It crashed, or something else stopped it.";
			context.tell({
				seq: 0,
				type: "event",
				event: "output",
				body: {category: "stderr", output: 'The program was killed by a signal, so it has no exit code.$why\n'}
			});
		}
		return Promise.resolve(message);
	}
}
