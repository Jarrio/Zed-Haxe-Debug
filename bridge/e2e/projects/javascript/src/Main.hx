class Main {
	static function main() {
		final greeting = "hello";
		final sum = add(2, 3);
		print('$greeting $sum'); // BREAK main
		print('cwd ${js.Syntax.code("process.cwd()")}');
		print('args ${js.Syntax.code("process.argv.slice(2).join(',')")}');
	}

	static function add(a:Int, b:Int):Int {
		return a + b; // BREAK add
	}

	static function print(text:String) {
		js.Syntax.code("console.log({0})", text);
	}
}
