class Main {
	static function main() {
		var value = 3;
		fail(value);
	}

	static function fail(n:Int) {
		throw 'broken $n'; // BREAK throw
	}
}
