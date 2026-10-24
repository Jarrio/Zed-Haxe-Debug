package bridge.util;

import js.Node.process;
import js.node.ChildProcess;

/**
	A process together with the ones it starts, such as `lime test` and the game it builds and runs:
	stopping the first alone would leave the game running.
**/
class ProcessTree {
	/** Spawns `file` with `args` in a process group of its own (on Windows, `kill` finds the tree by itself). **/
	public static function spawn(file:String, args:Array<String>, options:Dynamic):js.node.child_process.ChildProcess {
		if (process.platform != "win32") {
			options.detached = true;
		}
		return ChildProcess.spawn(file, args, options);
	}

	/** Stops the process and everything it started. **/
	public static function kill(child:js.node.child_process.ChildProcess) {
		final pid = child.pid;
		if (pid == null) {
			return;
		}
		if (process.platform == "win32") {
			ChildProcess.spawn("taskkill", ["/pid", Std.string(pid), "/T", "/F"], cast {windowsHide: true, stdio: "ignore"});
			return;
		}
		try {
			process.kill(-pid, "SIGTERM");
		} catch (_) {
			child.kill();
		}
	}
}
