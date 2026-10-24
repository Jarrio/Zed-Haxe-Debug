import haxe.macro.Expr;

class Macros {
	public static macro function answer():Expr {
		final value = 6 * 7;
		return macro $v{value}; // BREAK macro
	}
}
