import bridge.Plan;
import bridge.Settings.ProjectSettings;
import bridge.targets.Ceramic;
import bridge.targets.EvalCompletions;
import bridge.targets.HashLink;
import bridge.targets.Lime;
import bridge.targets.Hxcpp;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import utest.Assert;

using Lambda;

/** Turning a debug configuration into a plan: which hxml, which debugger, which Haxe. **/
class PlanTest extends utest.Test {
	function testTargetOfOutputFlags() {
		Assert.equals("eval", Planner.targetOf(["-cp", "src", "-main", "Main", "--interp"]));
		Assert.equals("eval", Planner.targetOf(["-cp", "src", "--run", "Main"]));
		Assert.equals("hxcpp", Planner.targetOf(["-main", "Main", "--cpp", "bin"]));
		Assert.equals("hl", Planner.targetOf(["--hl", "main.hl"]));
		Assert.equals("js", Planner.targetOf(["-js", "main.js"]));
		Assert.isNull(Planner.targetOf(["-cp", "src", "-main", "Main"]));
	}

	function testPicksTheHxmlThatRunsInEval() {
		final dir = Fixture.create({
			"build-js.hxml": "-cp src\n-main Main\n--js out.js",
			"run.hxml": "-cp src\n-main Main\n--interp"
		});
		final plan = plan(dir, {request: "launch"});
		Assert.equals("eval", plan.target);
		Assert.same(["run.hxml"], plan.arguments.args);
	}

	function testUsesTheLanguageServersHxml() {
		final dir = Fixture.create({"run.hxml": "--interp", "tools/check.hxml": "-cp src\n-main Check\n--interp"});
		final plan = plan(dir, {request: "launch"}, {target: "tools/check.hxml"});
		// Haxe reads the hxml's paths from the folder it runs in.
		Assert.same(["--cwd", "tools", "check.hxml"], plan.arguments.args);
	}

	function testHaxeArgsAreUsedAsGiven() {
		final dir = Fixture.create({"run.hxml": "--interp"});
		final plan = plan(dir, {request: "launch", haxeArgs: ["-cp", "src", "-main", "Main", "--interp"]});
		Assert.same(["-cp", "src", "-main", "Main", "--interp"], plan.arguments.args);
	}

