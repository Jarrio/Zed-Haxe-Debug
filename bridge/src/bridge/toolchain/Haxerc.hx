package bridge.toolchain;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
	The `.haxerc` file used by lix, haxe-manager and others to pin a Haxe version:
	`{"version": "4.3.7", "resolveLibs": "scoped"}`.
**/
typedef HaxercData = {
	/** A release (`4.3.7`) or a nightly commit hash (`033a9fd`). **/
	var version:String;

	/** `"scoped"` (libraries from `haxe_libraries/`), `"mixed"` or `"haxelib"`. **/
	var ?resolveLibs:String;
}

class Haxerc {
	/** Reads the `.haxerc` in `projectRoot`, or in a parent folder up to `workspaceRoot`. **/
	public static function find(projectRoot:String, workspaceRoot:String):Null<{path:String, data:HaxercData}> {
		final stop = Path.normalize(workspaceRoot);
		var dir = Path.normalize(projectRoot);
		while (true) {
			final path = Path.join([dir, ".haxerc"]);
			if (FileSystem.exists(path)) {
				try {
					final data:HaxercData = Json.parse(File.getContent(path));
					if (data.version != null) {
						return {path: path, data: data};
					}
				} catch (_) {}
			}
			final parent = Path.normalize(Path.join([dir, ".."]));
			if (dir == stop || parent == dir || !StringTools.startsWith(parent, stop)) {
				return null;
			}
			dir = parent;
		}
	}
}
