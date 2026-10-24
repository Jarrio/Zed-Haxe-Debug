package bridge;

import bridge.dap.Message;
import haxe.Json;
import js.Node.process;
import sys.io.File;

/**
	Logging goes to stderr, which Zed shows in the debug adapter log.
	stdout is reserved for DAP messages, so `trace` must never print there.
**/
class Log {
	/** When set, every message passing through the bridge is appended to this file. **/
	public static var traceFile:Null<String>;

	public static function info(message:String) {
		process.stderr.write('[haxe-debug] $message\n');
	}

	public static function message(direction:String, message:Message) {
		final file = traceFile;
		if (file == null) {
			return;
		}
		try {
			final output = File.append(file, false);
			output.writeString('${Date.now().toString()} $direction ${Json.stringify(message)}\n');
			output.close();
		} catch (e) {
			info('could not write trace file $file: $e');
			traceFile = null;
		}
	}

	/** Routes Haxe's `trace` to stderr. **/
	public static function install() {
		haxe.Log.trace = function(value, ?infos) {
			info(haxe.Log.formatOutput(value, infos));
		};
	}
}
