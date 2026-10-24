package bridge.util;

import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import sys.FileSystem;

class Files {
	static final isWindows = process.platform == "win32";

	/** Folders never searched for project files. `haxe_modules` holds git-submodule libraries (gsm). **/
	public static final ignoredFolders = [
		".git", ".haxelib", ".zed", "node_modules", "haxe_libraries", "haxe_modules", "Export", "export", "bin", "dump", "out"
	];

	/**
		Finds files named one of `names` in `root` and its subfolders, up to `maxDepth` levels down.
		Shallower matches come first; within a folder, `names` order decides.
	**/
	public static function findByName(root:String, names:Array<String>, maxDepth:Int):Array<String> {
		return find(root, maxDepth, file -> names.contains(file)).map(match -> match.path);
	}

	/** Finds files whose name ends with `extension` (e.g. `".hxml"`), shallowest first. **/
	public static function findByExtension(root:String, extension:String, maxDepth:Int):Array<{path:String, depth:Int}> {
		return find(root, maxDepth, file -> StringTools.endsWith(file, extension));
	}

	static function find(root:String, maxDepth:Int, matches:String->Bool):Array<{path:String, depth:Int}> {
		final result = [];
		var level = [root];
		for (depth in 0...maxDepth + 1) {
			final next = [];
			for (dir in level) {
				final entries = try FileSystem.readDirectory(dir) catch (_) [];
				entries.sort(Reflect.compare);
				for (entry in entries) {
					final path = Path.join([dir, entry]);
					final isDir = try FileSystem.isDirectory(path) catch (_) false;
					if (isDir) {
						// A folder with a haxelib.json is a library kept inside the project, not part of it.
						if (!ignoredFolders.contains(entry) && !StringTools.startsWith(entry, ".")
							&& !FileSystem.exists(Path.join([path, "haxelib.json"]))) {
							next.push(path);
						}
					} else if (matches(entry)) {
						result.push({path: path, depth: depth});
					}
				}
			}
			level = next;
		}
		return result;
	}

	/**
		Looks up an executable on `PATH`, like the `which` command. On Windows a name without an extension
		gets each of `PATHEXT`'s extensions, as cmd.exe does, so `lime` finds `lime.cmd` and not a shell script.
	**/
	public static function which(name:String, env:DynamicAccess<String>, ?windows:Bool):Null<String> {
		final onWindows = windows ?? isWindows;
		final pathVariable = variable(env, "PATH", onWindows) ?? "";
		final extensions = onWindows ? windowsExtensions(name, env) : [""];
		for (dir in pathVariable.split(onWindows ? ";" : ":")) {
			if (dir == "") {
				continue;
			}
			for (extension in extensions) {
				final candidate = Path.join([dir, name + extension]);
				if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
					return candidate;
				}
			}
		}
		return null;
	}

	/** The file a command names: `which` for a bare name, else the path itself (on Windows also with `PATHEXT`'s extensions). **/
	public static function executable(command:String, env:DynamicAccess<String>, cwd:String, ?windows:Bool):Null<String> {
		final onWindows = windows ?? isWindows;
		if (command.indexOf("/") < 0 && (!onWindows || command.indexOf("\\") < 0)) {
			return which(command, env, onWindows);
		}
		final path = Path.isAbsolute(command) ? Path.normalize(command) : Path.join([cwd, command]);
		final extensions = onWindows ? windowsExtensions(command, env) : [""];
		for (extension in extensions) {
			if (FileSystem.exists(path + extension) && !FileSystem.isDirectory(path + extension)) {
				return path + extension;
			}
		}
		return null;
	}

	static function windowsExtensions(name:String, env:DynamicAccess<String>):Array<String> {
		final pathExt = [
			for (extension in (variable(env, "PATHEXT", true) ?? ".COM;.EXE;.BAT;.CMD").split(";"))
				if (extension != "") extension.toLowerCase()
		];
		return Path.extension(name) != "" ? [""].concat(pathExt) : pathExt;
	}

	/** An environment variable; on Windows its name is case-insensitive (`Path`, `PATH`). **/
	public static function variable(env:DynamicAccess<String>, name:String, ?windows:Bool):Null<String> {
		if (!(windows ?? isWindows) || env.exists(name)) {
			return env.get(name);
		}
		for (key => value in env) {
			if (key.toUpperCase() == name) {
				return value;
			}
		}
		return null;
	}

	/**
		Returns `dir/name` or `dir/name.exe`, whichever exists. On Windows, `name` with each of `PATHEXT`'s
		extensions instead (`haxe.exe`, or lix's `haxe.cmd` rather than the shell script next to it).
	**/
	public static function executableIn(dir:String, name:String, ?windows:Bool):Null<String> {
		final extensions = (windows ?? isWindows) ? windowsExtensions(name, process.env) : ["", ".exe"];
		for (candidate in [for (extension in extensions) Path.join([dir, name + extension])]) {
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
				return candidate;
			}
		}
		return null;
	}
}
