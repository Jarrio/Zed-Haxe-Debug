package bridge;

import bridge.Settings.ProjectSettings;
import bridge.dap.Filter;
import bridge.project.Hxml;
import bridge.targets.Eval;
import bridge.targets.Hxcpp;
import bridge.toolchain.Haxerc;
import bridge.toolchain.Toolchain;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import sys.FileSystem;

/**
	The debug configuration from `.zed/debug.json`, a task or the new-session dialog.
	`debug_adapter_schemas/Haxe.json` describes each field for users.
**/
typedef LaunchConfig = {
	var ?request:String;
	var ?target:String;
	var ?hxml:String;
	var ?haxeArgs:Array<String>;
	var ?cwd:String;
	var ?stopOnEntry:Bool;
	var ?haxePath:String;
	var ?mergeScopes:Bool;
	var ?showGeneratedVariables:Bool;
	var ?program:String;
	var ?args:Array<String>;
	var ?env:DynamicAccess<String>;
	var ?port:Int;
}

/** What the extension has downloaded for the debuggers. **/
typedef Adapters = {
	/** eval-debugger's index.js. **/
	var ?eval:String;

	/** The hxcpp-debug-server library, which the bridge compiles into hxcpp programs. **/
	var ?hxcppDebugServer:String;
}

enum AdapterKind {
	/** `node <script>`. **/
	Node(script:String);

	/** The bridge's own hxcpp adapter. **/
	OwnHxcpp;
}

/** A debugger ready to start in `cwd`, which then gets `launch` with `arguments`. **/
typedef Plan = {
	final target:String;
	final adapter:AdapterKind;
	final cwd:String;
	final arguments:Dynamic;

	/** Work around the debugger's quirks in the messages it sends Zed, in this order. **/
	final filters:Array<Filter>;
}

/** Why a session can't start, worded for the user: Zed shows it as the launch error. **/
class LaunchError extends haxe.Exception {}

/**
	Turns a debug configuration into a `Plan`: which Haxe arguments to build, which debugger fits their
	output, and which Haxe to run.
**/
class Planner {
	public static function plan(config:LaunchConfig, settings:ProjectSettings, adapters:Adapters, workspaceRoot:String,
			env:DynamicAccess<String>):Plan {
		if (config.request != null && config.request != "launch") {
			throw new LaunchError('Haxe debugging supports only "request": "launch" so far.');
		}
		final projectRoot = settings.root == null ? workspaceRoot : absolute(workspaceRoot, settings.root);
		final cwd = config.cwd == null ? projectRoot : absolute(workspaceRoot, config.cwd);
		// A program that's already built needs no hxml.
		final prebuilt = config.program != null && config.haxeArgs == null && config.hxml == null;
		final haxeArgs = prebuilt ? [] : (config.haxeArgs ?? hxmlArgs(config.hxml == null ? defaultHxml(projectRoot, settings) : absolute(cwd, config.hxml), cwd));
		final output = outputOf(Hxml.expand(haxeArgs, cwd));
		final target = config.target ?? output ?? (prebuilt ? "hxcpp" : "eval");
		final toolchain = Toolchain.resolve({
			workspaceRoot: workspaceRoot,
			projectRoot: projectRoot,
			haxerc: Haxerc.find(projectRoot, workspaceRoot)?.data,
			providerHaxePath: null,
			env: env
		}, config.haxePath == null ? settings : {haxePath: config.haxePath});
		for (note in toolchain.notes) {
			Log.info(note);
		}
		return switch target {
			case "eval":
				{
					target: target,
					adapter: Node(installed(adapters.eval, "eval-debugger")),
					cwd: cwd,
					arguments: Eval.arguments(config, haxeArgs, output, toolchain),
					filters: Eval.filters(toolchain)
				};
			case "hxcpp":
				{
					target: target,
					adapter: OwnHxcpp,
					cwd: cwd,
					arguments: Hxcpp.launch(config, haxeArgs, cwd, toolchain, adapters.hxcppDebugServer),
					filters: []
				};
			case other:
				throw new LaunchError('Debugging $other builds isn\'t supported yet. To debug this build\'s macros, set "target": "eval".');
		}
	}

