package bridge;

import bridge.Build.HaxeRun;
import bridge.Settings.ProjectSettings;
import bridge.dap.BodylessResponses;
import bridge.dap.Filter;
import bridge.project.HaxeArgs;
import bridge.project.Hxml;
import bridge.targets.Ceramic;
import bridge.targets.Eval;
import bridge.targets.HashLink;
import bridge.targets.HashLinkOutput;
import bridge.targets.HashLinkSignal;
import bridge.targets.JavaScript;
import bridge.targets.Lime;
import bridge.targets.Hxcpp;
import bridge.toolchain.Haxerc;
import bridge.toolchain.Toolchain;
import bridge.toolchain.Toolchain.ResolvedToolchain;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.lib.Promise;
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
	var ?hl:String;
	var ?runtimeExecutable:String;
	var ?command:Array<String>;
	var ?url:String;
	var ?webRoot:String;
	var ?browser:String;
	var ?args:Array<String>;
	var ?env:DynamicAccess<String>;
	var ?port:Int;
	var ?stopAllThreads:Bool;
}

/** What the extension has downloaded for the debuggers. **/
typedef Adapters = {
	/** eval-debugger's index.js. **/
	var ?eval:String;

	/** The hxcpp-debug-server library, which the bridge compiles into hxcpp programs. **/
	var ?hxcppDebugServer:String;

	/** hashlink-debugger's adapter.js. **/
	var ?hashlink:String;

	/** js-debug's dapDebugServer.js. **/
	var ?jsDebug:String;
}

/** Work before the debugger gets `launch`, for a debugger that doesn't build the program itself. **/
typedef Prelaunch = {
	final build:HaxeRun;

	/**
		Runs the build, passing its output on, and resolves with the `launch` arguments. Rejects with a message
		for the user.
	**/
	final run:(output:String->Void) -> Promise<Dynamic>;
}

enum AdapterKind {
	/** `node <script>`. **/
	Node(script:String);

	/** The bridge's own hxcpp adapter. **/
	OwnHxcpp;

	/** js-debug's server script, run as one session (`JsDebugAdapter`). **/
	JsDebug(script:String);
}

