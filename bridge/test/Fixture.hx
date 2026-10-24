import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import js.node.Fs;
import js.node.Os;
import sys.FileSystem;

/** Temporary project folders for tests. **/
class Fixture {
	static final created:Array<String> = [];

	/** Creates a temporary folder containing `files` (relative path => content). **/
	public static function create(files:DynamicAccess<String>):String {
		final dir = Fs.realpathSync(Fs.mkdtempSync(Path.join([Os.tmpdir(), "haxe-debug-test-"])));
		created.push(dir);
		for (name => content in files) {
			final path = Path.join([dir, name]);
			FileSystem.createDirectory(Path.directory(path));
			sys.io.File.saveContent(path, content);
		}
		return dir;
	}

	/**
		Makes `dir/name` a fake executable that runs `js` with Node: a shell script, or `name.cmd` on Windows.
		Returns its path (see `launcher`).
	**/
	public static function script(dir:String, name:String, js:String):String {
		final path = Path.join([dir, name]);
		FileSystem.createDirectory(Path.directory(path));
		sys.io.File.saveContent('${path}.script.js', js);
		if (process.platform == "win32") {
			sys.io.File.saveContent(launcher(path), '@"${process.execPath}" "${path}.script.js" %*\r\n');
		} else {
			sys.io.File.saveContent(path, '#!/bin/sh\nexec "${process.execPath}" "${path}.script.js" "$$@"\n');
			Fs.chmodSync(path, "755");
		}
		return launcher(path);
	}

	/** The file `script` writes for `path`. **/
	public static function launcher(path:String):String {
		return process.platform == "win32" ? '$path.cmd' : path;
	}

	/** Deletes every folder made by `create`. **/
	public static function removeAll() {
		for (dir in created) {
			js.Syntax.code("require('fs').rmSync({0}, {recursive: true, force: true})", dir);
		}
		created.resize(0);
	}
}
