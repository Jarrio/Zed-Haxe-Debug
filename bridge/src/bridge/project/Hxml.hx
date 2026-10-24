package bridge.project;

/**
	Splits hxml text into compiler arguments, following the compiler's own rules:
	one argument per line, except that a line starting with `-` is split at its first space
	into a flag and its value. `#` starts a comment line, and surrounding double quotes are removed.
**/
class Hxml {
	public static function parse(text:String):Array<String> {
		final args = [];
		for (rawLine in ~/[\r\n]+/g.split(text)) {
			final line = unquote(StringTools.trim(rawLine));
			if (line == "" || StringTools.startsWith(line, "#")) {
				continue;
			}
			final space = line.indexOf(" ");
			if (StringTools.startsWith(line, "-") && space > 0) {
				args.push(unquote(line.substr(0, space)));
				args.push(unquote(StringTools.trim(line.substr(space + 1))));
			} else {
				args.push(line);
			}
		}
		return args;
	}

	/**
		Replaces hxml files named in `args` by their contents, recursively, so the result shows every
		library and class path. `cwd` is where relative paths start; a `--cwd` in the arguments moves it.
	**/
	public static function expand(args:Array<String>, cwd:String):Array<String> {
		return expandIn(args, cwd, []);
	}

	static function expandIn(args:Array<String>, cwd:String, seen:Array<String>):Array<String> {
		final result = [];
		var dir = cwd;
		var i = 0;
		while (i < args.length) {
			final arg = args[i];
			if (arg == "--cwd" && i + 1 < args.length) {
				dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([dir, args[i + 1]]);
				result.push(arg);
				result.push(dir);
				i += 2;
				continue;
			}
			final path = haxe.io.Path.isAbsolute(arg) ? arg : haxe.io.Path.join([dir, arg]);
			if (StringTools.endsWith(arg, ".hxml") && !seen.contains(path) && sys.FileSystem.exists(path)) {
				seen.push(path);
				final content = try sys.io.File.getContent(path) catch (_) "";
				for (included in expandIn(parse(content), dir, seen)) {
					result.push(included);
				}
			} else {
				result.push(arg);
			}
			i++;
		}
		return result;
	}

	static function unquote(text:String):String {
		if (text.length >= 2 && StringTools.startsWith(text, '"') && StringTools.endsWith(text, '"')) {
			return text.substr(1, text.length - 2);
		}
		return text;
	}
}
