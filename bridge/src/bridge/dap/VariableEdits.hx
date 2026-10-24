package bridge.dap;

import bridge.dap.Filter;
import js.lib.Promise;

/**
	Values changed in Zed's variables list. After an edit, Zed asks for the variables again under the same
	reference, and some debuggers answer with the value from when the program stopped: hxcpp-debug-server
	keeps the locals it listed, and V8 does the same for a function's scope. So until the program moves
	on, the bridge puts the values the edits set into those answers. Zed only logs an edit the debugger
	refuses, so the bridge also prints the reason in the debug console.
**/
class VariableEdits extends Filter {
	static final resuming = ["continue", "next", "stepIn", "stepOut", "stepBack", "reverseContinue", "restartFrame", "goto", "restart"];

	/** Zed's `setVariable` requests waiting for their answers, by sequence number. **/
	final edits:Map<Int, {reference:Int, name:String, value:String}> = [];

	/** Zed's `variables` requests waiting for their answers: the reference each asks about. **/
	final reads:Map<Int, Int> = [];

	/** What the edits since the program stopped set, by reference and then by name. **/
	final values:Map<Int, Map<String, Dynamic>> = [];

	public function new() {
		super();
	}

	override public function fromZed(message:Message, context:FilterContext):Promise<Message> {
		if (message.type == "request") {
			final args:Dynamic = message.arguments ?? {};
			switch message.command {
				case "setVariable":
					edits.set(message.seq, {reference: args.variablesReference, name: args.name, value: args.value});
				case "variables":
					reads.set(message.seq, args.variablesReference);
				case command if (resuming.contains(command)):
					values.clear();
				case _:
			}
		}
		return Promise.resolve(message);
	}

	override public function fromDebugger(message:Message, context:FilterContext):Promise<Null<Message>> {
		if (message.type == "event" && (message.event == "stopped" || message.event == "continued")) {
			values.clear();
		} else if (message.type == "response" && message.command == "setVariable") {
			final edit = edits.get(message.request_seq);
			edits.remove(message.request_seq);
			if (edit != null) {
				edited(edit, message, context);
			}
		} else if (message.type == "response" && message.command == "variables") {
			final reference = reads.get(message.request_seq);
			reads.remove(message.request_seq);
			final set = reference == null ? null : values.get(reference);
			if (set != null && message.success == true) {
				final variables:Array<Dynamic> = message.body?.variables ?? [];
				for (variable in variables) {
					final edit:Dynamic = set.get(variable.name);
					if (edit != null) {
						variable.value = edit.value;
						if (edit.type != null) {
							variable.type = edit.type;
						}
						if (edit.variablesReference != null) {
							variable.variablesReference = edit.variablesReference;
						}
					}
				}
			}
		}
		return Promise.resolve(message);
	}

	function edited(edit:{reference:Int, name:String, value:String}, response:Message, context:FilterContext) {
		// hashlink-debugger answers without a value when it can't evaluate the new one, such as a string.
		final reason:Null<String> = if (response.success != true) {
			response.body?.error?.format ?? response.message ?? "the debugger refused";
		} else if (response.body?.value == null) {
			'the debugger can\'t make the value ${edit.value}';
		} else {
			null;
		}
		if (reason != null) {
			context.tell({
				seq: 0,
				type: "event",
				event: "output",
				body: {category: "stderr", output: 'Couldn\'t change ${edit.name}: $reason\n'}
			});
			return;
		}
		if (!values.exists(edit.reference)) {
			values.set(edit.reference, []);
		}
		values.get(edit.reference).set(edit.name, response.body);
	}
}
