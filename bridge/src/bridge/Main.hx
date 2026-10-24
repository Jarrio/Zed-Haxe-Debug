package bridge;

import bridge.Plan;
import bridge.Settings.ProjectSettings;
import haxe.Json;
import js.Node.process;

/**
	`node bridge.js --config <JSON> [--project <JSON>] [--eval <eval-debugger's index.js>]
	[--hxcpp-debug-server <folder>] [--hashlink <hashlink-debugger's adapter.js>]
	[--js-debug <js-debug's dapDebugServer.js>] [--trace <file>]`

	Zed starts this as the debug adapter, in the workspace folder. `--config` is the debug configuration
	and `--project` is Zed-Haxe's `project` settings. The bridge works out the session before Zed's first
	message, because DAP's `initialize` already goes to the debugger, before `launch` says what to debug.
**/
class Main {
	static function main() {
		Log.install();
		process.on("uncaughtException", (error:Dynamic) -> Log.info('internal error: ${error?.stack ?? error}'));
		process.on("unhandledRejection", (reason:Dynamic) -> Log.info('internal error: ${reason?.stack ?? reason}'));
		final args = process.argv.slice(2);
		var config:LaunchConfig = {};
		var settings:ProjectSettings = {};
		final adapters:Adapters = {};
		var i = 0;
		while (i < args.length) {
			switch args[i] {
				case "--config":
					config = Json.parse(args[++i]);
				case "--project":
					settings = Json.parse(args[++i]);
				case "--eval":
					adapters.eval = args[++i];
				case "--hxcpp-debug-server":
					adapters.hxcppDebugServer = args[++i];
				case "--hashlink":
					adapters.hashlink = args[++i];
				case "--js-debug":
					adapters.jsDebug = args[++i];
				case "--trace":
					Log.traceFile = args[++i];
				case other:
					Log.info('ignoring unknown argument $other');
			}
			i++;
		}
		var plan:Null<Plan> = null;
		var error:Null<String> = null;
		try {
			plan = Planner.plan(config, settings, adapters, process.cwd(), process.env);
		} catch (e:LaunchError) {
			error = e.message;
			Log.info(error);
		}
		new Session(plan, error);
	}
}
