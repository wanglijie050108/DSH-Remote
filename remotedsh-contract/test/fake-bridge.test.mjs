import test from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import { generateKeyPairSync } from 'node:crypto'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { WebSocket } from 'ws'
import { buildHello } from '../js/hello.mjs'

async function freePort() {
  const server = net.createServer()
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const port = server.address().port
  await new Promise((resolve) => server.close(resolve))
  return port
}

async function nextMessage(ws) {
  const [raw] = await once(ws, 'message')
  return JSON.parse(raw.toString())
}

test('fake-bridge uses TURN_HOST and resets its two-second rate window', async (t) => {
  const port = await freePort()
  const child = spawn(process.execPath, [
    'tools/fake-bridge.mjs',
    '--port', String(port),
    '--turn-host', '198.51.100.7',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  t.after(() => child.kill())
  await once(child.stdout, 'data')

  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const privateKeyPem = privateKey.export({ format: 'pem', type: 'pkcs8' }).toString()
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/signal`)
  t.after(() => ws.close())
  await once(ws, 'open')

  ws.send(JSON.stringify(buildHello({ role: 'app', privateKeyPem })))
  assert.equal((await nextMessage(ws)).t, 'hello.ok')

  ws.send(JSON.stringify({ t: 'relay.request' }))
  const relay = await nextMessage(ws)
  assert.equal(relay.t, 'relay.alloc')
  assert.deepEqual(relay.turn.uris, [
    'stun:198.51.100.7:3478',
    'turn:198.51.100.7:3478?transport=udp',
    'turn:198.51.100.7:3478?transport=tcp',
  ])

  for (let i = 0; i < 38; i++) {
    ws.send(JSON.stringify({ t: 'ping' }))
    assert.equal((await nextMessage(ws)).t, 'pong')
  }
  await new Promise((resolve) => setTimeout(resolve, 2050))
  ws.send(JSON.stringify({ t: 'ping' }))
  assert.equal((await nextMessage(ws)).t, 'pong')
})
