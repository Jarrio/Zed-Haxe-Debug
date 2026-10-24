class Main {
	static function main() {
		var total = 0;
		// Not a constant: Haxe would unroll the loop and drop i.
		var count = Std.parseInt("10");
		for (i in 0...count) {
			total += i; // BREAK log
			var twice = i * 2; // BREAK hits
			if (twice < 0)
				Sys.println(twice);
		}
		var scale = 3;
		inner(total, scale); // BREAK caller
		Sys.println('total $total');
	}

	static function inner(n:Int, scale:Int) {
		var local = n * scale; // BREAK inner
		Sys.println('local $local');
	}
}
