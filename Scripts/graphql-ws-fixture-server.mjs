// Minimal graphql-transport-ws server for integration tests. No dependencies.
// Usage: node graphql-ws-fixture-server.mjs <port> <api-key>
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

const port = Number(process.argv[2] ?? 4719);
const apiKey = process.argv[3] ?? 'fixture-key';

function frame(text) {
  const payload = Buffer.from(text);
  const header = payload.length < 126
    ? Buffer.from([0x81, payload.length])
    : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]);
  return Buffer.concat([header, payload]);
}

function closeFrame(code) {
  return Buffer.from([0x88, 2, code >> 8, code & 0xff]);
}

function parseFrames(buffer, onText) {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const opcode = buffer[offset] & 0x0f;
    let length = buffer[offset + 1] & 0x7f;
    let cursor = offset + 2;
    if (length === 126) { length = buffer.readUInt16BE(cursor); cursor += 2; }
    else if (length === 127) { length = Number(buffer.readBigUInt64BE(cursor)); cursor += 8; }
    const masked = (buffer[offset + 1] & 0x80) !== 0;
    const mask = masked ? buffer.subarray(cursor, cursor + 4) : null;
    if (masked) cursor += 4;
    if (buffer.length < cursor + length) break;
    const data = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
    if (opcode === 0x1) onText(data.toString());
    if (opcode === 0x8) onText(null);
    offset = cursor + length;
  }
  return buffer.subarray(offset);
}

const server = createServer((req, res) => { res.writeHead(404); res.end('not found'); });

server.on('upgrade', (req, socket) => {
  if (req.url !== '/graphql' || req.headers['sec-websocket-protocol'] !== 'graphql-transport-ws') {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
    return;
  }
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\nSec-WebSocket-Protocol: graphql-transport-ws\r\n\r\n`);
  const send = (message) => socket.write(frame(JSON.stringify(message)));
  let pending = Buffer.alloc(0);
  let acknowledged = false;
  const timers = [];

  socket.on('data', (chunk) => {
    pending = parseFrames(Buffer.concat([pending, chunk]), (text) => {
      if (text === null) { socket.end(); return; }
      const message = JSON.parse(text);
      if (message.type === 'connection_init') {
        if (message.payload?.['x-api-key'] !== apiKey) { socket.end(closeFrame(4403)); return; }
        send({ type: 'ping' });
        return;
      }
      if (message.type === 'pong' && !acknowledged) { acknowledged = true; send({ type: 'connection_ack' }); return; }
      if (message.type === 'subscribe' && acknowledged) {
        const query = message.payload.query;
        if (query.includes('unsupportedField')) {
          send({ id: message.id, type: 'error', payload: [{ message: 'Cannot query field "unsupportedField" on type "Subscription".' }] });
          return;
        }
        let count = 0;
        const timer = setInterval(() => {
          count += 1;
          send({ id: message.id, type: 'next', payload: { data: { systemMetricsCpu: { percentTotal: count * 10 } } } });
          if (count === 3) { clearInterval(timer); send({ id: message.id, type: 'complete' }); }
        }, 50);
        timers.push(timer);
      }
    });
  });
  socket.on('close', () => timers.forEach(clearInterval));
  socket.on('error', () => timers.forEach(clearInterval));
});

server.listen(port, '127.0.0.1', () => console.log(`graphql-ws fixture listening on ${port}`));
