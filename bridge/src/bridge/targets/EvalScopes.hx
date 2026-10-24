package bridge.targets;

import bridge.dap.Filter;
import bridge.dap.Message;
import js.lib.Promise;

/**
	Haxe gives each block of a function a scope of its own, and vshaxe shows a frame's scopes merged by
	name (`mergeScopes`). eval-debugger can do the merging, but then fails to change an object's field or
	an array's item ("Cannot read properties of undefined"). So the bridge has it list the scopes as Haxe
	gives them, and merges them itself. A merged scope keeps the reference of the first of its scopes. A
	name declared in two of them (a shadowed variable) shows the second time as `name - line N`, N being
	the line its block starts on.
**/
class EvalScopes extends Filter {
	/** The scopes merged into each scope Zed sees, by that scope's reference. **/
	final merged:Map<Int, Array<{reference:Int, line:Null<Int>}>> = [];

	/** Where each variable of a merged scope is: its scope and name, by the merged scope's reference and the name Zed sees. **/
	final origins:Map<Int, Map<String, {reference:Int, name:String}>> = [];

	public function new() {
		super();
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "event" && (message.event == "stopped" || message.event == "continued")) {
			merged.clear();
			origins.clear();
		} else if (message.type == "response" && message.command == "scopes" && message.success == true) {
			message.body.scopes = merge(message.body.scopes ?? []);
		}
		return Promise.resolve(message);
	}

	override public function fromZed(message:Message, context:FilterContext):Promise<Message> {
		final args:Dynamic = message.arguments;
		if (message.type != "request" || args == null) {
			return Promise.resolve(message);
		}
		switch message.command {
			case "variables":
				final scopes = merged.get(args.variablesReference);
				if (scopes != null && scopes.length > 1) {
					return variables(message, scopes, context);
				}
			case "setVariable":
				final origin = origins.get(args.variablesReference)?.get(args.name);
				if (origin != null) {
					args.variablesReference = origin.reference;
					args.name = origin.name;
				}
			case _:
		}
		return Promise.resolve(message);
	}

	/** One scope for each name, covering the lines of the scopes with that name. **/
	function merge(scopes:Array<Dynamic>):Array<Dynamic> {
		final firsts:Map<String, Dynamic> = [];
		final result = [];
		for (scope in scopes) {
			final first:Dynamic = firsts.get(scope.name);
			if (first == null) {
				firsts.set(scope.name, scope);
				merged.set(scope.variablesReference, [{reference: scope.variablesReference, line: scope.line}]);
				result.push(scope);
				continue;
			}
			merged.get(first.variablesReference).push({reference: scope.variablesReference, line: scope.line});
			if (scope.line != null && (first.line == null || scope.line < first.line)) {
				first.line = scope.line;
				first.column = scope.column;
			}
			if (scope.endLine != null && (first.endLine == null || scope.endLine > first.endLine)) {
				first.endLine = scope.endLine;
				first.endColumn = scope.endColumn;
			}
		}
		return result;
	}

	/** Answers `variables` for a merged scope with the variables of each of its scopes, in order. **/
	function variables(request:Message, scopes:Array<{reference:Int, line:Null<Int>}>, context:FilterContext):Promise<Message> {
		return Promise.all([for (scope in scopes) context.request("variables", {variablesReference: scope.reference})]).then(function(responses) {
			final result = [];
			final names:Map<String, {reference:Int, name:String}> = [];
			for (index in 0...responses.length) {
				final response:Message = responses[index];
				if (response.success != true) {
					return answer(request, null, response.message ?? "eval didn't list the variables");
				}
				final variables:Array<Dynamic> = response.body?.variables ?? [];
				for (variable in variables) {
					final name:String = variable.name;
					final shown = names.exists(name) ? '$name - line ${scopes[index].line}' : name;
					names.set(shown, {reference: scopes[index].reference, name: name});
					variable.name = shown;
					result.push(variable);
				}
			}
			origins.set(request.arguments.variablesReference, names);
			return answer(request, {variables: result});
		});
	}

	static function answer(request:Message, body:Dynamic, ?failure:String):Message {
		final response:Message = {
			seq: 0,
			type: "response",
			request_seq: request.seq,
			command: request.command,
			success: failure == null
		};
		if (body != null) {
			response.body = body;
		}
		if (failure != null) {
			response.message = failure;
		}
		return response;
	}
}
