package bridge.targets;

import bridge.Plan;
import bridge.project.Hxml;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;

/** What `HxcppAdapter` builds and runs. **/
typedef HxcppLaunch = {
	/** The Haxe run that builds `program`, or null when the configuration names a program already built. **/
	final build:Null<HaxeRun>;

	final program:String;
	final args:Array<String>;

	/** Folder the program runs in. **/
	final cwd:String;

	/** Added to the bridge's environment for the program. **/
	final env:DynamicAccess<String>;

	/**
		Port the program's debug server connects to. 0 picks a free one and tells the program in
		`HXCPP_DEBUG_PORT`, which only the debug server the extension brings reads.
	**/
	final port:Int;
}

typedef HaxeRun = {
	final executable:String;
	final args:Array<String>;
	final cwd:String;

	/** Added to the bridge's environment. **/
	final env:DynamicAccess<String>;
}

/**
	hxcpp programs, debugged through hxcpp-debug-server (https://github.com/vshaxe/hxcpp-debugger): a library
	compiled into the program which, in a `-debug` build, connects back to the debugger at startup.
	The bridge builds the program with it unless the configuration names a program already built.
**/
class Hxcpp {
	/** hxcpp-debug-server's port when nothing sets another. **/
	public static inline final defaultPort = 6972;

	static inline final library = "hxcpp-debug-server";

	public static function launch(config:LaunchConfig, haxeArgs:Array<String>, cwd:String, toolchain:ResolvedToolchain, server:Null<String>):HxcppLaunch {
		final program = config.program;
		if (program != null && haxeArgs.length == 0) {
			// Built elsewhere, with a debug server of any version: they all connect to the port compiled in.
			return {
				build: null,
				program: Planner.absolute(cwd, program),
				args: config.args ?? [],
				cwd: cwd,
				env: config.env ?? {},
				port: config.port ?? defaultPort
			};
		}
		if (toolchain.major > 0 && toolchain.major < 4) {
			throw new LaunchError('Debugging hxcpp needs Haxe 4 or newer; ${toolchain.path} is ${toolchain.version}.');
		}
		final args = withoutCommands(cppCompilation(Hxml.expand(haxeArgs, cwd)));
		// A build that brings its own copy of the library keeps it, and that copy's port.
		final ownServer = usesLibrary(args, library);
		if (!ownServer && server == null) {
			throw new LaunchError('$library isn\'t installed, and the build doesn\'t use it (-lib $library).');
		}
		final extra = ["-debug"];
		if (!ownServer) {
			extra.push("-cp");
			extra.push(server);
			extra.push("--macro");
			extra.push("hxcpp.debug.jsonrpc.Macro.injectServer()");
		}
		final definedPort = Std.parseInt(define(args, "HXCPP_DEBUG_PORT") ?? "");
		return {
			build: {executable: toolchain.path, args: args.concat(extra), cwd: cwd, env: toolchain.env},
			program: program != null ? Planner.absolute(cwd, program) : executable(args, cwd),
			args: config.args ?? [],
			cwd: cwd,
			env: config.env ?? {},
			port: config.port ?? (ownServer ? (definedPort ?? defaultPort) : 0)
		};
	}

	/** The one compilation in `args` that outputs C++ (see `Planner.compilations`). **/
	public static function cppCompilation(args:Array<String>):Array<String> {
		final cpp = [for (compilation in Planner.compilations(args)) if (Planner.targetOf(compilation) == "hxcpp") compilation];
		return switch cpp {
			case [only]: only;
			case []: throw new LaunchError("The build has no --cpp output to debug.");
			case _: throw new LaunchError('The build compiles C++ ${cpp.length} times. Pick one with "haxeArgs" in the debug configuration.');
		}
	}

	/** Drops `--cmd`, which would run something after the build, such as the program without the debugger. **/
	public static function withoutCommands(args:Array<String>):Array<String> {
		final result = [];
		var i = 0;
		while (i < args.length) {
			if (args[i] == "--cmd" || args[i] == "-cmd") {
				i += 2;
				continue;
			}
			result.push(args[i]);
			i++;
		}
		return result;
	}

	/**
		Where hxcpp writes a `-debug` build's executable: `<--cpp folder>/<main class>-debug`, unless the
		`HAXE_OUTPUT_FILE` or `DEBUGSUFFIX` defines say otherwise.
	**/
	public static function executable(args:Array<String>, cwd:String):String {
		var dir = cwd;
		var output:Null<String> = null;
		var main:Null<String> = null;
		var i = 0;
		while (i < args.length - 1) {
			switch args[i] {
				case "--cwd":
					dir = Planner.absolute(dir, args[i + 1]);
				case "-cpp" | "--cpp":
					output = Planner.absolute(dir, args[i + 1]);
				case "-main" | "--main" | "-m":
					main = args[i + 1];
				case _:
			}
			i++;
		}
		if (output == null) {
			throw new LaunchError("The build has no --cpp output to debug.");
		}
		final name = define(args, "HAXE_OUTPUT_FILE") ?? {
			if (main == null) {
				throw new LaunchError('The build has no -main class, so it makes no program to run. Set "program" in the debug configuration.');
			}
			main.split(".").pop() + (define(args, "DEBUGSUFFIX") ?? "-debug");
		}
		return Path.join([output, process.platform == "win32" ? '$name.exe' : name]);
	}

	/** Whether `args` add the haxelib `name`, at any version. **/
	public static function usesLibrary(args:Array<String>, name:String):Bool {
		for (i in 0...args.length - 1) {
			if ((args[i] == "-lib" || args[i] == "-L" || args[i] == "--library") && args[i + 1].split(":")[0] == name) {
				return true;
			}
		}
		return false;
	}

	/** The value of the define `name` in `args` (`-D name=value`), "1" when it has none, null when it's absent. **/
	public static function define(args:Array<String>, name:String):Null<String> {
		var value:Null<String> = null;
		for (i in 0...args.length - 1) {
			if (args[i] == "-D" || args[i] == "--define") {
				final parts = args[i + 1].split("=");
				if (parts[0] == name) {
					value = parts.length > 1 ? parts.slice(1).join("=") : "1";
				}
			}
		}
		return value;
	}
}
