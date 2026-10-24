import tools.Geometry;

using StringTools;

class Point {
	public var x:Int;

	public function new(x:Int) {
		this.x = x;
	}

	public function describe():String {
		return 'point at $x';
	}

	public function check():Int {
		return x; // BREAK member
	}
}

class Main {
	static var count = 7;

	static function main() {
		var name = "hello";
		var point = new Point(4);
		var area = Geometry.area(2, 3);
		Sys.println('$name $area ${point.check()} ${tools.Colors.red}'); // BREAK main
	}
}
