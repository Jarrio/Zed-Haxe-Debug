package bridge.toolchain;

/**
	A toolchain resolver described as data, run by `CommandResolver`. Add these under
	`project.resolvers` and list their names in `project.haxeResolvers`:

	```json
	{"name": "mytool", "detect": [".haxerc"], "command": ["mytool", "which-haxe", "${haxercVersion}"]}
	```

	The command must print the path of a Haxe executable on its first line.
	Placeholders: `${workspaceRoot}`, `${projectDir}`, `${haxercVersion}`.
**/
typedef ResolverDefinition = {
	var name:String;

	/** Only run when one of these files exists in the project folder. **/
	var ?detect:Array<String>;

	var command:Array<String>;
}
