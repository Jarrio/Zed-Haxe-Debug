package bridge.util;

import haxe.DynamicAccess;
import js.Node.process;
import js.lib.Error;
import js.lib.Promise;
import js.node.Buffer;
import js.node.ChildProcess;

typedef ExecOptions = {
	/** Working directory of the command. **/
	var cwd:String;

	/** Full environment of the command. **/
	var env:DynamicAccess<String>;

	/** Replacements for the executable, keyed by its name (see `ProjectSettings.commands`). **/
	var ?aliases:DynamicAccess<String>;

	/** Milliseconds before the command is killed. Default two minutes. **/
	var ?timeout:Int;
}

typedef Start = {
	var file:String;
	var args:Array<String>;

	/** Pass the arguments to Windows as they are (they are already quoted for cmd.exe). **/
	var verbatim:Bool;
}

typedef ExecResult = {
	var code:Int;
	var stdout:String;
	var stderr:String;
}

/**
	Runs external commands (`lime`, `ceramic`, `haxelib`, ...) without a shell.
	On Windows, .cmd/.bat launchers go through cmd.exe with their arguments escaped (see `prepare`).
**/
class Exec {
	static final isWindows = process.platform == "win32";

	/**
		Runs `command` (executable first, then arguments).
		Rejects with `NotFound` when the executable doesn't exist, otherwise resolves with the exit code and output.
	**/
	public static function run(command:Array<String>, options:ExecOptions):Promise<ExecResult> {
		final executable = alias(command[0], options.aliases);
		final start = prepare(executable, command.slice(1), options);
		if (start == null) {
			return Promise.reject(new NotFound(executable));
		}
		return new Promise(function(resolve, reject) {
			final child = ChildProcess.spawn(start.file, start.args, cast {
				cwd: options.cwd,
				env: options.env,
				windowsHide: true,
				windowsVerbatimArguments: start.verbatim
			});
			final stdout = [];
			final stderr = [];
			final timer = haxe.Timer.delay(function() {
				child.kill();
				reject('`${command.join(" ")}` did not finish within ${Std.int((options.timeout ?? 120000) / 1000)} seconds');
			}, options.timeout ?? 120000);
			child.stdout.on("data", (chunk:Buffer) -> stdout.push(chunk));
			child.stderr.on("data", (chunk:Buffer) -> stderr.push(chunk));
			child.on("error", function(error:Error) {
				timer.stop();
				if ((cast error).code == "ENOENT") {
					reject(new NotFound(executable));
				} else {
					reject(error);
				}
			});
			child.on("close", function(code:Null<Int>, _) {
				timer.stop();
				resolve({
					code: code == null ? -1 : code,
					stdout: Buffer.concat(stdout).toString("utf8"),
					stderr: Buffer.concat(stderr).toString("utf8")
				});
			});
		});
	}

	/**
		Tries each command in turn, moving on only when the executable isn't found.
		Useful for `lime ...` with `haxelib run lime ...` as a fallback.
	**/
	public static function runFirst(alternatives:Array<Array<String>>, options:ExecOptions):Promise<ExecResult> {
		if (alternatives.length == 0) {
			return Promise.reject(new NotFound("(no command)"));
		}
		return run(alternatives[0], options).then(null, function(error:Dynamic) {
			if (Std.isOfType(error, NotFound) && alternatives.length > 1) {
				return runFirst(alternatives.slice(1), options);
			}
			return Promise.reject(error);
		});
	}

	/** Synchronous variant for quick queries such as `haxe --version`. Returns null when the executable doesn't exist. **/
	public static function runSync(command:Array<String>, options:ExecOptions):Null<ExecResult> {
		final start = prepare(alias(command[0], options.aliases), command.slice(1), options);
		if (start == null) {
			return null;
		}
		final result = ChildProcess.spawnSync(start.file, start.args, cast {
			cwd: options.cwd,
			env: options.env,
			windowsHide: true,
			windowsVerbatimArguments: start.verbatim,
			encoding: "utf8",
			timeout: 15000
		});
		if (result.error != null) {
			return null;
		}
		return {
			code: result.status == null ? -1 : result.status,
			stdout: Std.string(result.stdout),
			stderr: Std.string(result.stderr)
		};
	}

	/**
		What to start for `executable` and `args`, or null when the executable doesn't exist (Windows only;
		elsewhere spawning reports that). Windows has no shell here: with one, Node joins the arguments
		unquoted, so any path with a space breaks. So the executable is looked up on PATH, and only a
		.cmd/.bat launcher (haxelib.cmd, lime.cmd) runs through cmd.exe, escaped as cross-spawn does it.
	**/
	static function prepare(executable:String, args:Array<String>, options:ExecOptions):Null<Start> {
		if (!isWindows) {
			return {file: executable, args: args, verbatim: false};
		}
		final file = Files.executable(executable, options.env, options.cwd);
		return file == null ? null : windowsStart(file, args, Files.variable(options.env, "COMSPEC", true) ?? "cmd.exe");
	}

	public static function windowsStart(file:String, args:Array<String>, comSpec:String):Start {
		if (~/\.(com|exe)$/i.match(file)) {
			return {file: file, args: args, verbatim: false};
		}
		final launcher = file.split("/").join("\\");
		// npm's .cmd shims pass their arguments on to another command line, which parses them again.
		final twice = ~/node_modules[\\\/]\.bin[\\\/][^\\\/]+\.cmd$/i.match(launcher);
		final line = [escapeMeta(launcher)].concat([for (arg in args) escapeArgument(arg, twice)]).join(" ");
		return {file: comSpec, args: ["/d", "/s", "/c", '"$line"'], verbatim: true};
	}

	static function escapeArgument(arg:String, twice:Bool):String {
		// Backslashes before a quote, and before the closing quote added here, are doubled; the quote is escaped
		// (https://qntm.org/cmd).
		var quoted = ~/(\\*)"/g.map(arg, re -> re.matched(1) + re.matched(1) + '\\"');
		quoted = ~/(\\*)$/.map(quoted, re -> re.matched(1) + re.matched(1));
		quoted = escapeMeta('"$quoted"');
		return twice ? escapeMeta(quoted) : quoted;
	}

	/** cmd.exe's special characters, each escaped with `^`. **/
	static function escapeMeta(text:String):String {
		return ~/([()\][%!^"`<>&|;, *?])/g.map(text, re -> "^" + re.matched(1));
	}

	static function alias(executable:String, aliases:Null<DynamicAccess<String>>):String {
		if (aliases != null && aliases.exists(executable)) {
			return aliases.get(executable);
		}
		return executable;
	}
}

class NotFound {
	public final executable:String;

	public function new(executable:String) {
		this.executable = executable;
	}

	public function toString() {
		return '`$executable` was not found on PATH';
	}
}
