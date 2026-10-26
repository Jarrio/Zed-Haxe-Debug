package bridge.dap;

/**
	A debug adapter the session relays Zed's messages to: one of vshaxe's, run with Node (`NodeAdapter`),
	or one written into the bridge (`targets.HxcppAdapter`).
**/
interface Adapter {
	/** Receives every message the adapter sends towards Zed. **/
	var onMessage:Message->Void;

	/**
		Called when the adapter has finished, with the exit code for the bridge, and how the debugger's own
		process ended when it ran as one.
	**/
	var onClose:(code:Int, ended:Null<ProcessEnd>) -> Void;

	/** Delivers a message from Zed, or a request of the bridge's own. **/
	function send(message:Message):Void;

	/** Stops the adapter and whatever it started. **/
	function kill():Void;
}

/** How a debugger's process ended: its exit code or the signal that killed it, and the end of its error output. **/
typedef ProcessEnd = {
	final code:Null<Int>;
	final signal:Null<String>;
	final errors:String;
}

/** The last few thousand characters a process wrote to stderr, which say why it stopped when it crashes. **/
class ErrorOutput {
	static inline final limit = 4000;

	var text = "";

	public function new() {}

	public function add(chunk:String) {
		text += chunk;
		if (text.length > limit * 2) {
			text = text.substr(-limit);
		}
	}

	/** The end of the output, starting at a whole line. **/
	public function tail():String {
		if (text.length <= limit) {
			return StringTools.trim(text);
		}
		final end = text.substr(-limit);
		final newline = end.indexOf("\n");
		return StringTools.trim(newline < 0 ? end : end.substr(newline + 1));
	}
}