	function testEvalDebugsTheMacrosOfOtherTargets() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--js out.js"});
		final plan = plan(dir, {request: "launch", target: "eval", hxml: "build.hxml"});
		Assert.same(["build.hxml", "--no-output"], plan.arguments.args);
	}

	function testOtherTargetsAreNotSupportedYet() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--python main.py"});
		final error = launchError(() -> plan(dir, {request: "launch"}));
		Assert.stringContains("python builds isn't supported yet", error);
		Assert.stringContains('"target": "eval"', error);
	}

	function testHxcppBuildsWithTheDebugServer() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main app.Main\n--cpp bin\n--cmd bin/Main"});
		final plan = plan(dir, {request: "launch", args: ["--fast"]});
		Assert.equals("hxcpp", plan.target);
		Assert.isTrue(plan.adapter.match(OwnHxcpp));
		final launch:HxcppLaunch = plan.arguments;
		// The --cmd would run the program without the debugger.
		Assert.same([
			"-cp", "src", "-main", "app.Main", "--cpp", "bin", "-debug", "-cp", server(dir), "--macro", "hxcpp.debug.jsonrpc.Macro.injectServer()",
			"-D", "hxcpp_debugger_build"
		], launch.build.args);
		Assert.equals(executable(dir, "bin/Main-debug"), launch.program);
		Assert.same(["--fast"], launch.args);
		Assert.equals(dir, launch.cwd);
		Assert.equals(0, launch.port);
	}

	function testHxcppKeepsTheBuildsOwnDebugServer() {
		final dir = Fixture.create({"build.hxml": "-main Main\n-lib hxcpp-debug-server:1.2.4\n-D HXCPP_DEBUG_PORT=7000\n--cpp bin"});
		final launch:HxcppLaunch = plan(dir, {request: "launch"}).arguments;
		Assert.same(["-main", "Main", "-lib", "hxcpp-debug-server:1.2.4", "-D", "HXCPP_DEBUG_PORT=7000", "--cpp", "bin", "-debug"], launch.build.args);
		Assert.equals(7000, launch.port);
	}

	function testHxcppBuildsOnlyTheCppCompilation() {
		final dir = Fixture.create({"build.hxml": "-cp src\n--each\n-main A\n--python a.py\n--next\n-main B\n--cpp out\n-D HAXE_OUTPUT_FILE=game"});
		final launch:HxcppLaunch = plan(dir, {request: "launch"}).arguments;
		Assert.same(["-cp", "src", "-main", "B", "--cpp", "out", "-D", "HAXE_OUTPUT_FILE=game"], launch.build.args.slice(0, 8));
		Assert.equals(executable(dir, "out/game"), launch.program);
	}

	function testHxcppRunsAProgramAlreadyBuilt() {
		final dir = Fixture.create({"src/Main.hx": ""});
		final plan = plan(dir, {request: "launch", program: "bin/Main-debug"});
		Assert.equals("hxcpp", plan.target);
		final launch:HxcppLaunch = plan.arguments;
		Assert.isNull(launch.build);
		Assert.equals(Path.join([dir, "bin", "Main-debug"]), launch.program);
		// Built by someone else, so with a debug server that may only know its compiled-in port.
		Assert.equals(Hxcpp.defaultPort, launch.port);
	}

	function testCppiaBuildsTheScriptAndRunsTheHost() {
		final dir = Fixture.create({"script.hxml": "-cp src\n-main Script\n--cppia bin/script.cppia\n--cmd hl"});
		final plan = plan(dir, {request: "launch", hxml: "script.hxml", program: "bin/host/Host-debug"});
		Assert.equals("cppia", plan.target);
		final launch:HxcppLaunch = plan.arguments;
		Assert.same(["-cp", "src", "-main", "Script", "--cppia", "bin/script.cppia", "-debug"], launch.build.args);
		Assert.equals(Path.join([dir, "bin", "host", "Host-debug"]), launch.program);
		Assert.same([Path.join([dir, "bin", "script.cppia"])], launch.args);
		// The host is built elsewhere.
		Assert.equals(Hxcpp.defaultPort, launch.port);
	}

	function testCppiaNeedsAHost() {
		final dir = Fixture.create({"script.hxml": "-main Script\n--cppia script.cppia"});
		Assert.stringContains("runs in a host", launchError(() -> plan(dir, {request: "launch", hxml: "script.hxml"})));
	}

	function testHashLinkBuildsWithDebugInformation() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--hl bin/main.hl\n--cmd hl bin/main.hl"});
		final plan = plan(dir, {request: "launch", args: ["one"]});
		Assert.equals("hl", plan.target);
		Assert.isTrue(plan.adapter.match(Node(_)));
		Assert.same(["-cp", "src", "-main", "Main", "--hl", "bin/main.hl", "-debug"], plan.prelaunch.build.args);
		final launch:HashLinkLaunch = plan.arguments;
		Assert.equals(Path.join([dir, "bin", "main.hl"]), launch.program);
		Assert.equals("hl", launch.hl);
		Assert.same(["one"], launch.args);
		Assert.equals(dir, launch.cwd);
		// hashlink-debugger gives the VM exactly this environment: all of it, not only the additions.
		final inherited = [for (name in Reflect.fields(process.env)) name][0];
		Assert.equals(Reflect.field(process.env, inherited), launch.env.get(inherited));
	}

	// Runs a stand-in script, which Windows starts slowly.
	@:timeout(10000)
	function testHashLinkGetsTheClassPathsFromTheBuild(async:utest.Async) {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--hl bin/main.hl"});
		// Does what the build's helper macro does: writes the class paths, its own folder among them.
		final haxe = Fixture.script(dir, "fake/haxe", "
			const fs = require('fs'), path = require('path');
			const args = process.argv.slice(2);
			if (args[0] === '--version') { console.log('4.3.7'); process.exit(0); }
			const helper = args[args.indexOf('-cp', args.indexOf('-debug')) + 1];
			const file = JSON.parse(/\\((.*)\\)$/.exec(args[args.indexOf('--macro') + 1])[1]);
			fs.writeFileSync(file, JSON.stringify([helper, path.resolve('src'), path.resolve('.'), '/std/hl/_std/', '/std/']));
			fs.mkdirSync('bin', {recursive: true});
			fs.writeFileSync('bin/main.hl', '');
			console.log('built');
		");
		final plan = plan(dir, {request: "launch", haxePath: haxe});
		final output = [];
		plan.prelaunch.run(text -> output.push(text)).then(function(arguments:HashLinkLaunch) {
			// The build's own separators, which are \ on Windows.
			Assert.same([Path.join([dir, "src"]), dir, "/std/hl/_std/", "/std/"].map(Path.normalize), arguments.classPaths.map(Path.normalize));
			Assert.isTrue(output.join("").indexOf("built") >= 0);
			async.done();
		}, function(error) {
			Assert.fail(Std.string(error));
			async.done();
		});
	}

	function testHashLinkCIsRejected() {
		final dir = Fixture.create({"build.hxml": "-main Main\n--hl out/main.c"});
		Assert.stringContains("HashLink/C", launchError(() -> plan(dir, {request: "launch"})));
	}

	function testHashLinkNeedsABuild() {
		final dir = Fixture.create({"src/Main.hx": ""});
		Assert.stringContains("builds HashLink programs itself", launchError(() -> plan(dir, {request: "launch", program: "bin/main.hl"})));
	}

	function testJavaScriptBuildsWithSourceMaps() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--js bin/main.js\n--cmd node bin/main.js"});
		final plan = plan(dir, {request: "launch", args: ["one"]});
		Assert.equals("js", plan.target);
		Assert.isTrue(plan.adapter.match(JsDebug(_)));
		Assert.same(["-cp", "src", "-main", "Main", "--js", "bin/main.js", "-debug", "-D", "js-source-map"], plan.prelaunch.build.args);
		final launch:Dynamic = plan.arguments;
		Assert.equals("pwa-node", launch.type);
		Assert.equals(Path.join([dir, "bin", "main.js"]), launch.program);
		Assert.same(["one"], launch.args);
		// Without these, js-debug doesn't take breakpoints in .hx files.
		Assert.equals(dir, launch.__workspaceFolder);
		Assert.isFalse(launch.pauseForSourceMap);
	}

	function testJavaScriptPagesOpenInABrowser() {
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--js bin/main.js"});
		final plan = plan(dir, {request: "launch", webRoot: "bin", browser: "/opt/chromium/chrome"});
		Assert.equals("js", plan.target);
		Assert.same(["-cp", "src", "-main", "Main", "--js", "bin/main.js", "-debug", "-D", "js-source-map"], plan.prelaunch.build.args);
		final launch:Dynamic = plan.arguments;
		Assert.equals("pwa-chrome", launch.type);
		Assert.equals(Path.join([dir, "bin"]), launch.webRoot);
		Assert.equals("/opt/chromium/chrome", launch.runtimeExecutable);
		// Filled in when the bridge serves the folder.
		Assert.isNull(launch.url);
		Assert.equals(dir, launch.__workspaceFolder);
	}

	function testJavaScriptRunsAProgramAlreadyBuilt() {
		final dir = Fixture.create({"src/Main.hx": ""});
		final plan = plan(dir, {request: "launch", program: "bin/main.js"});
		Assert.equals("js", plan.target);
		Assert.isNull(plan.prelaunch);
		Assert.equals(Path.join([dir, "bin", "main.js"]), plan.arguments.program);
	}

	function testLimeCommandsAreRead() {
		final command = Lime.parse(["haxelib", "run", "lime", "test", "project.xml", "linux", "-final"]);
		Assert.same(["haxelib", "run", "lime"], command.tool);
		Assert.equals("test", command.action);
		Assert.equals("project.xml", command.projectFile);
		Assert.equals("linux", command.target);
		Assert.same(["-final"], command.flags);
		Assert.equals("hl", Lime.parse(["openfl", "build", "hl", "-debug"]).target);
		Assert.isNull(Lime.parse(["haxe", "build.hxml"]));
	}

	function testLimeDebugsANativeBuildThroughLimeTest() {
		final dir = Fixture.create({"project.xml": "<project/>"});
		final plan = plan(dir, {request: "launch", command: ["haxelib", "run", "lime", "build", "project.xml", "linux", "-final"]});
		Assert.equals("hxcpp", plan.target);
		final launch:HxcppLaunch = plan.arguments;
		Assert.isTrue(launch.launcher);
		Assert.equals("haxelib", launch.program);
		// A debug build that Lime also runs, with the debug server added through --haxeflag.
		Assert.same([
			"run", "lime", "test", Path.join([dir, "project.xml"]), "linux", "-debug", "-nocolor", '--haxeflag=-cp ${server(dir)}',
			"--haxeflag=--macro hxcpp.debug.jsonrpc.Macro.injectServer()", "--haxeflag=-D hxcpp_debugger_build"
		], launch.args);
		// The project file's folder, with Haxe's separators.
		Assert.equals(Path.normalize(dir), Path.normalize(launch.cwd));
		Assert.equals(0, launch.port);
	}

	function testLimeProjectsNeedNoConfiguration() {
		final dir = Fixture.create({"game/Project.xml": "<project/>"});
		// The target the language server uses.
		final plan = plan(dir, {request: "launch"}, {target: "hl"});
		Assert.equals("hl", plan.target);
		Assert.same(["run", "lime", "build", Path.join([dir, "game", "Project.xml"]), "hl", "-debug", "-nocolor"], plan.prelaunch.build.args);
		Assert.equals(Path.join([dir, "game"]), plan.prelaunch.build.cwd);
	}

	function testLimeKeepsTheProjectsOwnDebugServer() {
		final dir = Fixture.create({"project.xml": '<project><haxelib name="hxcpp-debug-server" if="debug"/></project>'});
		final launch:HxcppLaunch = plan(dir, {request: "launch", command: ["lime", "test", "linux"]}).arguments;
		Assert.isFalse(launch.args.exists(arg -> StringTools.startsWith(arg, "--haxeflag")));
		Assert.equals(Hxcpp.defaultPort, launch.port);
	}

	function testLimeHtml5BuildsWithSourceMaps() {
		final dir = Fixture.create({"project.xml": "<project/>"});
		final plan = plan(dir, {request: "launch", command: ["lime", "test", "html5", "-release"]});
		Assert.equals("js", plan.target);
		Assert.isTrue(plan.adapter.match(JsDebug(_)));
		Assert.same(["build", "html5", "-debug", "-nocolor", "--haxeflag=-D js-source-map"], plan.prelaunch.build.args);
		Assert.equals("pwa-chrome", plan.arguments.type);
	}

	function testCeramicCommandsAreRead() {
		final command = Ceramic.parse(["ceramic", "clay", "run", "linux", "--setup", "--assets", "--variant", "demo"]);
		Assert.equals("clay", command.backend);
		Assert.equals("linux", command.target);
		Assert.same(["--variant", "demo"], command.flags);
		Assert.equals("hxcpp", Ceramic.debugger("mac"));
		Assert.equals("js", Ceramic.debugger("web"));
		Assert.isNull(Ceramic.parse(["lime", "test", "linux"]));
	}

	function testCeramicProjectsNeedNoConfiguration() {
		final dir = Fixture.create({"ceramic.yml": "app:\n  name: demo\n"});
		// Zed-Haxe's default Ceramic target, web, which runs in a browser.
		final plan = plan(dir, {request: "launch"});
		Assert.equals("js", plan.target);
		Assert.isTrue(plan.adapter.match(JsDebug(_)));
		Assert.equals("ceramic", plan.prelaunch.build.executable);
		Assert.same(["clay", "build", "web", "--setup", "--assets", "--debug"], plan.prelaunch.build.args);
		Assert.equals("pwa-chrome", plan.arguments.type);
	}

	// Runs a stand-in script, which Windows starts slowly.
	@:timeout(10000)
	function testCeramicDesktopAddsTheDebugServerToItsHxml(async:utest.Async) {
		final dir = Fixture.create({"ceramic.yml": "app:\n  name: demo\n"});
		// Writes the hxml as `ceramic clay setup linux --debug` does.
		final ceramic = Fixture.script(dir, "tools/ceramic", "
			const fs = require('fs');
			fs.mkdirSync('out/clay/linux-debug', {recursive: true});
			fs.writeFileSync('out/clay/linux-debug/project.hxml', '-main Main\\n--cpp out\\n');
		");
		final plan = plan(dir, {request: "launch", command: [ceramic, "clay", "run", "linux", "--setup", "--assets"]});
		Assert.equals("hxcpp", plan.target);
		Assert.same(["clay", "setup", "linux", "--debug"], plan.prelaunch.build.args);
		final launch:HxcppLaunch = plan.arguments;
		Assert.isTrue(launch.launcher);
		Assert.same(["clay", "run", "linux", "--assets", "--debug", "--no-skip"], launch.args);
		plan.prelaunch.run(_ -> {}).then(function(_) {
			final hxml = sys.io.File.getContent(Path.join([dir, "out", "clay", "linux-debug", "project.hxml"]));
			Assert.stringContains('-cp ${server(dir)}', hxml);
			Assert.stringContains("--macro hxcpp.debug.jsonrpc.Macro.injectServer()", hxml);
			Assert.stringContains("-D hxcpp_debugger_build", hxml);
			async.done();
		}, function(error) {
			Assert.fail(Std.string(error));
			async.done();
		});
	}

	function testUnknownCommandsNeedATarget() {
		final dir = Fixture.create({"build.sh": ""});
		Assert.stringContains('"target": "hxcpp"', launchError(() -> plan(dir, {request: "launch", command: ["./build.sh"]})));
		final launch:HxcppLaunch = plan(dir, {request: "launch", command: ["./build.sh", "run"], target: "hxcpp"}).arguments;
		Assert.isTrue(launch.launcher);
		Assert.same(["run"], launch.args);
	}

	function testHxcppStopsEveryThreadUnlessToldOtherwise() {
		final dir = Fixture.create({"build.hxml": "-main Main\n--cpp bin"});
		final launch = (config, ?settings) -> (plan(dir, config, settings).arguments : HxcppLaunch).stopAllThreads;
		Assert.isTrue(launch({request: "launch"}));
		// The project's setting, unless the configuration says.
		Assert.isFalse(launch({request: "launch"}, {debug: {stopAllThreads: false}}));
		Assert.isTrue(launch({request: "launch", stopAllThreads: true}, {debug: {stopAllThreads: false}}));
	}

	function testHxcppNeedsTheDebugServer() {
		final dir = Fixture.create({"build.hxml": "-main Main\n--cpp bin"});
		final haxe = Fixture.script(dir, "haxe4/haxe", "console.log('4.3.7')");
		final error = launchError(() -> Planner.plan({request: "launch", haxePath: haxe}, {}, {eval: adapter(dir)}, dir, process.env));
		Assert.stringContains("hxcpp-debug-server isn't installed", error);
	}

	function testMissingHxmlIsReported() {
		final dir = Fixture.create({"src/Main.hx": ""});
		Assert.stringContains("There is no .hxml file", launchError(() -> plan(dir, {request: "launch"})));
		Assert.stringContains("doesn't exist", launchError(() -> plan(dir, {request: "launch", hxml: "nope.hxml"})));
	}

	function testRunsEvalDebuggerInTheProjectFolder() {
		final dir = Fixture.create({"run.hxml": "--interp"});
		final plan = plan(dir, {request: "launch"});
		Assert.equals(dir, plan.cwd);
		// eval-debugger passes cwd to a shell unquoted.
		Assert.equals(".", plan.arguments.cwd);
	}

	function testHaxercPicksTheHaxeManagerVersion() {
		final root = Fixture.create({"versions/4.3.7/std/StdTypes.hx": ""});
		Fixture.script(root, "bin/hx", "");
		final haxe = Fixture.script(root, "versions/4.3.7/haxe", "console.log('4.3.7')");
		final dir = Fixture.create({".haxerc": '{"version": "4.3.7"}', "run.hxml": "--interp"});
		final env:DynamicAccess<String> = process.env.copy();
		env.set("PATH", Path.join([root, "bin"]));
		final plan = Planner.plan({request: "launch"}, {}, {eval: adapter(dir)}, dir, env);
		Assert.equals(haxe, plan.arguments.haxeExecutable.executable);
		Assert.equals(Path.join([root, "versions", "4.3.7", "std"]), plan.arguments.haxeExecutable.env.HAXE_STD_PATH);
	}

	function testHaxe3IsRejected() {
		final dir = Fixture.create({"run.hxml": "--interp"});
		final haxe = Fixture.script(dir, "old/haxe", "console.log('3.4.7')");
		Assert.stringContains("needs Haxe 4", launchError(() -> plan(dir, {request: "launch", haxePath: haxe})));
	}

	function testHaxe5HidesCompletions() {
		final dir = Fixture.create({"run.hxml": "--interp"});
		final haxe5 = Fixture.script(dir, "five/haxe", "console.log('5.0.0-preview.1+066bd83')");
		Assert.isTrue(plan(dir, {request: "launch", haxePath: haxe5}).filters.exists(f -> Std.isOfType(f, EvalCompletions)));
		Assert.isFalse(plan(dir, {request: "launch"}).filters.exists(f -> Std.isOfType(f, EvalCompletions)));
	}

	/** Plans with a fake Haxe 4.3.7 unless the configuration names one. **/
	static function plan(dir:String, config:LaunchConfig, ?settings:ProjectSettings):Plan {
		if (config.haxePath == null) {
			config.haxePath = Fixture.script(dir, "haxe4/haxe", "console.log('4.3.7')");
		}
		return Planner.plan(config, settings ?? {}, {eval: adapter(dir), hxcppDebugServer: server(dir), hashlink: adapter(dir), jsDebug: adapter(dir)}, dir, process.env);
	}

	static function server(dir:String):String {
		return Path.join([dir, "server"]);
	}

	/** The path of an hxcpp executable on this system. **/
	static function executable(dir:String, path:String):String {
		return Path.join([dir, process.platform == "win32" ? '$path.exe' : path]);
	}

	/** A stand-in for eval-debugger's index.js. **/
	static function adapter(dir:String):String {
		final path = Path.join([dir, "adapter", "index.js"]);
		sys.FileSystem.createDirectory(Path.directory(path));
		sys.io.File.saveContent(path, "");
		return path;
	}

	static function launchError(run:() -> Void):String {
		try {
			run();
		} catch (e:LaunchError) {
			return e.message;
		}
		return "(no error)";
	}
}
