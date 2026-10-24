class Main {
	static function main() {
		final lock = new sys.thread.Lock();
		for (n in 1...3) {
			sys.thread.Thread.create(function() {
				final id = n;
				final doubled = id * 2; // BREAK thread
				Sys.println('thread $id $doubled');
				lock.release();
			});
		}
		// With a timeout: Haxe 5 on hxcpp master doesn't wait without one (see the README's known issues).
		lock.wait(60);
		lock.wait(60);
		haxe.Timer.delay(function() {
			final late = "timer";
			Sys.println('$late fired'); // BREAK timer
		}, 50);
		Sys.println("main done");
	}
}
