class Main {
	static function main() {
		final greeting = "hello";
		final sum = add(2, 3);
		Sys.println('$greeting $sum'); // BREAK main
		Sys.println('cwd ${Sys.getCwd()}');
		Sys.println('args ${Sys.args().join(",")}');
	}

	static function add(a:Int, b:Int):Int {
		return a + b; // BREAK add
	}
}
