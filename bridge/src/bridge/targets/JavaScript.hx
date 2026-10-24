package bridge.targets;

import bridge.Build;
import bridge.Plan;
import bridge.project.HaxeArgs;
import bridge.project.Hxml;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import sys.FileSystem;

/**
	JavaScript run by Node, debugged through Microsoft's js-debug (https://github.com/microsoft/vscode-js-debug),
	the debugger behind Zed's own JavaScript support. The bridge builds with source maps, which js-debug
	follows from the JavaScript to the Haxe code, so breakpoints, frames and stepping are in the .hx files.
**/
class JavaScript {
	/**
		The `launch` arguments for js-debug (its `pwa-node` type). `projectRoot` is the folder js-debug
		treats as the workspace.
	**/
	public static function launch(config:LaunchConfig, haxeArgs:Array<String>, cwd:String, projectRoot:String, toolchain:ResolvedToolchain,
			env:DynamicAccess<String>):{arguments:Dynamic, build:Null<HaxeRun>} {
		// A program named without a build is run as it is, with whatever source maps it was built with.
		final args = haxeArgs.length == 0 ? null : HaxeArgs.withoutCommands(Planner.compilationFor(Hxml.expand(haxeArgs, cwd), "js"));
		final program = config.program != null ? Planner.absolute(cwd, config.program) : HaxeArgs.output(args, ["-js", "--js"], cwd);
		final arguments:Dynamic = {
			type: "pwa-node",
			request: "launch",
			program: program,
			cwd: cwd,
			args: config.args ?? [],
			env: config.env ?? {},
			// The program's output comes as DAP output events, as with the other targets.
			console: "internalConsole",
			runtimeExecutable: config.runtimeExecutable ?? Files.executable("node", env, cwd) ?? process.execPath,
			stopOnEntry: config.stopOnEntry ?? false,
			sourceMaps: true,
			// Without a workspace folder, and with js-debug pausing each script until its source map is read
			// (Zed's default for its own JavaScript adapter), breakpoints in .hx files never take effect.
			__workspaceFolder: projectRoot,
			pauseForSourceMap: false,
			outFiles: [Path.join([Path.directory(program), "**", "*.js"])]
		};
		return {
			arguments: arguments,
			build: args == null ? null : {executable: toolchain.path, args: args.concat(["-debug", "-D", "js-source-map"]), cwd: cwd, env: toolchain.env}
		};
	}

	/** Builds, then resolves with the `launch` arguments once the program is there. **/
	public static function prelaunch(arguments:Dynamic, build:HaxeRun):Prelaunch {
		return {
			build: build,
			run: function(output) {
				return Build.run(build, output).then(function(_):Dynamic {
					if (!FileSystem.exists(arguments.program)) {
						return Promise.reject('The build didn\'t make ${arguments.program}. If it writes the program elsewhere, set "program" in the debug configuration.');
					}
					return arguments;
				});
			}
		};
	}
}
