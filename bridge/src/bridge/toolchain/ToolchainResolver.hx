package bridge.toolchain;

import bridge.toolchain.Haxerc.HaxercData;
import haxe.DynamicAccess;

typedef ToolchainContext = {
	final workspaceRoot:String;
	final projectRoot:String;

	/** Contents of the nearest `.haxerc`, if any. **/
	final haxerc:Null<HaxercData>;

	/** Haxe executable suggested by the project provider (e.g. Ceramic's bundled Haxe). **/
	final providerHaxePath:Null<String>;

	final env:DynamicAccess<String>;
}

typedef ToolchainChoice = {
	/** Haxe executable to run. **/
	var path:String;

	/** Extra environment for that executable, e.g. `HAXE_STD_PATH`. **/
	var ?env:DynamicAccess<String>;
}

/**
	Decides which `haxe` executable to use for a project.

	Resolvers are tried in the order of `project.haxeResolvers`; the first non-null answer wins.
	To add one in Haxe, implement this interface and add it to `Toolchain.builtInResolvers`.
	Users can also define command-based resolvers in settings (see `ResolverDefinition`).
**/
interface ToolchainResolver {
	var name(default, null):String;

	/**
		Returns the executable to use, or null to let the next resolver try.
		Push to `notes` to tell the user why this resolver couldn't help when it should have.
	**/
	function resolve(ctx:ToolchainContext, notes:Array<String>):Null<ToolchainChoice>;
}
