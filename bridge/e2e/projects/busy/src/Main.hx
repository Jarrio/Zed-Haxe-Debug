class Main {
	static function main() {
		sys.thread.Thread.create(function() {
			var spins = 0;
			while (true) {
				spins++;
			}
		});
		var ticks = 0;
		while (true) {
			ticks++;
			Sys.sleep(0.01);
		}
	}
}
