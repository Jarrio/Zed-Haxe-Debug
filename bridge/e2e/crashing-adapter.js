// A debug adapter that crashes once it gets `launch`, as one with a bug would: for the debuggerCrash test.
"use strict";
let buffer = Buffer.alloc(0);

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const length = Number(/Content-Length:\s*(\d+)/i.exec(buffer.toString("ascii", 0, headerEnd))[1]);
    if (buffer.length < headerEnd + 4 + length) return;
    const message = JSON.parse(buffer.toString("utf8", headerEnd + 4, headerEnd + 4 + length));
    buffer = buffer.subarray(headerEnd + 4 + length);
    if (message.command === "initialize") {
      send({ seq: 1, type: "response", request_seq: message.seq, command: "initialize", success: true, body: {} });
    } else if (message.command === "launch") {
      setTimeout(() => {
        throw new Error("something went wrong in the debugger");
      });
    }
  }
});
