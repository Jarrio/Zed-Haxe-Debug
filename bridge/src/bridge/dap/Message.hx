package bridge.dap;

/**
	A Debug Adapter Protocol message (https://microsoft.github.io/debug-adapter-protocol/specification).

	Requests have `command` and `arguments`; responses have `request_seq`, `command`, `success` and
	`body` or `message`; events have `event` and `body`.
**/
typedef Message = {
	var seq:Int;

	/** `"request"`, `"response"` or `"event"`. **/
	var type:String;

	var ?command:String;
	var ?arguments:Dynamic;
	var ?request_seq:Int;
	var ?success:Bool;
	var ?message:String;
	var ?body:Dynamic;
	var ?event:String;
}
