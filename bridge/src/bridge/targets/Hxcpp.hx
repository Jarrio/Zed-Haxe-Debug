package bridge.targets;

import bridge.Build.HaxeRun;
import bridge.Plan;
import bridge.project.HaxeArgs;
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

	/**
		`program` is a tool that builds and starts the real program, such as `haxelib run lime test`: it's
		looked up on PATH, and has as long as it runs for the program to connect.
	**/
	final ?launcher:Bool;

	/** Whether a thread's stop stops the others too (the default). Needs the debug server the extension brings. **/
	var ?stopAllThreads:Bool;
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
		final args = HaxeArgs.withoutCommands(Planner.compilationFor(Hxml.expand(haxeArgs, cwd), "hxcpp"));
		// A build that brings its own copy of the library keeps it, and that copy's port.
		final ownServer = HaxeArgs.usesLibrary(args, library);
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
		final definedPort = Std.parseInt(HaxeArgs.define(args, "HXCPP_DEBUG_PORT") ?? "");
		return {
			build: {executable: toolchain.path, args: args.concat(extra), cwd: cwd, env: toolchain.env},
			program: program != null ? Planner.absolute(cwd, program) : executable(args, cwd),
			args: config.args ?? [],
			cwd: cwd,
			env: config.env ?? {},
			port: config.port ?? (ownServer ? (definedPort ?? defaultPort) : 0)
		};
	}

	/**
		A cppia script, run in a host built for debugging: an hxcpp `-debug` build with `-D scriptable` and
		hxcpp-debug-server. The bridge builds the script with `-debug` and runs the host, which gets the
		script's path unless the configuration gives other arguments.
	**/
	public static function cppia(config:LaunchConfig, haxeArgs:Array<String>, cwd:String, toolchain:ResolvedToolchain):HxcppLaunch {
		final host = config.program;
		if (host == null) {
			throw new LaunchError('A cppia script runs in a host. Set "program" to one built for debugging: an hxcpp -debug build with -D scriptable and $library.');
		}
		final args = HaxeArgs.withoutCommands(Planner.compilationFor(Hxml.expand(haxeArgs, cwd), "cppia"));
		final script = HaxeArgs.output(args, ["--cppia"], cwd);
		return {
			build: {executable: toolchain.path, args: args.concat(["-debug"]), cwd: cwd, env: toolchain.env},
			program: Planner.absolute(cwd, host),
			args: config.args ?? [script],
			cwd: cwd,
			env: config.env ?? {},
			// Built elsewhere, like a program named without a build.
			port: config.port ?? defaultPort
		};
	}

	/**
		Where hxcpp writes a `-debug` build's executable: `<--cpp folder>/<main class>-debug`, unless the
		`HAXE_OUTPUT_FILE` or `DEBUGSUFFIX` defines say otherwise.
	**/
	public static function executable(args:Array<String>, cwd:String):String {
		final output = HaxeArgs.output(args, ["-cpp", "--cpp"], cwd);
		if (output == null) {
			throw new LaunchError("The build has no --cpp output to debug.");
		}
		final name = HaxeArgs.define(args, "HAXE_OUTPUT_FILE") ?? {
			final main = HaxeArgs.value(args, ["-main", "--main", "-m"]);
			if (main == null) {
				throw new LaunchError('The build has no -main class, so it makes no program to run. Set "program" in the debug configuration.');
			}
			main.split(".").pop() + (HaxeArgs.define(args, "DEBUGSUFFIX") ?? "-debug");
		}
		return Path.join([output, process.platform == "win32" ? '$name.exe' : name]);
	}
}
