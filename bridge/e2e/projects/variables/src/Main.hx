class Point {
	public var x:Int;

	public function new(x:Int) {
		this.x = x;
	}
}

class Main {
	static function main() {
		var greeting = "hello";
		var sum = add(2, 3);
		var point = new Point(4);
		var list = [1, 2, 3];
		show(greeting, sum, point, list); // BREAK main
	}

	static function show(greeting:String, sum:Int, point:Point, list:Array<Int>) {
		print('edited $greeting $sum ${point.x} $list');
	}

	static function add(a:Int, b:Int):Int {
		return a + b;
	}

	static function print(text:String) {
		#if js
		js.Syntax.code("console.log({0})", text);
		#else
		Sys.println(text);
		#end
	}
}
