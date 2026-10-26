package bridge.targets;

import bridge.Build;
import bridge.Plan;
import bridge.targets.HashLink;
import bridge.targets.Hxcpp;
import bridge.targets.JavaScript;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import bridge.util.Exec;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/** A Lime command line, split up. **/
typedef LimeCommand = {
	/** What runs Lime: `["lime"]`, `["openfl"]` or `["haxelib", "run", "lime"]`. **/
	final tool:Array<String>;

	final action:String;
	final projectFile:Null<String>;
	final target:Null<String>;
	final flags:Array<String>;
}

/**
	Lime projects, which OpenFL and Flixel projects are too (`project.xml`). Lime builds and runs them
	itself (`lime test`): it generates the Haxe build and the native project, copies the assets and starts
	the program. The bridge runs that command for a debug build, adding the debugger's pieces to the Haxe
	build with `--haxeflag`.
**/
class Lime {
	public static final projectFiles = ["project.xml", "Project.xml", "project.hxp", "project.lime"];

	/** Lime targets built with hxcpp for the desktop. **/
	static final native = ["linux", "windows", "mac", "macos", "cpp"];

	/** `lime …`, `openfl …` or `haxelib run lime …`, split up; null for any other command. **/
	public static function parse(command:Array<String>):Null<LimeCommand> {
		if (command.length == 0) {
			return null;
		}
		final executable = Path.withoutExtension(Path.withoutDirectory(command[0])).toLowerCase();
		final tool = if (executable == "haxelib" && command[1] == "run" && (command[2] == "lime" || command[2] == "openfl")) {
			command.slice(0, 3);
		} else if (executable == "lime" || executable == "openfl") {
			[command[0]];
		} else {
			return null;
		}
		final rest = command.slice(tool.length);
		var projectFile:Null<String> = null;
		var target:Null<String> = null;
		final flags = [];
		for (arg in rest.slice(1)) {
			if (StringTools.startsWith(arg, "-")) {
				flags.push(arg);
			} else if (projectFile == null && target == null && ~/\.(xml|hxp|lime)$/i.match(arg)) {
				projectFile = arg;
			} else if (target == null) {
				target = arg;
			} else {
				flags.push(arg);
			}
		}
		return {
			tool: tool,
			action: rest[0] ?? "test",
			projectFile: projectFile,
			target: target,
			flags: flags
		};
	}

	/** The Lime project file in `dir` or up to two folders below, if any. **/
	public static function find(dir:String):Null<String> {
		final found = Files.findByName(dir, projectFiles, 2);
		return found.length > 0 ? found[0] : null;
	}

	/** The target to debug when nothing names one: the desktop this runs on. **/
	public static function hostTarget():String {
		return switch process.platform {
			case "win32": "windows";
			case "darwin": "mac";
			case _: "linux";
		}
	}

	public static function isTarget(name:Null<String>):Bool {
		return name != null && (native.contains(name) || ["hl", "html5", "neko", "android", "ios", "air", "flash", "electron"].contains(name));
	}

	/** The debugger a Lime target needs, as the bridge names them. **/
	public static function debugger(target:String):String {
		return native.contains(target) ? "hxcpp" : target;
	}

	/**
		`lime test <target> -debug` for an hxcpp target, with hxcpp-debug-server added unless the project
		brings it. Lime starts the program, which connects back to the debugger.
	**/
	public static function hxcpp(command:LimeCommand, config:LaunchConfig, cwd:String, toolchain:ResolvedToolchain, env:DynamicAccess<String>,
			server:Null<String>):HxcppLaunch {
		final projectFile = command.projectFile == null ? null : Planner.absolute(cwd, command.projectFile);
		final dir = projectFile == null ? cwd : Path.directory(projectFile);
		// Lime finds the project file in its folder when the command names none.
		final project = projectFile ?? find(dir);
		final ownServer = project != null && FileSystem.exists(project) && File.getContent(project).indexOf("hxcpp-debug-server") >= 0;
		if (!ownServer && server == null) {
			throw new LaunchError('hxcpp-debug-server isn\'t installed, and the project doesn\'t use it.');
		}
		final haxeFlags = ownServer ? [] : [
			'--haxeflag=-cp $server',
			"--haxeflag=--macro hxcpp.debug.jsonrpc.Macro.injectServer()",
			'--haxeflag=-D ${Hxcpp.rebuildDefine}'
		];
		final environment = toolEnvironment(toolchain, env);
		for (name => value in config.env ?? {}) {
			environment.set(name, value);
		}
		return {
			build: null,
			program: command.tool[0],
			args: testArgs(command, projectFile).concat(haxeFlags),
			cwd: dir,
			env: environment,
			port: config.port ?? (ownServer ? Hxcpp.defaultPort : 0),
			launcher: true
		};
	}

