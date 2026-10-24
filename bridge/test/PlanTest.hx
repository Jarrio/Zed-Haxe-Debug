import bridge.Plan;
import bridge.Settings.ProjectSettings;
import bridge.targets.EvalCompletions;
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
		final dir = Fixture.create({"build.hxml": "-cp src\n-main Main\n--hl main.hl"});
		final error = launchError(() -> plan(dir, {request: "launch"}));
		Assert.stringContains("hl builds isn't supported yet", error);
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
			"-cp", "src", "-main", "app.Main", "--cpp", "bin", "-debug", "-cp", server(dir), "--macro", "hxcpp.debug.jsonrpc.Macro.injectServer()"
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
		final dir = Fixture.create({"build.hxml": "-cp src\n--each\n-main A\n--js a.js\n--next\n-main B\n--cpp out\n-D HAXE_OUTPUT_FILE=game"});
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
		return Planner.plan(config, settings ?? {}, {eval: adapter(dir), hxcppDebugServer: server(dir)}, dir, process.env);
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
