package bridge.toolchain;

import bridge.toolchain.ToolchainResolver;
import bridge.util.Exec;
import bridge.util.Files;
import bridge.util.Vars;
import haxe.io.Path;
import js.node.Fs;
import sys.FileSystem;

/** Uses the Haxe the project provider asked for, e.g. Ceramic's bundled Haxe. **/
class ProviderResolver implements ToolchainResolver {
	public var name(default, null):String = "provider";

	public function new() {}

	public function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice> {
		return ctx.providerHaxePath == null ? null : {path: ctx.providerHaxePath};
	}
}

/** lix: a project-local `node_modules/.bin/haxe` shim, which reads `.haxerc` and `haxe_libraries/` itself. **/
class LixResolver implements ToolchainResolver {
	public var name(default, null):String = "lix";

	public function new() {}

	public function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice> {
		if (ctx.haxerc == null) {
			return null;
		}
		for (root in [ctx.projectRoot, ctx.workspaceRoot]) {
			final shim = Files.executableIn(Path.join([root, "node_modules", ".bin"]), "haxe");
			if (shim != null) {
				return {path: shim};
			}
		}
		return null;
	}
}

/**
	haxe-manager (https://github.com/kLabz/haxe-manager): picks the installed version that `.haxerc` asks for,
	the same binary `hx with rc` would run, without changing the globally selected version.
**/
class HaxeManagerResolver implements ToolchainResolver {
	public var name(default, null):String = "haxe-manager";

	public function new() {}

	public function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice> {
		if (ctx.haxerc == null) {
			return null;
		}
		final hx = Files.which("hx", ctx.env);
		if (hx == null) {
			return null;
		}
		// hx lives in <haxe-manager>/bin/
		final root = Path.directory(Path.directory(Fs.realpathSync(hx)));
		final version = ctx.haxerc.version;
		final dir = findVersion(root, version);
		if (dir == null) {
			final download = ~/^\d+\.\d+\.\d+/.match(version) ? 'hx download $version' : 'hx download nightly $version';
			notes.push('.haxerc asks for Haxe $version, which haxe-manager doesn\'t have installed. Run `$download`.');
			return null;
		}
		final haxe = Files.executableIn(dir, "haxe");
		if (haxe == null) {
			return null;
		}
		return {path: haxe, env: {HAXE_STD_PATH: Path.join([dir, "std"])}};
	}

	/**
		Matches the way haxe-manager names installs: `versions/<name>` (e.g. `4.3.7`, `5.0.0-preview.1+066bd83`)
		and `releases/haxe_<date>_<hash>`.
	**/
	public static function findVersion(root:String, version:String):Null<String> {
		final versions = Path.join([root, "versions"]);
		final releases = Path.join([root, "releases"]);
		final exact = Path.join([versions, version]);
		if (FileSystem.exists(exact)) {
			return exact;
		}
		for (entry in list(releases)) {
			if (StringTools.endsWith(entry, '_$version') && FileSystem.isDirectory(Path.join([releases, entry]))) {
				return Path.join([releases, entry]);
			}
		}
		for (entry in list(versions)) {
			if (StringTools.endsWith(entry, '+$version')) {
				return Path.join([versions, entry]);
			}
		}
		return null;
	}

	static function list(dir:String):Array<String> {
		final entries = try FileSystem.readDirectory(dir) catch (_) [];
		entries.sort(Reflect.compare);
		return entries;
	}
}

/** Whatever `haxe` is first on PATH. **/
class PathResolver implements ToolchainResolver {
	public var name(default, null):String = "path";

	public function new() {}

	public function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice> {
		final haxe = Files.which("haxe", ctx.env);
		return haxe == null ? null : {path: haxe};
	}
}

/** Runs a user-defined `ResolverDefinition`. **/
class CommandResolver implements ToolchainResolver {
	public var name(default, null):String;

	final definition:ResolverDefinition;

	public function new(definition:ResolverDefinition) {
		this.definition = definition;
		name = definition.name;
	}

	public function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice> {
		final detect = definition.detect;
		if (detect != null && !Lambda.exists(detect, file -> FileSystem.exists(Path.join([ctx.projectRoot, file])))) {
			return null;
		}
		final command = Vars.expandArgs(definition.command, {
			workspaceRoot: ctx.workspaceRoot,
			projectDir: ctx.projectRoot,
			haxercVersion: ctx.haxerc?.version ?? ""
		});
		final result = Exec.runSync(command, {cwd: ctx.projectRoot, env: ctx.env});
		if (result == null || result.code != 0) {
			notes.push('Toolchain resolver "$name": `${command.join(" ")}` failed${result == null ? " (not found)" : ""}.');
			return null;
		}
		final path = StringTools.trim(result.stdout.split("\n")[0]);
		return path == "" ? null : {path: path};
	}
}
