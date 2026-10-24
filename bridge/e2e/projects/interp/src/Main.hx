class Main {
	static function main() {
		final greeting = "hello";
		final sum = add(2, 3);
		trace('$greeting $sum'); // BREAK main
	}

	static function add(a:Int, b:Int):Int {
		return a + b;
	}
}
