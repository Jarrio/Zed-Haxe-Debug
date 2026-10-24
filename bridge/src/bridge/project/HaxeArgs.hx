package bridge.project;

import haxe.io.Path;

/** Questions about Haxe command-line arguments, after `Hxml.expand` has replaced the hxml files in them. **/
class HaxeArgs {
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

	/** Drops `--cmd`, which would run something after the build, such as the program without the debugger. **/
	public static function withoutCommands(args:Array<String>):Array<String> {
		final result = [];
		var i = 0;
		while (i < args.length) {
			if (args[i] == "--cmd" || args[i] == "-cmd") {
				i += 2;
				continue;
			}
			result.push(args[i]);
			i++;
		}
		return result;
	}

	/**
		The absolute path given to the first of `flags` (such as `--hl`), resolved from the folder Haxe is in
		at that point: `cwd`, moved by any `--cwd` before it. Null when no flag is there.
	**/
	public static function output(args:Array<String>, flags:Array<String>, cwd:String):Null<String> {
		var dir = cwd;
		for (i in 0...args.length - 1) {
			if (args[i] == "--cwd") {
				dir = absolute(dir, args[i + 1]);
			} else if (flags.contains(args[i])) {
				return absolute(dir, args[i + 1]);
			}
		}
		return null;
	}

	/** The value of the first of `flags` (such as `-main`), null when there is none. **/
	public static function value(args:Array<String>, flags:Array<String>):Null<String> {
		for (i in 0...args.length - 1) {
			if (flags.contains(args[i])) {
				return args[i + 1];
			}
		}
		return null;
	}

	/** Whether `args` add the haxelib `name`, at any version. **/
	public static function usesLibrary(args:Array<String>, name:String):Bool {
		for (i in 0...args.length - 1) {
			if ((args[i] == "-lib" || args[i] == "-L" || args[i] == "--library") && args[i + 1].split(":")[0] == name) {
				return true;
			}
		}
		return false;
	}

	/** The value of the define `name` in `args` (`-D name=value`), "1" when it has none, null when it's absent. **/
	public static function define(args:Array<String>, name:String):Null<String> {
		var value:Null<String> = null;
		for (i in 0...args.length - 1) {
			if (args[i] == "-D" || args[i] == "--define") {
				final parts = args[i + 1].split("=");
				if (parts[0] == name) {
					value = parts.length > 1 ? parts.slice(1).join("=") : "1";
				}
			}
		}
		return value;
	}

	static function absolute(base:String, path:String):String {
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
	}
}