/** A debugger ready to start in `cwd`, which then gets `launch` with `arguments`. **/
typedef Plan = {
	final target:String;
	final adapter:AdapterKind;
	final cwd:String;
	final arguments:Dynamic;

	/** Work around the debugger's quirks in the messages it sends Zed, in this order. **/
	final filters:Array<Filter>;

	final ?prelaunch:Prelaunch;
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
		final plan = planTarget(config, settings, adapters, workspaceRoot, env);
		if (plan.adapter.match(OwnHxcpp)) {
			// With hxcpp, whether a thread's stop stops the others: the configuration says, else the project.
			final launch:HxcppLaunch = plan.arguments;
			launch.stopAllThreads = config.stopAllThreads ?? settings.debug?.stopAllThreads ?? true;
		}
		return plan;
	}

	static function planTarget(config:LaunchConfig, settings:ProjectSettings, adapters:Adapters, workspaceRoot:String,
			env:DynamicAccess<String>):Plan {
		if (config.request != null && config.request != "launch") {
			throw new LaunchError('Haxe debugging supports only "request": "launch" so far.');
		}
		final projectRoot = settings.root == null ? workspaceRoot : absolute(workspaceRoot, settings.root);
		final cwd = config.cwd == null ? projectRoot : absolute(workspaceRoot, config.cwd);
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
		// A project built by its own tool, such as Lime, named or found.
		final nothingNamed = config.command == null && config.hxml == null && config.haxeArgs == null && config.program == null;
		final command = config.command ?? (nothingNamed ? toolCommand(projectRoot, settings) : null);
		if (command != null) {
			return planCommand(command, config, cwd, projectRoot, toolchain, adapters, env);
		}
		// A program that's already built needs no hxml.
		final prebuilt = config.program != null && config.haxeArgs == null && config.hxml == null;
		final haxeArgs = prebuilt ? [] : (config.haxeArgs ?? hxmlArgs(config.hxml == null ? defaultHxml(projectRoot, settings) : absolute(cwd, config.hxml), cwd));
		final output = outputOf(Hxml.expand(haxeArgs, cwd));
		final target = config.target ?? output ?? (prebuilt ? prebuiltTarget(config.program) : "eval");
		return switch target {
			case "eval":
				{
					target: target,
					adapter: Node(installed(adapters.eval, "eval-debugger")),
					cwd: cwd,
					arguments: Eval.arguments(config, haxeArgs, output, toolchain),
					filters: Eval.filters(config, toolchain)
				};
			case "hxcpp":
				{
					target: target,
					adapter: OwnHxcpp,
					cwd: cwd,
					arguments: Hxcpp.launch(config, haxeArgs, cwd, toolchain, adapters.hxcppDebugServer),
					filters: []
				};
			case "hl":
				final launch = HashLink.launch(config, haxeArgs, cwd, toolchain);
				{
					target: target,
					adapter: Node(installed(adapters.hashlink, "hashlink-debugger")),
					cwd: cwd,
					arguments: launch.arguments,
					filters: [new BodylessResponses(), new HashLinkOutput(), new HashLinkSignal()],
					prelaunch: HashLink.prelaunch(launch.arguments, launch.build)
				};
			case "js":
				final launch = JavaScript.launch(config, haxeArgs, cwd, projectRoot, toolchain, env);
				{
					target: target,
					adapter: JsDebug(installed(adapters.jsDebug, "js-debug")),
					cwd: cwd,
					arguments: launch.arguments,
					filters: [],
					prelaunch: launch.arguments.type == "pwa-chrome" ? JavaScript.browserPrelaunch(launch.arguments, launch.build,
						() -> Promise.resolve(launch.arguments.webRoot)) : launch.build == null ? null : JavaScript.prelaunch(launch.arguments,
						launch.build)
				};
			case "cppia":
				{
					target: target,
					adapter: OwnHxcpp,
					cwd: cwd,
					arguments: Hxcpp.cppia(config, haxeArgs, cwd, toolchain),
					filters: []
				};
			case other:
				throw new LaunchError('Debugging $other builds isn\'t supported yet. To debug this build\'s macros, set "target": "eval".');
		}
	}

	/**
		The command that builds and runs a project whose tool the bridge knows, when the configuration names
		nothing to build: Lime's for a Lime project, with the target the language server uses or else this
		desktop's, and Ceramic's for a Ceramic project, with the language server's target or else web. Null
		for a plain hxml project.
	**/
	static function toolCommand(projectRoot:String, settings:ProjectSettings):Null<Array<String>> {
		final provider = settings.provider;
		final limeProject = provider == null || provider == "lime" ? Lime.find(projectRoot) : null;
		if (limeProject != null) {
			final target = Lime.isTarget(settings.target) ? settings.target : Lime.hostTarget();
			return ["haxelib", "run", "lime", "test", limeProject, target];
		}
		if ((provider == null || provider == "ceramic") && Ceramic.find(projectRoot) != null) {
			// Zed-Haxe's default Ceramic target is web.
			final target = settings.target ?? "web";
			final backend = switch target {
				case "node": "headless";
				case "unity": "unity";
				case _: "clay";
			}
			return ["ceramic", backend, "run", target, "--setup", "--assets"];
		}
		return null;
	}

	/** A session for a command that builds and starts the program, such as `lime test linux`. **/
	static function planCommand(command:Array<String>, config:LaunchConfig, cwd:String, projectRoot:String, toolchain:ResolvedToolchain,
			adapters:Adapters, env:DynamicAccess<String>):Plan {
		final lime = Lime.parse(command);
		if (lime != null) {
			final target = Lime.debugger(lime.target ?? Lime.hostTarget());
			return switch target {
				case "hxcpp":
					{
						target: target,
						adapter: OwnHxcpp,
						cwd: cwd,
						arguments: Lime.hxcpp(lime, config, cwd, toolchain, env, adapters.hxcppDebugServer),
						filters: []
					};
				case "hl":
					final launch = Lime.hashlink(lime, config, cwd, toolchain, env);
					{
						target: target,
						adapter: Node(installed(adapters.hashlink, "hashlink-debugger")),
						cwd: cwd,
						arguments: launch.arguments,
						filters: [new BodylessResponses(), new HashLinkOutput(), new HashLinkSignal()],
						prelaunch: launch.prelaunch
					};
				case "html5":
					final launch = Lime.html5(lime, config, cwd, projectRoot, toolchain, env);
					{
						target: "js",
						adapter: JsDebug(installed(adapters.jsDebug, "js-debug")),
						cwd: cwd,
						arguments: launch.arguments,
						filters: [],
						prelaunch: launch.prelaunch
					};
				case other:
					throw new LaunchError('Debugging Lime\'s $other target isn\'t supported yet. Desktop targets (linux, windows, mac), hl and html5 are.');
			}
		}
		final ceramic = Ceramic.parse(command);
		if (ceramic != null) {
			final project = Ceramic.find(cwd);
			final dir = project == null ? cwd : Path.directory(project);
			return switch Ceramic.debugger(ceramic.target) {
				case "hxcpp":
					final launch = Ceramic.hxcpp(ceramic, config, dir, adapters.hxcppDebugServer);
					{
						target: "hxcpp",
						adapter: OwnHxcpp,
						cwd: dir,
						arguments: launch.arguments,
						filters: [],
						prelaunch: launch.prelaunch
					};
				case "js":
					final launch = Ceramic.web(ceramic, config, dir, projectRoot, env);
					{
						target: "js",
						adapter: JsDebug(installed(adapters.jsDebug, "js-debug")),
						cwd: dir,
						arguments: launch.arguments,
						filters: [],
						prelaunch: launch.prelaunch
					};
				case other:
					throw new LaunchError('Debugging Ceramic\'s $other target isn\'t supported yet. Desktop targets (linux, mac, windows) and web are.');
			}
		}
		if (config.target == "hxcpp") {
			// Any other tool that builds and starts an hxcpp program with hxcpp-debug-server: the program connects back.
			return {
				target: "hxcpp",
				adapter: OwnHxcpp,
				cwd: cwd,
				arguments: ({
					build: null,
					program: command[0],
					args: command.slice(1),
					cwd: cwd,
					env: Lime.toolEnvironment(toolchain, env),
					port: config.port ?? Hxcpp.defaultPort,
					launcher: true
				} : HxcppLaunch),
				filters: []
			};
		}
		throw new LaunchError('The debugger doesn\'t know what `${command.join(" ")}` builds. If it starts an hxcpp program built with -debug and hxcpp-debug-server, set "target": "hxcpp".');
	}

	/** The debugger for a program named without a build, from its file name. **/
	static function prebuiltTarget(program:String):String {
		return switch Path.extension(program) {
			case "hl": "hl";
			case "js" | "cjs" | "mjs": "js";
			case _: "hxcpp";
		}
	}

	/** The outputs a debugger here supports. **/
	static final supported = ["eval", "hxcpp", "cppia", "hl", "js"];

	/**
		The debugger a build needs: that of the first compilation in it that a debugger here supports, else
		that of the first output. Null when there's no output: such a build only types the code, and eval
		can debug its macros.
	**/
	public static function outputOf(args:Array<String>):Null<String> {
		final targets = [for (compilation in HaxeArgs.compilations(args)) targetOf(compilation)];
		for (target in targets) {
			if (supported.contains(target)) {
				return target;
			}
		}
		return targets.filter(target -> target != null)[0];
	}

	/** The one compilation in `args` (see `HaxeArgs.compilations`) whose output needs `target`'s debugger. **/
	public static function compilationFor(args:Array<String>, target:String):Array<String> {
		final flag = switch target {
			case "hxcpp": "--cpp";
			case other: '--$other';
		}
		final found = [for (compilation in HaxeArgs.compilations(args)) if (targetOf(compilation) == target) compilation];
		return switch found {
			case [only]: only;
			case []: throw new LaunchError('The build has no $flag output to debug.');
			case _: throw new LaunchError('The build has ${found.length} $flag outputs. Pick one with "haxeArgs" in the debug configuration.');
		}
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
