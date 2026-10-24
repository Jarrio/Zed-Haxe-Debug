package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/**
	eval names the frame of a local function after where it was called from rather than where it's
	written, such as `sys.thread._EventLoop.RegularEvent.run.localFunction1.localFunction1.localFunction3`
	for a `haxe.Timer.delay` callback. The bridge names it after the method the function is written in,
	found in its source file: "local function in Main.main".
**/
class EvalFrameNames extends Filter {
	static final local = ~/(^|\.)localFunction\d+$/;
	static final namedFunction = ~/\bfunction\s+([A-Za-z_]\w*)/;
	static final type = ~/\b(?:class|interface|abstract|enum(?!\s+abstract))\s+([A-Za-z_]\w*)/;
	static final packageName = ~/^\s*package\s+([\w.]+)\s*;/m;

	/** Source files read so far, with their modification time. **/
	final files:Map<String, {time:Float, text:String}> = [];

	public function new() {
		super();
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "response" && message.command == "stackTrace" && message.success == true) {
			final frames:Array<Dynamic> = message.body?.stackFrames ?? [];
			for (frame in frames) {
				final name:String = frame.name ?? "";
				if (local.match(name)) {
					final method = frame.source?.path == null ? null : enclosing(frame.source.path, frame.line);
					frame.name = method == null ? "local function" : 'local function in $method';
				}
			}
		}
		return Promise.resolve(message);
	}

	/** The method around `line` of the file: the nearest named function above it, in the nearest type above that. **/
	function enclosing(path:String, line:Int):Null<String> {
		final text = read(path);
		if (text == null) {
			return null;
		}
		final lines = text.split("\n");
		var index = Std.int(Math.min(line, lines.length)) - 1;
		while (index >= 0 && !namedFunction.match(lines[index])) {
			index--;
		}
		if (index < 0) {
			return null;
		}
		final method = namedFunction.matched(1);
		while (index >= 0 && !type.match(lines[index])) {
			index--;
		}
		if (index < 0) {
			return null;
		}
		final prefix = packageName.match(text) ? packageName.matched(1) + "." : "";
		return '$prefix${type.matched(1)}.$method';
	}

	function read(path:String):Null<String> {
		try {
			final time = FileSystem.stat(path).mtime.getTime();
			final known = files.get(path);
			if (known != null && known.time == time) {
				return known.text;
			}
			final text = File.getContent(path);
			files.set(path, {time: time, text: text});
			return text;
		} catch (_) {
			return null;
		}
	}
}
