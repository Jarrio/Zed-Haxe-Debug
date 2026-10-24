package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.lib.Promise;

/**
	hashlink-debugger sends the program's output up to 400 ms after it comes (it waits for whole lines),
	but `terminated` as soon as the VM exits, so the program's last lines arrived after the session had
	ended. The bridge sends `terminated` half a second later, after them.
**/
class HashLinkOutput extends Filter {
	static inline final delay = 500;

	public function new() {
		super();
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "event" && message.event == "terminated") {
			haxe.Timer.delay(() -> context.tell(message), delay);
			return Promise.resolve(null);
		}
		return Promise.resolve(message);
	}
}
