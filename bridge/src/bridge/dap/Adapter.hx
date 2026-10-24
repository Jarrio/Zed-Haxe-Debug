package bridge.dap;

/**
	A debug adapter the session relays Zed's messages to: one of vshaxe's, run with Node (`NodeAdapter`),
	or one written into the bridge (`targets.HxcppAdapter`).
**/
interface Adapter {
	/** Receives every message the adapter sends towards Zed. **/
	var onMessage:Message->Void;

	/** Called when the adapter has finished, with the exit code for the bridge. **/
	var onClose:Int->Void;

	/** Delivers a message from Zed, or a request of the bridge's own. **/
	function send(message:Message):Void;

	/** Stops the adapter and whatever it started. **/
	function kill():Void;
}
