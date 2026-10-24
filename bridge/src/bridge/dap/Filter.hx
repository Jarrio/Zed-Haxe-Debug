package bridge.dap;

import js.lib.Promise;

/** Sends a request of the bridge's own to the debugger and resolves with its response. **/
typedef Requester = (command:String, arguments:Dynamic) -> Promise<Message>;

/** Rewrites a debugger's messages before Zed gets them, to work around that debugger's quirks. **/
interface Filter {
	/**
		Resolves with the message to send on to Zed, or null to drop it. Messages reach Zed in the order
		the debugger sent them.
	**/
	function fromDebugger(message:Message, request:Requester):Promise<Null<Message>>;
}
