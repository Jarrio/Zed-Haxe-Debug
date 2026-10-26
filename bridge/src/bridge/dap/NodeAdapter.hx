package bridge.dap;

import bridge.dap.Adapter;
import bridge.util.ProcessTree;
import js.Node.process;
import js.node.Buffer;

/**
	A debug adapter written for Node, such as eval-debugger: `node <script>`, speaking DAP over stdio. It
	runs in a process group of its own, so that stopping it also stops what it started, such as the Haxe
	that eval-debugger runs.
**/
class NodeAdapter implements Adapter {
	public var onMessage:Message->Void = _ -> {};
	public var onClose:(code:Int, ended:Null<ProcessEnd>) -> Void = (_, _) -> {};

	final child:js.node.child_process.ChildProcess;
	final connection:Connection;
	final errors = new ErrorOutput();

	public function new(script:String, cwd:String) {
		child = ProcessTree.spawn(process.execPath, [script], {cwd: cwd, windowsHide: true});
		connection = new Connection(child.stdout, child.stdin);
		connection.onMessage = message -> onMessage(message);
		child.stderr.on("data", function(chunk:Buffer) {
			process.stderr.write(chunk);
			errors.add(chunk.toString());
		});
		// A process that can't start may report both.
		var closed = false;
		child.on("error", function(error:js.lib.Error) {
			Log.info('could not start the debugger: ${error.message}');
			if (!closed) {
				closed = true;
				onClose(1, {code: null, signal: null, errors: error.message});
			}
		});
		// "close" rather than "exit": the debugger's last messages may still be unread when it exits.
		child.on("close", function(code:Null<Int>, signal:Null<String>) {
			Log.info('the debugger exited (${code != null ? 'code $code' : signal})');
			if (!closed) {
				closed = true;
				onClose(code ?? 1, {code: code, signal: signal, errors: errors.tail()});
			}
		});
	}

	public function send(message:Message) {
		connection.send(message);
	}

	public function kill() {
		ProcessTree.kill(child);
	}
}
