import test from 'node:test'
import assert from 'node:assert/strict'
import { turnIceServers, withTimeout } from '../lib/rtc.js'

test('TURN credentials survive iceServers conversion', () => {
  assert.deepEqual(turnIceServers({
    uris: [
      'stun:114.55.114.12:3478',
      'turn:114.55.114.12:3478?transport=udp',
      'turn:114.55.114.12:3478?transport=tcp',
    ],
    username: 'user',
    credential: 'secret',
  }), [
    { urls: 'stun:114.55.114.12:3478' },
    {
      urls: 'turn:114.55.114.12:3478?transport=udp',
      username: 'user',
      credential: 'secret',
    },
    {
      urls: 'turn:114.55.114.12:3478?transport=tcp',
      username: 'user',
      credential: 'secret',
    },
  ])
})

test('gather timeout closes the peer and rejects', async () => {
  let closed = false
  await assert.rejects(
    withTimeout(new Promise(() => {}), 5, () => { closed = true }, 'gather timeout'),
    /gather timeout/,
  )
  assert.equal(closed, true)
})
