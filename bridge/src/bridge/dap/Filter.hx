package bridge.dap;

import js.lib.Promise;

/** Sends a request of the bridge's own to the debugger and resolves with its response. **/
typedef Requester = (command:String, arguments:Dynamic) -> Promise<Message>;

/** What a filter can do besides passing messages on. **/
typedef FilterContext = {
	final request:Requester;

	/** Sends Zed a message of the bridge's own, such as an output event. **/
	final tell:Message->Void;
}

/**
	Rewrites the messages between Zed and a debugger, to work around that debugger's quirks. A session's
	filters are listed from the debugger's side to Zed's: the debugger's messages pass through them in
	that order, and Zed's in the other.
**/
class Filter {
	public function new() {}

	/**
		Resolves with the message to send on to Zed, or null to drop it. Messages reach Zed in the order
		the debugger sent them.
	**/
	public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		return Promise.resolve(message);
	}

	/**
		Resolves with the message to send on to the debugger, or with a response to answer the request
		with instead, which passes through the filters on Zed's side of this one.
	**/
	public function fromZed(message:Message, context:FilterContext):Promise<Message> {
		return Promise.resolve(message);
	}
}
