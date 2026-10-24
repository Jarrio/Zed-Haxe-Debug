package bridge.toolchain;

import bridge.Settings.ProjectSettings;
import bridge.toolchain.Resolvers;
import bridge.toolchain.ToolchainResolver;
import bridge.util.Exec;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.io.Path;
import js.node.Fs;
import sys.FileSystem;

typedef ResolvedToolchain = {
	final path:String;
	final env:DynamicAccess<String>;

	/** Which resolver picked it (`"settings"`, `"provider"`, `"lix"`, ...). **/
	final source:String;

	/** Output of `haxe --version`, or null if it couldn't be run. **/
	final version:Null<String>;

	/** Major version number, or 0 when unknown. **/
	final major:Int;

	final notes:Array<String>;
}

class Toolchain {
	public static final defaultOrder = ["provider", "lix", "haxe-manager", "path"];

	/** Resolvers written in Haxe. Users can reorder them with `project.haxeResolvers`. **/
	static function builtInResolvers():Array<ToolchainResolver> {
		return [new ProviderResolver(), new LixResolver(), new HaxeManagerResolver(), new PathResolver()];
	}

	public static function resolve(ctx:ToolchainContext, settings:ProjectSettings):ResolvedToolchain {
		final notes = [];
		var choice:Null<ToolchainChoice> = null;
		var source = "settings";
		if (settings.haxePath != null) {
			choice = {path: settings.haxePath};
		} else {
			final available = new Map<String, ToolchainResolver>();
			for (resolver in builtInResolvers()) {
				available.set(resolver.name, resolver);
			}
			for (definition in settings.resolvers ?? []) {
				available.set(definition.name, new CommandResolver(definition));
			}
			for (name in settings.haxeResolvers ?? defaultOrder) {
				final resolver = available.get(name);
				if (resolver == null) {
					notes.push('Unknown toolchain resolver "$name" in project.haxeResolvers.');
					continue;
				}
				choice = resolver.resolve(ctx, notes);
				if (choice != null) {
					source = name;
					break;
				}
			}
		}
		if (choice == null) {
			choice = {path: "haxe"};
			source = "default";
		}

		final env:DynamicAccess<String> = choice.env ?? {};
		// A Haxe install keeps its std next to the binary. Point HAXE_STD_PATH there, or a
		// HAXE_STD_PATH from the user's shell (e.g. haxe-manager's "current") would win.
		if (!env.exists("HAXE_STD_PATH")) {
			final std = siblingStd(choice.path, ctx.env);
			if (std != null) {
				env.set("HAXE_STD_PATH", std);
			}
		}
		final version = readVersion(choice.path, ctx, env);
		return {
			path: choice.path,
			env: env,
			source: source,
			version: version,
			major: version == null ? 0 : (Std.parseInt(version.split(".")[0]) ?? 0),
			notes: notes
		};
	}

	static function siblingStd(path:String, env:DynamicAccess<String>):Null<String> {
		final binary = Path.isAbsolute(path) ? path : Files.which(path, env);
		if (binary == null) {
			return null;
		}
		final real = try Fs.realpathSync(binary) catch (_) binary;
		final std = Path.join([Path.directory(real), "std"]);
		return FileSystem.exists(Path.join([std, "StdTypes.hx"])) ? std : null;
	}

	static function readVersion(path:String, ctx:ToolchainContext, extraEnv:DynamicAccess<String>):Null<String> {
		final env = ctx.env.copy();
		for (key => value in extraEnv) {
			env.set(key, value);
		}
		// Haxe 3 only knows `-version`.
		for (flag in ["--version", "-version"]) {
			final result = Exec.runSync([path, flag], {cwd: ctx.projectRoot, env: env});
			if (result != null && result.code == 0) {
				// Old Haxe versions print the version on stderr.
				final output = StringTools.trim(result.stdout) != "" ? result.stdout : result.stderr;
				return StringTools.trim(output);
			}
		}
		return null;
	}
}
