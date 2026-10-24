package bridge.dap;

import haxe.Json;
import js.node.Buffer;
import js.node.stream.Readable.IReadable;
import js.node.stream.Writable.IWritable;

/**
	Reads and writes DAP messages, which are framed with `Content-Length` headers like LSP's.
**/
class Connection {
	static final contentLength = ~/Content-Length:\s*(\d+)/i;

	final output:IWritable;
	var buffer:Buffer = Buffer.alloc(0);

	/** Called once per complete incoming message. **/
	public var onMessage:Message->Void = function(_) {};

	public function new(input:IReadable, output:IWritable) {
		this.output = output;
		input.on("data", function(chunk:Buffer) {
			buffer = Buffer.concat([buffer, chunk]);
			drain();
		});
	}

	public function send(message:Message) {
		final body = Buffer.from(Json.stringify(message), "utf8");
		output.write('Content-Length: ${body.length}\r\n\r\n');
		output.write(body);
	}

	function drain() {
		while (true) {
			final headerEnd = buffer.indexOf("\r\n\r\n");
			if (headerEnd < 0) {
				return;
			}
			final header = buffer.toString("ascii", 0, headerEnd);
			if (!contentLength.match(header)) {
				// Not a frame we understand: drop the header and keep going.
				buffer = buffer.slice(headerEnd + 4);
				continue;
			}
			final length = Std.parseInt(contentLength.matched(1));
			final bodyStart = headerEnd + 4;
			if (buffer.length < bodyStart + length) {
				return;
			}
			final body = buffer.toString("utf8", bodyStart, bodyStart + length);
			buffer = buffer.slice(bodyStart + length);
			onMessage(Json.parse(body));
		}
	}
}
