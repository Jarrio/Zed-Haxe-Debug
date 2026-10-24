package bridge.util;

import haxe.DynamicAccess;

/**
	Expands `${name}` placeholders in provider and resolver definitions.
**/
class Vars {
	static final placeholder = ~/\$\{([A-Za-z]+)\}/g;
	static final wholePlaceholder = ~/^\$\{([A-Za-z]+)\}$/;

	public static function expand(text:String, values:DynamicAccess<String>):String {
		return placeholder.map(text, re -> values.get(re.matched(1)) ?? "");
	}

	/**
		Expands every argument. An argument that is exactly `${name}` where `name` is in `lists`
		is replaced by that list (possibly empty). Arguments that expand to an empty string are dropped.
	**/
	public static function expandArgs(args:Array<String>, values:DynamicAccess<String>, ?lists:DynamicAccess<Array<String>>):Array<String> {
		final result = [];
		for (arg in args) {
			if (lists != null && wholePlaceholder.match(arg) && lists.exists(wholePlaceholder.matched(1))) {
				for (item in lists.get(wholePlaceholder.matched(1))) {
					result.push(item);
				}
				continue;
			}
			final expanded = expand(arg, values);
			if (expanded != "") {
				result.push(expanded);
			}
		}
		return result;
	}
}
