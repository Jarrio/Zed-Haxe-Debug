package bridge.targets;

import haxe.Json;
import js.lib.Promise;
import js.node.Buffer;
import js.node.net.Socket;

/**
	The connection to hxcpp-debug-server inside the program. Each message is JSON after its length in
	bytes, as a little-endian 32-bit integer. Requests carry an `id`, which the answer repeats, with a
	`result` or an `error`; notifications have only `method` and `params`.
	The requests and notifications are listed in the library's `hxcpp/debug/jsonrpc/Protocol.hx`.
**/
class HxcppServer {
	final socket:Socket;
	var buffer:Buffer = Buffer.alloc(0);
	var nextId = 1;
	final pending:Map<Int, {resolve:Dynamic->Void, reject:String->Void}> = [];

	public var onNotification:(method:String, params:Dynamic) -> Void = (_, _) -> {};

	/** Called once the connection has closed, usually because the program exited. **/
	public var onClose:() -> Void = () -> {};

	public function new(socket:Socket) {
		this.socket = socket;
		socket.on("data", function(chunk:Buffer) {
			buffer = Buffer.concat([buffer, chunk]);
			drain();
		});
		socket.on("error", (error:js.lib.Error) -> Log.info('debug server connection: ${error.message}'));
		socket.on("close", function(_) {
			for (callbacks in pending) {
				callbacks.reject("The program's debug server disconnected.");
			}
			pending.clear();
			onClose();
		});
	}

	/** Resolves with the request's result, or rejects with the server's error message. **/
	public function request(method:String, params:Dynamic):Promise<Dynamic> {
		return new Promise(function(resolve, reject) {
			final message = {id: nextId++, method: method, params: params};
			pending.set(message.id, {resolve: resolve, reject: reject});
			Log.message("bridge (to the debug server)", cast message);
			final body = Buffer.from(Json.stringify(message), "utf8");
			final header = Buffer.alloc(4);
			header.writeInt32LE(body.length, 0);
			socket.write(Buffer.concat([header, body]));
		});
	}

	public function close() {
		socket.destroy();
	}

	function drain() {
		while (buffer.length >= 4) {
			final length = buffer.readInt32LE(0);
			if (buffer.length < 4 + length) {
				return;
			}
			final message:Dynamic = Json.parse(buffer.toString("utf8", 4, 4 + length));
			buffer = buffer.slice(4 + length);
			Log.message("debug server", message);
			if (message.id == null) {
				onNotification(message.method, message.params);
				continue;
			}
			final callbacks = pending.get(message.id);
			if (callbacks != null) {
				pending.remove(message.id);
				if (message.error != null) {
					callbacks.reject(message.error.message);
				} else {
					callbacks.resolve(message.result);
				}
			}
		}
	}
}
