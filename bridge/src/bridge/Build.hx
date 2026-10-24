package bridge;

import bridge.util.Exec;
import haxe.DynamicAccess;
import js.Node.process;
import js.lib.Promise;
import js.node.ChildProcess;

typedef HaxeRun = {
	final executable:String;
	final args:Array<String>;
	final cwd:String;

	/** Added to the bridge's environment. **/
	final env:DynamicAccess<String>;
}

/** Builds the program for debuggers that don't, showing Haxe's output in the debug console. **/
@:access(bridge.util.Exec)
class Build {
	static final running:Array<js.node.child_process.ChildProcess> = [];
	static var stopped = false;

	/**
		Runs Haxe and passes on its output as it comes. Rejects with a message for the user. `hidden` are
		arguments of the bridge's own, added to the build but not to the command it shows.
	**/
	public static function run(run:HaxeRun, output:String->Void, ?hidden:Array<String>):Promise<Any> {
		return new Promise(function(resolve, reject) {
			final env = environment(run.env);
			env.set("HXCPP_NO_COLOR", "1");
			final start = Exec.prepare(run.executable, run.args.concat(hidden ?? []), {cwd: run.cwd, env: env});
			if (start == null) {
				reject('Haxe (${run.executable}) was not found.');
				return;
			}
			output('Building: ${commandLine(run.executable, run.args)}\n');
			final started = Date.now().getTime();
			final child = ChildProcess.spawn(start.file, start.args, cast {
				cwd: run.cwd,
				env: env,
				windowsHide: true,
				windowsVerbatimArguments: start.verbatim
			});
			running.push(child);
			final errors = [];
			child.stdout.setEncoding("utf8");
			child.stderr.setEncoding("utf8");
			child.stdout.on("data", (text:String) -> output(text));
			child.stderr.on("data", function(text:String) {
				errors.push(text);
				output(text);
			});
			child.on("error", (error:js.lib.Error) -> reject('Couldn\'t run ${run.executable}: ${error.message}'));
			child.on("close", function(code:Null<Int>, signal:Null<String>) {
				running.remove(child);
				if (stopped) {
					reject("The session ended during the build.");
				} else if (code == 0) {
					output('Built in ${Math.round((Date.now().getTime() - started) / 100) / 10} s.\n');
					resolve(null);
				} else {
					final lines = [for (line in errors.join("").split("\n")) if (StringTools.trim(line) != "") StringTools.trim(line)];
					reject('The build failed (${exitStatus(code, signal)})${lines.length > 0 ? ": " + lines.slice(0, 3).join("\n") : "."}');
				}
			});
		});
	}

	/** Stops any build still running, when the session ends. **/
	public static function stopAll() {
		stopped = true;
		for (child in running) {
			child.kill();
		}
	}

	/** The bridge's environment with `extra` added. **/
	public static function environment(extra:DynamicAccess<String>):DynamicAccess<String> {
		final env:DynamicAccess<String> = (cast process.env : DynamicAccess<String>).copy();
		for (name => value in extra) {
			env.set(name, value);
		}
		return env;
	}

	public static function commandLine(executable:String, args:Array<String>):String {
		return [for (arg in [executable].concat(args)) arg.indexOf(" ") >= 0 ? '"$arg"' : arg].join(" ");
	}

	public static function exitStatus(code:Null<Int>, signal:Null<String>):String {
		return code != null ? 'exit code $code' : 'signal $signal';
	}
}
