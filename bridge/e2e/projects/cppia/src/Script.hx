class Script {
	public static function tick(n:Int) {
		final value = n * 2 + 1;
		Sys.println('tick $value'); // BREAK tick
	}

	static function main() {}
}