	/**
		The debugger a build needs: that of the first compilation in it that a debugger here supports, else
		that of the first output. Null when there's no output: such a build only types the code, and eval
		can debug its macros.
	**/
	public static function outputOf(args:Array<String>):Null<String> {
		final targets = [for (compilation in compilations(args)) targetOf(compilation)];
		for (target in targets) {
			if (target == "eval" || target == "hxcpp") {
				return target;
			}
		}
		return targets.filter(target -> target != null)[0];
	}

	/**
		The separate compilations in a build's arguments, separated by `--next`. The arguments before an
		`--each` belong to all of them.
	**/
	public static function compilations(args:Array<String>):Array<Array<String>> {
		var common = [];
		final compilations = [[]];
		for (arg in args) {
			switch arg {
				case "--each":
					common = compilations.pop();
					compilations.push([]);
				case "--next":
					compilations.push([]);
				case _:
					compilations[compilations.length - 1].push(arg);
			}
		}
		return [for (compilation in compilations) common.concat(compilation)];
	}

	/** The debugger a compilation's output needs, from the first output flag in its arguments. **/
	public static function targetOf(args:Array<String>):Null<String> {
		for (arg in args) {
			switch arg {
				case "--interp" | "--run" | "-x":
					return "eval";
				case "-cpp" | "--cpp":
					return "hxcpp";
				case "-js" | "--js" | "-hl" | "--hl" | "-neko" | "--neko" | "-python" | "--python" | "-lua" | "--lua" | "-php" | "--php" | "-cs" |
					"--cs" | "-java" | "--java" | "--jvm" | "-swf" | "--swf" | "--cppia" | "--custom-target":
					return ~/^-+/.replace(arg, "");
				case _:
			}
		}
		return null;
	}

	/**
		The hxml to debug when the configuration names none: the one the language server uses
		(`project.target`), else one that runs in eval, else the only one there is.
	**/
	static function defaultHxml(projectRoot:String, settings:ProjectSettings):String {
		final target = settings.target;
		if (target != null && StringTools.endsWith(target, ".hxml")) {
			return absolute(projectRoot, target);
		}
		final found = [
			for (file in Files.findByExtension(projectRoot, ".hxml", 3))
				if (Path.withoutDirectory(file.path) != "extraParams.hxml") file.path
		];
		for (path in found) {
			if (outputOf(Hxml.expand([path], Path.directory(path))) == "eval") {
				return path;
			}
		}
		return switch found {
			case [only]: only;
			case []: throw new LaunchError('There is no .hxml file in $projectRoot. Set "hxml" or "haxeArgs" in the debug configuration.');
			case _: throw new LaunchError('There are several .hxml files in $projectRoot. Set "hxml" in the debug configuration to pick one.');
		}
	}

	/** Haxe resolves the paths in an hxml from the folder it runs in, so an hxml elsewhere gets a `--cwd`. **/
	static function hxmlArgs(hxml:String, cwd:String):Array<String> {
		if (!FileSystem.exists(hxml)) {
			throw new LaunchError('$hxml doesn\'t exist.');
		}
		final dir = Path.directory(hxml);
		if (Path.normalize(dir) == Path.normalize(cwd)) {
			return [Path.withoutDirectory(hxml)];
		}
		return ["--cwd", js.node.Path.relative(cwd, dir), Path.withoutDirectory(hxml)];
	}

	static function installed(path:Null<String>, name:String):String {
		if (path == null || !FileSystem.exists(path)) {
			throw new LaunchError('$name isn\'t installed${path == null ? "" : ' (expected at $path)'}.');
		}
		return path;
	}

	public static function absolute(base:String, path:String):String {
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
	}
}
