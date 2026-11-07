// A minimal RESP server for tests: it answers the node-redis handshake and
// replies to commands, except those named in `stall`, which it never answers.
const net = require("node:net");

const CRLF = "\r\n";

// Parses complete RESP arrays of bulk strings; returns [commands, unread bytes].
const parse = buffer => {
  const commands = [];
  let offset = 0;
  while (offset < buffer.length && buffer[offset] === 0x2a) {
    const headerEnd = buffer.indexOf(CRLF, offset);
    if (headerEnd < 0) break;
    const count = Number(buffer.subarray(offset + 1, headerEnd));
    const args = [];
    let position = headerEnd + 2;
    let complete = true;
    for (let index = 0; index < count; index += 1) {
      const lengthEnd = buffer.indexOf(CRLF, position);
      if (lengthEnd < 0) {
        complete = false;
        break;
      }
      const length = Number(buffer.subarray(position + 1, lengthEnd));
      const start = lengthEnd + 2;
      if (buffer.length < start + length + 2) {
        complete = false;
        break;
      }
      args.push(buffer.subarray(start, start + length).toString());
      position = start + length + 2;
    }
    if (!complete) break;
    commands.push(args);
    offset = position;
  }
  return [commands, buffer.subarray(offset)];
};

const reply = (name, args, values) => {
  if (name === "GET") {
    const value = values.get(args[1]);
    return value === undefined ? `$-1${CRLF}` : `$${Buffer.byteLength(value)}${CRLF}${value}${CRLF}`;
  }
  if (name === "PING") return `+PONG${CRLF}`;
  return `+OK${CRLF}`;
};

const startFakeRedis = async ({ stall = [], values = new Map() } = {}) => {
  const sockets = new Set();
  const received = [];
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    let buffer = Buffer.alloc(0);
    socket.on("data", data => {
      const [commands, rest] = parse(Buffer.concat([buffer, data]));
      buffer = rest;
      for (const args of commands) {
        const name = args[0].toUpperCase();
        received.push(name);
        if (!stall.includes(name)) {
          socket.write(reply(name, args, values));
        }
      }
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));

  return {
    port: server.address().port,
    received,
    openSockets: () => sockets.size,
    // Resolves true once every client socket has closed, false after timeoutMs.
    async waitForAllClosed(timeoutMs) {
      const deadline = Date.now() + timeoutMs;
      while (sockets.size > 0 && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      return sockets.size === 0;
    },
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    }
  };
};

module.exports = { startFakeRedis };
