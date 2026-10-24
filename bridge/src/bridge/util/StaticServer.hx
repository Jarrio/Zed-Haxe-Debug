package bridge.util;

import haxe.io.Path;
import js.lib.Promise;
import js.node.Fs;
import js.node.Http;

/** Serves a folder over HTTP on localhost, for a browser to load a web build from. **/
class StaticServer {
	static final types = [
		"html" => "text/html", "js" => "text/javascript", "mjs" => "text/javascript", "css" => "text/css", "json" => "application/json",
		"map" => "application/json", "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif",
		"svg" => "image/svg+xml", "wasm" => "application/wasm", "ogg" => "audio/ogg", "mp3" => "audio/mpeg", "wav" => "audio/wav",
		"ttf" => "font/ttf", "otf" => "font/otf", "woff" => "font/woff", "woff2" => "font/woff2", "txt" => "text/plain"
	];

	/** Starts serving `root` on a free port, and resolves with the server's base URL (`http://127.0.0.1:port/`). **/
	public static function start(root:String):Promise<String> {
		return new Promise(function(resolve, reject) {
			final server = Http.createServer(function(request, response) {
				final relative = StringTools.urlDecode(request.url.split("?")[0]);
				var path = Path.normalize(Path.join([root, relative]));
				// Only files inside the folder.
				if (!StringTools.startsWith(path, Path.normalize(root))) {
					response.writeHead(403);
					response.end();
					return;
				}
				if (StringTools.endsWith(relative, "/")) {
					path = Path.join([path, "index.html"]);
				}
				Fs.readFile(path, function(error, data) {
					if (error != null) {
						response.writeHead(404);
						response.end();
						return;
					}
					response.writeHead(200, {"Content-Type": types.get(Path.extension(path).toLowerCase()) ?? "application/octet-stream"});
					response.end(data);
				});
			});
			server.on("error", reject);
			server.listen(0, "127.0.0.1", function() {
				resolve('http://127.0.0.1:${(cast server.address()).port}/');
			});
		});
	}
}
