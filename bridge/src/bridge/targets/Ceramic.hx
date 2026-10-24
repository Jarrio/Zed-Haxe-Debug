package bridge.targets;

import bridge.Build;
import bridge.Plan;
import bridge.project.HaxeArgs;
import bridge.project.Hxml;
import bridge.targets.Hxcpp;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/** A Ceramic command line (`ceramic clay run web --setup --assets`), split up. **/
typedef CeramicCommand = {
	final executable:String;

	/** `clay`, `headless`, `unity`. **/
	final backend:String;

	final target:String;
	final flags:Array<String>;
}

/**
	Ceramic projects (`ceramic.yml`). Ceramic builds with its own Haxe, from a `project.hxml` it generates in
	`out/<backend>/<target>-debug/` when it sets a target up, and has no way to add Haxe arguments from its
	command line. So the bridge has Ceramic set the target up, adds its own lines to that generated hxml,
	and builds without setting up again.
**/
class Ceramic {
	static final native = ["linux", "mac", "windows"];

	/** `ceramic <backend> <action> <target> …`, split up; null for any other command. **/
	public static function parse(command:Array<String>):Null<CeramicCommand> {
		if (command.length < 4 || Path.withoutExtension(Path.withoutDirectory(command[0])).toLowerCase() != "ceramic") {
			return null;
		}
		return {
			executable: command[0],
			backend: command[1],
			target: command[3],
			flags: command.slice(4).filter(flag -> !["--setup", "--assets", "--debug", "--no-skip"].contains(flag))
		};
	}

	/** The project file in `dir` or up to two folders below, if any. **/
	public static function find(dir:String):Null<String> {
		final found = Files.findByName(dir, ["ceramic.yml"], 2);
		return found.length > 0 ? found[0] : null;
	}

	/** The debugger a Ceramic target needs, as the bridge names them. **/
	public static function debugger(target:String):String {
		return native.contains(target) ? "hxcpp" : target == "web" ? "js" : target;
	}

	/** The web target: built by Ceramic in debug mode, then served for a browser that js-debug starts. **/
	public static function web(command:CeramicCommand, config:LaunchConfig, dir:String, projectRoot:String,
			env:DynamicAccess<String>):{arguments:Dynamic, prelaunch:Prelaunch} {
		final build:HaxeRun = {
			executable: command.executable,
			args: [command.backend, "build", command.target, "--setup", "--assets", "--debug"].concat(command.flags),
			cwd: dir,
			env: {}
		};
		final arguments = JavaScript.browser(config, dir, projectRoot, env);
		return {
			arguments: arguments,
			prelaunch: JavaScript.browserPrelaunch(arguments, build, function() {
				// The page is where the generated hxml writes the JavaScript.
				final js = HaxeArgs.output(Hxml.expand([hxml(command, dir)], dir), ["-js", "--js"], dir);
				return js == null ? Promise.reject('Ceramic\'s ${hxml(command, dir)} has no -js output.') : Promise.resolve(Path.directory(js));
			})
		};
	}

	/**
		A desktop target: `ceramic <backend> setup <target> --debug`, hxcpp-debug-server added to the hxml
		that writes, then `ceramic <backend> run <target> --assets --debug`, whose program connects back.
	**/
	public static function hxcpp(command:CeramicCommand, config:LaunchConfig, dir:String, server:Null<String>):{arguments:HxcppLaunch, prelaunch:Prelaunch} {
		final project = find(dir);
		final ownServer = project != null && File.getContent(project).indexOf("hxcpp-debug-server") >= 0;
		if (!ownServer && server == null) {
			throw new LaunchError('hxcpp-debug-server isn\'t installed, and the project doesn\'t use it.');
		}
		final setup:HaxeRun = {
			executable: command.executable,
			args: [command.backend, "setup", command.target, "--debug"].concat(command.flags),
			cwd: dir,
			env: {}
		};
		final arguments:HxcppLaunch = {
			build: null,
			program: command.executable,
			// --no-skip: Ceramic skips the Haxe build when the sources haven't changed, which would leave out the debug server.
			args: [command.backend, "run", command.target, "--assets", "--debug", "--no-skip"].concat(command.flags),
			cwd: dir,
			env: config.env ?? {},
			port: config.port ?? (ownServer ? Hxcpp.defaultPort : 0),
			launcher: true
		};
		return {
			arguments: arguments,
			prelaunch: {
				build: setup,
				run: function(output) {
					return Build.run(setup, output).then(function(_):Dynamic {
						if (!ownServer) {
							final path = hxml(command, dir);
							if (!FileSystem.exists(path)) {
								return Promise.reject('Ceramic\'s setup didn\'t write $path.');
							}
							// Gone at the next setup, which every Ceramic build without the debugger does.
							File.saveContent(path, File.getContent(path) + '\n-cp $server\n--macro hxcpp.debug.jsonrpc.Macro.injectServer()\n');
						}
						return arguments;
					});
				}
			}
		};
	}

	/** The hxml Ceramic generates for a debug build of the command's target. **/
	static function hxml(command:CeramicCommand, dir:String):String {
		return Path.join([dir, "out", command.backend, '${command.target}-debug', "project.hxml"]);
	}
}