	/**
		Lime's HashLink target: `lime build hl -debug`, with the class path helper added, then the VM Lime
		copied next to the program (`lime display … --output-file`) runs it under hashlink-debugger. Lime
		brings its own HashLink, so none needs to be installed.
	**/
	public static function hashlink(command:LimeCommand, config:LaunchConfig, cwd:String, toolchain:ResolvedToolchain,
			env:DynamicAccess<String>):{arguments:HashLinkLaunch, prelaunch:Prelaunch} {
		final projectFile = command.projectFile == null ? null : Planner.absolute(cwd, command.projectFile);
		final dir = projectFile == null ? cwd : Path.directory(projectFile);
		final environment = toolEnvironment(toolchain, env);
		final build:HaxeRun = {
			executable: command.tool[0],
			args: limeArgs(command, "build", projectFile),
			cwd: dir,
			env: environment
		};
		final arguments:HashLinkLaunch = {
			cwd: dir,
			program: "",
			hl: "",
			args: config.args ?? [],
			// The whole environment, as for HashLink.launch.
			env: Build.environment(config.env ?? {})
		};
		if (config.port != null) {
			arguments.port = config.port;
		}
		return {
			arguments: arguments,
			prelaunch: {
				build: build,
				run: function(output) {
					final haxeFlags = (dir, call) -> ['--haxeflag=-cp $dir', '--haxeflag=--macro $call'];
					return HashLink.classPaths(build, output, haxeFlags).then(function(paths) {
						arguments.classPaths = paths;
						return outputFile(command, projectFile, dir, environment);
					}).then(function(vm:String):Dynamic {
						// Lime copies its HashLink VM as the program, with the bytecode next to it as hlboot.dat.
						final arguments:Dynamic = arguments;
						arguments.hl = vm;
						arguments.program = Path.join([Path.directory(vm), "hlboot.dat"]);
						arguments.cwd = Path.directory(vm);
						return arguments;
					});
				}
			}
		};
	}

	/**
		Lime's html5 target: `lime build html5 -debug` with source maps, then the folder Lime wrote the page
		to, served for a browser that js-debug starts.
	**/
	public static function html5(command:LimeCommand, config:LaunchConfig, cwd:String, projectRoot:String, toolchain:ResolvedToolchain,
			env:DynamicAccess<String>):{arguments:Dynamic, prelaunch:Prelaunch} {
		final projectFile = command.projectFile == null ? null : Planner.absolute(cwd, command.projectFile);
		final dir = projectFile == null ? cwd : Path.directory(projectFile);
		final environment = toolEnvironment(toolchain, env);
		final build:HaxeRun = {
			executable: command.tool[0],
			args: limeArgs(command, "build", projectFile).concat(["--haxeflag=-D js-source-map"]),
			cwd: dir,
			env: environment
		};
		final arguments = JavaScript.browser(config, dir, projectRoot, env);
		return {
			arguments: arguments,
			prelaunch: JavaScript.browserPrelaunch(arguments, build, () -> outputFile(command, projectFile, dir, environment).then(Path.directory))
		};
	}

	/** Where Lime writes the program for this command's target: `lime display … --output-file`. **/
	static function outputFile(command:LimeCommand, projectFile:Null<String>, dir:String, environment:DynamicAccess<String>):Promise<String> {
		final display = [command.tool[0]].concat(limeArgs(command, "display", projectFile)).concat(["--output-file"]);
		return Exec.run(display, {cwd: dir, env: Build.environment(environment)}).then(function(result):Dynamic {
			final lines = [for (line in result.stdout.split("\n")) if (StringTools.trim(line) != "") StringTools.trim(line)];
			final path = lines.length == 0 ? null : Planner.absolute(dir, lines[lines.length - 1]);
			if (result.code != 0 || path == null || !FileSystem.exists(path)) {
				return Promise.reject('Lime didn\'t say where it put the program (lime display --output-file): ${result.stderr}${result.stdout}');
			}
			return path;
		});
	}

	/** `lime test` in debug mode, with the project's own flags but not its build type. **/
	static function testArgs(command:LimeCommand, projectFile:Null<String>):Array<String> {
		return limeArgs(command, "test", projectFile);
	}

	/** Arguments for Lime's `action`, in debug mode, with the project's own flags but not its build type. **/
	static function limeArgs(command:LimeCommand, action:String, projectFile:Null<String>):Array<String> {
		final args = command.tool.slice(1).concat([action]);
		if (projectFile != null) {
			args.push(projectFile);
		}
		if (command.target != null) {
			args.push(command.target);
		}
		for (flag in command.flags) {
			if (!["-debug", "-release", "-final", "-nocolor"].contains(flag)) {
				args.push(flag);
			}
		}
		return args.concat(["-debug", "-nocolor"]);
	}

	/**
		The environment for a project's own tool: Toolchain's additions, and the Haxe it resolved first on
		PATH, so that the tool builds with the same Haxe as the language server.
	**/
	public static function toolEnvironment(toolchain:ResolvedToolchain, env:DynamicAccess<String>):DynamicAccess<String> {
		final result:DynamicAccess<String> = toolchain.env.copy();
		if (Path.isAbsolute(toolchain.path)) {
			final name = [for (key in env.keys()) if (key.toUpperCase() == "PATH") key][0] ?? "PATH";
			final separator = process.platform == "win32" ? ";" : ":";
			final current = env.get(name);
			result.set(name, Path.directory(toolchain.path) + (current == null ? "" : separator + current));
		}
		return result;
	}
}
