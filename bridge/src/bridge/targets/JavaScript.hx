package bridge.targets;

import bridge.Build;
import bridge.Plan;
import bridge.project.HaxeArgs;
import bridge.project.Hxml;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import bridge.util.Files;
import bridge.util.StaticServer;
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
		final build:Null<HaxeRun> = args == null ? null : {
			executable: toolchain.path,
			args: args.concat(["-debug", "-D", "js-source-map"]),
			cwd: cwd,
			env: toolchain.env
		};
		if (config.url != null || config.webRoot != null) {
			// A page: the folder it's in, served unless there's a URL.
			final webRoot = Planner.absolute(cwd, config.webRoot ?? Path.directory(program));
			return {arguments: browser(config, webRoot, projectRoot, env), build: build};
		}
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
		return {arguments: arguments, build: build};
	}

	/**
		js-debug's arguments for a page in Chrome, Chromium or Edge (its `pwa-chrome` type). `url` is filled
		in by `browserPrelaunch` when the bridge serves `webRoot` itself.
	**/
	public static function browser(config:LaunchConfig, webRoot:String, projectRoot:String, env:DynamicAccess<String>):Dynamic {
		return {
			type: "pwa-chrome",
			request: "launch",
			url: config.url,
			webRoot: webRoot,
			runtimeExecutable: config.browser ?? findBrowser(env, projectRoot) ?? "stable",
			sourceMaps: true,
			// As for Node (see `launch`).
			__workspaceFolder: projectRoot,
			pauseForSourceMap: false,
			outFiles: [Path.join([webRoot, "**", "*.js"])]
		};
	}

	/**
		Runs `build` if there is one, finds the folder to serve with `webRoot` (which may need the build to
		have run), serves it unless the configuration gave a URL, and resolves with the `launch` arguments.
	**/
	public static function browserPrelaunch(arguments:Dynamic, build:Null<HaxeRun>, webRoot:Void->Promise<String>):Prelaunch {
		return {
			build: build,
			run: function(output) {
				final built:Promise<Any> = build == null ? Promise.resolve(null) : Build.run(build, output);
				return built.then(_ -> webRoot()).then(function(root):Promise<Dynamic> {
					arguments.webRoot = root;
					arguments.outFiles = [Path.join([root, "**", "*.js"])];
					if (arguments.url != null) {
						return Promise.resolve(arguments);
					}
					return StaticServer.start(root).then(function(url):Dynamic {
						output('Serving $root at $url\n');
						arguments.url = url;
						return arguments;
					});
				});
			}
		};
	}

	/** Chrome, Chromium, Edge or Brave on PATH; elsewhere js-debug finds an installed Chrome itself ("stable"). **/
	static function findBrowser(env:DynamicAccess<String>, cwd:String):Null<String> {
		if (process.platform != "linux") {
			return null;
		}
		for (name in ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"]) {
			final path = Files.executable(name, env, cwd);
			if (path != null) {
				return path;
			}
		}
		return null;
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
