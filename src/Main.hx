import protocol.debug.Types;
import js.node.Buffer;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import js.node.stream.Readable.ReadableEvent;
import Protocol;

typedef EvalLaunchRequestArguments = {
	>protocol.debug.Types.LaunchRequestArguments,
	var cwd:String;
	var hxml:String;
	var stopOnEntry:Bool;
}

@:keep
class Main extends adapter.DebugSession {
	function traceToOutput(value:Dynamic, ?infos:haxe.PosInfos) {
		var msg = value;
		if (infos != null && infos.customParams != null) {
			msg += " " + infos.customParams.join(" ");
		}
		msg += "\n";
		sendEvent(new adapter.DebugSession.OutputEvent(msg));
	}

	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		// haxe.Log.trace = traceToOutput;
		sendEvent(new adapter.DebugSession.InitializedEvent());
		response.body.supportsSetVariable = true;
		sendResponse(response);
		postLaunchActions = [];
	}

	var connection:Connection;
	var postLaunchActions:Array<(Void->Void)->Void>;

	function executePostLaunchActions(callback) {
		function loop() {
			var action = postLaunchActions.shift();
			if (action == null)
				return callback();
			action(loop);
		}
		loop();
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var args:EvalLaunchRequestArguments = cast args;
		var hxmlFile = args.hxml;
		var cwd = args.cwd;

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);
			connection.onEvent = onEvent;

			socket.on(SocketEvent.Error, error -> trace('Socket error: $error'));

			executePostLaunchActions(function() {
				if (args.stopOnEntry) {
					sendResponse(response);
					sendEvent(new adapter.DebugSession.StoppedEvent("entry", 0));
				} else {
					continueRequest(cast response, null);
				}
			});
		}

		function onExit(_, _) {
			sendEvent(new adapter.DebugSession.TerminatedEvent(false));
		}

		var server = Net.createServer(onConnected);
		server.listen(0, function() {
			var port = server.address().port;
			var args = [
				"--cwd", cwd,
				hxmlFile,
				"-D", 'eval-debugger=127.0.0.1:$port',
			];
			var haxeProcess = ChildProcess.spawn("haxe", args, {stdio: Pipe});
			haxeProcess.stdout.on(ReadableEvent.Data, onStdout);
			haxeProcess.stderr.on(ReadableEvent.Data, onStderr);
			haxeProcess.on(ChildProcessEvent.Exit, onExit);
		});
	}

	function onStdout(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stdout));
	}

	function onStderr(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stderr));
	}

	var stopContext:StopContext;

	function onEvent<P>(type:NotificationMethod<P>, data:P) {
		switch (type) {
			case Protocol.BreakpointStop:
				stopContext = new StopContext(connection);
				sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", 0));
			case Protocol.ExceptionStop:
				stopContext = new StopContext(connection);
				var evt = new adapter.DebugSession.StoppedEvent("exception", 0);
				evt.body.text = data.text;
				sendEvent(evt);
		}
	}

	override function scopesRequest(response:ScopesResponse, args:ScopesArguments) {
		stopContext.getScopes(args.frameId, function(scopes) {
			response.body = {scopes: scopes};
			sendResponse(response);
		});
	}

	override function variablesRequest(response:VariablesResponse, args:VariablesArguments) {
		stopContext.getVariables(args.variablesReference, function(vars) {
			response.body = {variables: vars};
			sendResponse(response);
		});
	}

	override function setVariableRequest(response:SetVariableResponse, args:SetVariableArguments) {
		stopContext.setVariable(args.variablesReference, args.name, args.value, function(varInfo) {
			if (varInfo != null)
				response.body = {value: varInfo.value};
			sendResponse(response);
		});
	}

	override function stepInRequest(response:StepInResponse, args:StepInArguments) {
		connection.sendCommand(Protocol.StepIn, {}, function(_,_) {
			sendResponse(response);
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}

	override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
		connection.sendCommand(Protocol.StepOut, {}, function(_,_) {
			sendResponse(response);
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}


	override function nextRequest(response:NextResponse, args:NextArguments) {
		connection.sendCommand(Protocol.Next, {}, function(_,_) {
			sendResponse(response);
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand(Protocol.StackTrace, {}, function(error, result) {
			var r:Array<StackFrame> = [];
			for (info in result) {
				if (info.artificial) {
					r.push({
						id: info.id,
						name: "Internal",
						line: 0,
						column: 0,
						presentationHint: label,
					});
				} else {
					r.push({
						id: info.id,
						name: info.name,
						source: {path: info.source},
						line: info.line,
						column: info.column,
						endLine: info.endLine,
						endColumn: info.endColumn,
					});
				}
			}
			response.body = {
				stackFrames: r
			};
			sendResponse(response);
		});
	}

	override function threadsRequest(response:ThreadsResponse) {
		// TODO: support other threads?
		response.body = {threads: [{id: 0, name: "Interp"}]};
		sendResponse(response);
	}

	override function continueRequest(response:ContinueResponse, args:ContinueArguments) {
		connection.sendCommand(Protocol.Continue, {}, (_,_) -> sendResponse(response));
	}

	override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		if (connection == null)
			postLaunchActions.push(cb -> doSetBreakpoints(response, args, cb));
		else
			doSetBreakpoints(response, args, null);
	}

	function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments, callback:Null<Void->Void>) {
		var params:SetBreakpointsParams = {
			file: args.source.path,
			breakpoints: [for (sbp in args.breakpoints) {
				var bp:{line:Int, ?column:Int} = {line: sbp.line};
				if (sbp.column != null) bp.column = sbp.column;
				bp;
			}]
		}
		connection.sendCommand(Protocol.SetBreakpoints, params, function(error, result) {
			response.body = {breakpoints: [for (bp in result) {verified: true, id: bp.id}]};
			sendResponse(response);
			if (callback != null)
				callback();
		});
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
