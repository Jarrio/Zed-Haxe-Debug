package bridge.targets;

import bridge.Plan;
import bridge.dap.BodylessResponses;
import bridge.dap.Filter;
import bridge.toolchain.Toolchain.ResolvedToolchain;

/**
	vshaxe's eval-debugger (https://github.com/vshaxe/eval-debugger). It runs Haxe with `-D eval-debugger`,
	which stops macros and `--interp` programs at breakpoints.
**/
class Eval {
	/** Workarounds for the debugger and the compiler's side of it. **/
	public static function filters(config:LaunchConfig, toolchain:ResolvedToolchain):Array<Filter> {
		final filters:Array<Filter> = [new BodylessResponses(), new EvalThreads(), new EvalFrameNames()];
		if (toolchain.major >= 5) {
			filters.push(new EvalCompletions());
		}
		// vshaxe's default.
		if (config.mergeScopes ?? true) {
			filters.push(new EvalScopes());
		}
		return filters;
	}

	/** The `launch` arguments eval-debugger expects (its `EvalLaunchRequestArguments`). **/
	public static function arguments(config:LaunchConfig, haxeArgs:Array<String>, output:Null<String>, toolchain:ResolvedToolchain):Dynamic {
		if (toolchain.major > 0 && toolchain.major < 4) {
			throw new LaunchError('eval-debugger needs Haxe 4 or newer; ${toolchain.path} is ${toolchain.version}.');
		}
		// Debugging another target's build in eval only runs its macros, so skip generating and compiling its output.
		final args = output == null || output == "eval" ? haxeArgs : haxeArgs.concat(["--no-output"]);
		return {
			// eval-debugger runs Haxe through a shell without quoting its arguments, so a folder with a space
			// in its name would break `--cwd <folder>`. The bridge starts it in that folder instead.
			cwd: ".",
			args: args,
			stopOnEntry: config.stopOnEntry ?? false,
			haxeExecutable: {executable: toolchain.path, env: toolchain.env},
			// The bridge merges the scopes itself (see EvalScopes).
			mergeScopes: false,
			// vshaxe's default.
			showGeneratedVariables: config.showGeneratedVariables ?? false,
			trace: false
		};
	}
}
