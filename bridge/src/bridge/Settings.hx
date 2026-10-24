package bridge;

import bridge.toolchain.ResolverDefinition;

/**
	Zed-Haxe's `project` settings (`lsp.haxe-language-server.settings.project`), shared so the debugger
	uses the same project folder and Haxe as the language server. Only the fields the debugger reads are
	here; Zed-Haxe's `Settings.hx` documents the rest.
**/
typedef ProjectSettings = {
	/** Folder of the Haxe project, relative to the workspace root (for monorepos). **/
	var ?root:String;

	/** Forces a provider by name (`"lime"`, `"ceramic"`, `"hxml"`, or a custom one). **/
	var ?provider:String;

	/** Target to use; for plain hxml projects, the path of the hxml. **/
	var ?target:String;

	/** Explicit Haxe executable. Wins over every toolchain resolver. **/
	var ?haxePath:String;

	/** Order of toolchain resolvers. Defaults to `["provider", "lix", "haxe-manager", "path"]`. **/
	var ?haxeResolvers:Array<String>;

	/** Extra toolchain resolvers, referenced by name from `haxeResolvers`. **/
	var ?resolvers:Array<ResolverDefinition>;

	/** The debugger's own settings, which a debug configuration's fields of the same names override. **/
	var ?debug:{
		/** hxcpp: whether a thread stopping stops the others too. Default: true. **/
		var ?stopAllThreads:Bool;
	};
}
