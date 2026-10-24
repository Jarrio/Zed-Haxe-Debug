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
		lock.wait();
		lock.wait();
		haxe.Timer.delay(function() {
			final late = "timer";
			Sys.println('$late fired'); // BREAK timer
		}, 50);
		Sys.println("main done");
	}
}
