package bridge.dap;

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
	public var onClose:Int->Void = _ -> {};

	final child:js.node.child_process.ChildProcess;
	final connection:Connection;

	public function new(script:String, cwd:String) {
		child = ProcessTree.spawn(process.execPath, [script], {cwd: cwd, windowsHide: true});
		connection = new Connection(child.stdout, child.stdin);
		connection.onMessage = message -> onMessage(message);
		child.stderr.on("data", (chunk:Buffer) -> process.stderr.write(chunk));
		child.on("error", function(error:js.lib.Error) {
			Log.info('could not start the debugger: ${error.message}');
			onClose(1);
		});
		// "close" rather than "exit": the debugger's last messages may still be unread when it exits.
		child.on("close", function(code:Null<Int>, signal:Null<String>) {
			Log.info('the debugger exited (${code != null ? 'code $code' : signal})');
			onClose(code ?? 1);
		});
	}

	public function send(message:Message) {
		connection.send(message);
	}

	public function kill() {
		ProcessTree.kill(child);
	}
}
