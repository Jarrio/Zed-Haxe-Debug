/** A host that runs Script.tick five times a second, and loads the script again whenever it changes. **/
class Host {
	static function main() {
		final path = Sys.args()[0];
		var stamp = 0.0;
		var tick:Dynamic = null;
		var n = 0;
		final end = Sys.time() + 120;
		while (Sys.time() < end && !sys.FileSystem.exists("stop")) {
			final time = sys.FileSystem.stat(path).mtime.getTime();
			if (time != stamp) {
				stamp = time;
				final module = cpp.cppia.Module.fromData(sys.io.File.getBytes(path).getData());
				module.boot();
				tick = Reflect.field(module.resolveClass("Script"), "tick");
				Sys.println("loaded the script");
			}
			Reflect.callMethod(null, tick, [n++]);
			Sys.sleep(0.2);
		}
	}
}
