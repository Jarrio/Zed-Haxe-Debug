package bridge.targets;

import bridge.Build;
import bridge.Plan;
import bridge.project.HaxeArgs;
import bridge.project.Hxml;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.lib.Promise;
import js.node.Os;
import sys.FileSystem;
import sys.io.File;

/** The `launch` arguments of vshaxe's hashlink-debugger (its `HLAdapter.hx`). **/
typedef HashLinkLaunch = {
	final cwd:String;

	/** The .hl file. **/
	final program:String;

	/** The HashLink VM. **/
	final hl:String;

	final args:Array<String>;
	final env:DynamicAccess<String>;
	var ?port:Int;

	/**
		Where the debugger looks for the files the program's debug information names, the standard library
		last. Many are named relative to the class path they're in. Filled in by the build.
	**/
	var ?classPaths:Array<String>;
}

/**
	HashLink programs, debugged through vshaxe's hashlink-debugger
	(https://github.com/vshaxe/hashlink-debugger), which runs the program in the HashLink VM. It doesn't
	build, so the bridge builds the hxml with `-debug` first, and asks Haxe for the class paths on the way.
**/
class HashLink {
	/** Macro class the build calls to write its class paths, from a folder of its own. **/
	static final helper = "zed.haxedebug.ClassPaths";

	static final helperSource = "package zed.haxedebug;

// Written by the Haxe debugger for Zed, for the duration of one build.
class ClassPaths {
	public static function write(file:String) {
		var paths = [for (path in haxe.macro.Context.getClassPath()) sys.FileSystem.absolutePath(path == \"\" ? \".\" : path)];
		sys.io.File.saveContent(file, haxe.Json.stringify(paths));
	}
}
";

	public static function launch(config:LaunchConfig, haxeArgs:Array<String>, cwd:String, toolchain:ResolvedToolchain):{arguments:HashLinkLaunch, build:HaxeRun} {
		if (haxeArgs.length == 0) {
			throw new LaunchError('The debugger builds HashLink programs itself, to know where their files are. Set "hxml" or "haxeArgs".');
		}
		if (toolchain.major > 0 && toolchain.major < 4) {
			throw new LaunchError('Debugging HashLink needs Haxe 4 or newer; ${toolchain.path} is ${toolchain.version}.');
		}
		final args = HaxeArgs.withoutCommands(Planner.compilationFor(Hxml.expand(haxeArgs, cwd), "hl"));
		final output = HaxeArgs.output(args, ["-hl", "--hl"], cwd);
		if (output != null && Path.extension(output) == "c") {
			throw new LaunchError('This build makes C code for HashLink/C, which runs without the HashLink VM and its debugger. Debug a build to a .hl file.');
		}
		final arguments:HashLinkLaunch = {
			cwd: cwd,
			program: config.program != null ? Planner.absolute(cwd, config.program) : output,
			hl: config.hl ?? "hl",
			args: config.args ?? [],
			// hashlink-debugger runs the VM with exactly this environment, so it's the whole of it.
			env: Build.environment(config.env ?? {})
		};
		if (config.port != null) {
			arguments.port = config.port;
		}
		return {
			arguments: arguments,
			build: {executable: toolchain.path, args: args.concat(["-debug"]), cwd: cwd, env: toolchain.env}
		};
	}

	/** Builds, then resolves with the `launch` arguments, their class paths filled in. **/
	public static function prelaunch(arguments:HashLinkLaunch, build:HaxeRun):Prelaunch {
		return {
			build: build,
			run: function(output) {
				return classPaths(build, output, (dir, call) -> ["-cp", dir, "--macro", call]).then(function(paths):Dynamic {
					arguments.classPaths = paths;
					if (!FileSystem.exists(arguments.program)) {
						return Promise.reject('The build didn\'t make ${arguments.program}. If it writes the program elsewhere, set "program" in the debug configuration.');
					}
					return arguments;
				});
			}
		};
	}

	/**
		Runs `build` with the class path helper added, and resolves with the build's class paths. `flags`
		makes the build's arguments for the helper's folder and the call that writes the paths: plain Haxe
		arguments, or Lime's `--haxeflag`s.
	**/
	public static function classPaths(build:HaxeRun, output:String->Void, flags:(dir:String, call:String) -> Array<String>):Promise<Array<String>> {
		final dir = js.node.Fs.mkdtempSync(Path.join([Os.tmpdir(), "haxe-debug-"]));
		final file = Path.join([dir, "classpaths.json"]);
		FileSystem.createDirectory(Path.join([dir, "zed", "haxedebug"]));
		File.saveContent(Path.join([dir, "zed", "haxedebug", "ClassPaths.hx"]), helperSource);
		function cleanUp() {
			js.Syntax.code("require('fs').rmSync({0}, {recursive: true, force: true})", dir);
		}
		return Build.run(build, output, flags(dir, '$helper.write(${Json.stringify(file)})')).then(function(_) {
			final paths:Array<String> = Json.parse(File.getContent(file));
			cleanUp();
			return [for (path in paths) if (Path.normalize(path) != Path.normalize(dir)) path];
		}, function(error:Dynamic):Dynamic {
			cleanUp();
			return Promise.reject(error);
		});
	}
}
