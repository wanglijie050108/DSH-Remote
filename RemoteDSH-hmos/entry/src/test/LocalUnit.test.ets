// 契约层纯逻辑 G2 向量单测（本地跑，无设备 API）
// 覆盖：帧编解码 14 例 / a=fingerprint 归一 7 例 / QR 解析 5 例 + Codec 自证
// crypto 相关向量（hello/turn）在真机自测页跑（cryptoFramework 需设备环境）
import { describe, it, expect } from '@ohos/hypium';
import {
  encodeFrame, decodeFrame, FrameError, FrameType, FrameSplitter, MAX_PAYLOAD, FRAME_HEADER_SIZE
} from '../main/ets/contract/Frames';
import { extractPinnedFingerprint, verifyPin } from '../main/ets/contract/Fingerprint';
import { parsePairQr } from '../main/ets/contract/QrPair';
import {
  bytesToBase64, base64ToBytes, bytesToB64u, b64uToBytes, bytesToHex, hexToBytes,
  utf8Encode, utf8Decode, bytesEqual
} from '../main/ets/contract/Codec';
import { sha256, sha1, hmacSha1 } from '../main/ets/contract/Digest';
import { rawToDer, derToRaw, DerError } from '../main/ets/contract/DerEcdsa';
import { turnUsername, turnCredential } from '../main/ets/contract/Turn';
import { VEC_FRAMES, VEC_FP, VEC_QR, VEC_HELLO } from '../main/ets/contract/Vectors';

interface FrameCase {
  name: string;
  frame_hex?: string;
  decode?: FrameDecode;
}

interface FrameDecode {
  ver: number;
  type: string;
  flags: number;
  stream_id: number;
  payload_hex?: string;
  payload_utf8?: string;
  credit?: number;
}

interface FpCase {
  name: string;
  offer_lines: string[];
  expect: string | null;
}

interface QrCase {
  name: string;
  uri: string;
  expect: Record<string, Object> | null;
}

function framesRoot(): Record<string, Object> {
  return JSON.parse(VEC_FRAMES) as Record<string, Object>;
}

function typeOfName(n: string): number {
  switch (n) {
    case 'OPEN': return FrameType.OPEN;
    case 'DATA': return FrameType.DATA;
    case 'FIN': return FrameType.FIN;
    case 'RST': return FrameType.RST;
    case 'WINDOW': return FrameType.WINDOW;
    case 'PING': return FrameType.PING;
    case 'PONG': return FrameType.PONG;
    default: return -1;
  }
}

export default function contractPureTest() {
  describe('contractPure', () => {
    it('codec_base64_roundtrip', 0, () => {
      const samples: number[][] = [[], [0], [1, 2, 3], [255, 254, 253], [0x61, 0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x91, 0x8B]];
      for (const s of samples) {
        const b = new Uint8Array(s);
        expect(bytesEqual(b, base64ToBytes(bytesToBase64(b)))).assertTrue();
      }
      expect(bytesToBase64(new Uint8Array([0]))).assertEqual('AA==');
      expect(bytesToBase64(new Uint8Array([0x61]))).assertEqual('YQ==');
      expect(bytesToBase64(new Uint8Array([0x61, 0x62]))).assertEqual('YWI=');
      expect(bytesToBase64(new Uint8Array([0x61, 0x62, 0x63]))).assertEqual('YWJj');
    });
    it('codec_b64url', 0, () => {
      // 向量里的 nonce：gCEzU1KQjzh6lVGJH_x1ze3ZUdCQtc0vQCixwFIvHm8（base64url 无填充）
      const bytes = b64uToBytes('gCEzU1KQjzh6lVGJH_x1ze3ZUdCQtc0vQCixwFIvHm8');
      expect(bytes.length).assertEqual(32);
      expect(bytesToB64u(bytes)).assertEqual('gCEzU1KQjzh6lVGJH_x1ze3ZUdCQtc0vQCixwFIvHm8');
    });
    it('codec_hex_utf8', 0, () => {
      expect(bytesToHex(utf8Encode('hello|1770000000|gCEz'))).assertEqual(
        '68656c6c6f7c313737303030303030307c6743457a');
      expect(utf8Decode(utf8Encode('hello 中文 👋'))).assertEqual('hello 中文 👋');
      expect(bytesEqual(hexToBytes('00ff10'), new Uint8Array([0, 255, 16]))).assertTrue();
    });

    it('frames_vectors_all_cases', 0, () => {
      const root = framesRoot();
      const cases = root['cases'] as Array<Record<string, Object>>;
      expect(cases.length).assertEqual(14);
      for (const c of cases) {
        const fc = c as Object as FrameCase;
        if (fc.frame_hex === undefined || fc.frame_hex === null) { continue } // JSON null ≠ undefined
        const raw = hexToBytes(fc.frame_hex);
        let thrown: FrameError | null = null;
        let decoded: ReturnType<typeof decodeFrame> | null = null;
        try {
          decoded = decodeFrame(raw);
        } catch (e) {
          thrown = e as FrameError;
        }
        const name = String(c['name']);
        if (name.includes('reject')) {
          // 负例：ver=2 → BAD_VER；len=16374 → LEN_OVERFLOW
          expect(thrown).assertNotNull();
          if (thrown !== null) {
            if (name.includes('ver=2')) { expect(thrown.code).assertEqual('BAD_VER') }
            if (name.includes('16374')) { expect(thrown.code).assertEqual('LEN_OVERFLOW') }
          }
          continue;
        }
        if (name.includes('truncated')) {
          expect(thrown).assertNotNull();
          if (thrown !== null) { expect(thrown.code).assertEqual('HEADER_INCOMPLETE') }
          continue;
        }
        expect(thrown).assertNull();
        const dec = c['decode'] as Object as FrameDecode;
        if (decoded !== null && dec !== undefined) {
          expect(decoded.ver).assertEqual(dec.ver);
          // 已知类型按名字映射；未知类型向量用 type_code 给数值（如 0x2A=42），解码器必须原样带回
          const typeCode = c['decode'] as Record<string, Object>;
          const wantType = typeCode['type_code'] !== undefined
            ? Number(typeCode['type_code'])
            : (typeof dec.type === 'string' ? typeOfName(dec.type) : Number(dec.type));
          expect(decoded.type).assertEqual(wantType);
          if (name.includes('flags=0x05')) {
            expect(decoded.flags).assertEqual(5); // flags 原样带回（接收方忽略不拒帧）
          } else {
            expect(decoded.flags).assertEqual(dec.flags);
          }
          // 控制帧忽略 stream_id 用例的键为 stream_id_read_as（语义相同）
          const wantSid = dec.stream_id !== undefined ? dec.stream_id
            : (typeCode['stream_id_read_as'] !== undefined ? Number(typeCode['stream_id_read_as']) : NaN);
          expect(decoded.streamId).assertEqual(wantSid);
          if (dec.payload_hex !== undefined) {
            expect(bytesToHex(decoded.payload)).assertEqual(dec.payload_hex);
          }
          if (dec.payload_utf8 !== undefined) {
            expect(utf8Decode(decoded.payload)).assertEqual(dec.payload_utf8);
          }
          if (dec.credit !== undefined) {
            expect(decoded.payload.length).assertEqual(4);
            expect(((decoded.payload[0] * 0x1000000) + (decoded.payload[1] << 16) + (decoded.payload[2] << 8) + decoded.payload[3])).assertEqual(dec.credit);
          }
          // re-encode → 逐字节一致（flags 恒置 0：契约 §3.1 发送方 MUST 置 0，故比较前把向量 flags 清零）
          const re = encodeFrame(decoded.type, decoded.streamId, decoded.payload);
          const want = fc.frame_hex.substring(0, 4) + '00' + fc.frame_hex.substring(6);
          expect(bytesToHex(re)).assertEqual(want);
        }
      }
    });
    it('frames_max_payload_boundary', 0, () => {
      const big = new Uint8Array(MAX_PAYLOAD);
      const f = encodeFrame(FrameType.DATA, 1, big);
      expect(f.length).assertEqual(FRAME_HEADER_SIZE + MAX_PAYLOAD);
      const d = decodeFrame(f);
      expect(d.payload.length).assertEqual(MAX_PAYLOAD);
      let threw = false;
      try {
        encodeFrame(FrameType.DATA, 1, new Uint8Array(MAX_PAYLOAD + 1));
      } catch (e) {
        threw = (e as FrameError).code === 'LEN_OVERFLOW';
      }
      expect(threw).assertTrue();
    });
    it('frames_splitter_streaming', 0, () => {
      const f1 = encodeFrame(FrameType.OPEN, 1, utf8Encode('{"authority":"127.0.0.1:13080"}'));
      const f2 = encodeFrame(FrameType.DATA, 1, utf8Encode('abc'));
      const splitter = new FrameSplitter();
      // 逐字节喂入（最苛刻的流式场景）
      const all = new Uint8Array(f1.length + f2.length);
      all.set(f1); all.set(f2, f1.length);
      let got = 0;
      for (let i = 0; i < all.length; i++) {
        got += splitter.push(new Uint8Array([all[i]])).length;
      }
      expect(got).assertEqual(2);
    });

    it('fingerprint_vectors', 0, () => {
      const root = JSON.parse(VEC_FP) as Record<string, Object>;
      const cases = root['cases'] as Array<Record<string, Object>>;
      expect(cases.length).assertEqual(7);
      for (const c of cases) {
        const fc = c as Object as FpCase;
        const got = extractPinnedFingerprint(fc.offer_lines);
        if (fc.expect === null) {
          expect(got).assertEqual('');
        } else {
          expect(got).assertEqual(fc.expect);
        }
      }
    });
    it('fingerprint_verify_pin_negative', 0, () => {
      const lines = ['a=fingerprint:sha-256 AA:BB:CC'];
      expect(verifyPin('aabbcc', lines)).assertTrue();
      expect(verifyPin('aabbcd', lines)).assertFalse();
      expect(verifyPin('', lines)).assertFalse();
      expect(verifyPin('aabbcc', ['m=application 9'])).assertFalse();
    });

    it('qr_vectors', 0, () => {
      const root = JSON.parse(VEC_QR) as Record<string, Object>;
      const cases = root['cases'] as Array<Record<string, Object>>;
      expect(cases.length).assertEqual(5);
      for (const c of cases) {
        const qc = c as Object as QrCase;
        const r = parsePairQr(qc.uri);
        if (qc.expect === null) {
          expect(r.ok).assertFalse();
        } else {
          expect(r.ok).assertTrue();
          if (r.ok && r.qr !== null) {
            expect(r.qr.v).assertEqual(Number(qc.expect['v']));
            expect(r.qr.s).assertEqual(String(qc.expect['s']));
            expect(r.qr.pt).assertEqual(String(qc.expect['pt']));
            expect(r.qr.fp).assertEqual(String(qc.expect['fp']));
            expect(r.qr.a).assertEqual(String(qc.expect['a']));
            const expT = qc.expect['t'];
            if (expT === undefined || expT === null) {
              expect(r.qr.t).assertNull();
            } else {
              expect(r.qr.t).assertEqual(String(expT));
            }
          }
        }
      }
    });

    it('digest_sha256_nist', 0, () => {
      expect(bytesToHex(sha256(utf8Encode('abc')))).assertEqual(
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(bytesToHex(sha256(new Uint8Array(0)))).assertEqual(
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(bytesToHex(sha256(utf8Encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')))).assertEqual(
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      // 跨块（>64B，期望值 2026-09-18 由 node crypto 现算）
      expect(bytesToHex(sha256(utf8Encode('a'.repeat(200))))).assertEqual(
        'c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5');
      expect(bytesToHex(sha256(utf8Encode('a'.repeat(1000))))).assertEqual(
        '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    });

    it('digest_sha1_nist', 0, () => {
      expect(bytesToHex(sha1(utf8Encode('abc')))).assertEqual('a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(bytesToHex(sha1(new Uint8Array(0)))).assertEqual('da39a3ee5e6b4b0d3255bfef95601890afd80709');
    });

    it('digest_hmac_sha1_rfc2202', 0, () => {
      const key20 = new Uint8Array(20).fill(0x0b);
      expect(bytesToHex(hmacSha1(key20, utf8Encode('Hi There')))).assertEqual(
        'b617318655057264e28bc0b6fb378c8ef146be00');
      expect(bytesToHex(hmacSha1(utf8Encode('Jefe'), utf8Encode('what do ya want for nothing?')))).assertEqual(
        'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79');
      const keyAa = new Uint8Array(20).fill(0xaa);
      const dataDd = new Uint8Array(50).fill(0xdd);
      // 期望值经 node crypto + python hmac 双实现核验（RFC 2202 TC3/TC6）
      expect(bytesToHex(hmacSha1(keyAa, dataDd))).assertEqual(
        '125d7342b9ac11cd91a39af48aa17b4f63f175d3');
      // 超块长 key（>64B → 先 hash 再 pad）
      const keyBig = new Uint8Array(80).fill(0xaa);
      expect(bytesToHex(hmacSha1(keyBig, utf8Encode('Test Using Larger Than Block-Size Key - Hash Key First')))).assertEqual(
        'aa4ae5e15272d00e95705637ce8a3b55ed402112');
    });

    it('turn_credential_vector', 0, () => {
      // 2026-09-18 由契约 js/turn.mjs 现算生成（username/credential 固定输入）
      const u = turnUsername('pair-demo-001', 3600, 1770000000);
      expect(u).assertEqual('1770003600:pair-demo-001');
      expect(turnCredential('demo-secret-S-please-ignore', u)).assertEqual('eZWIRZVQqk8+D5L1kRNmEgc46/c=');
    });

    it('der_ecdsa_roundtrip_on_contract_vectors', 0, () => {
      const root = JSON.parse(VEC_HELLO) as Record<string, Object>;
      const cases = root['cases'] as Array<Record<string, Object>>;
      let checked = 0;
      for (const c of cases) {
        const sigB64u = String(c['expected_sig_base64url']);
        const der = b64uToBytes(sigB64u);
        if (der[0] !== 0x30) { continue } // 篡改签名例可能不是合法 DER，跳过 roundtrip
        const raw = derToRaw(der, 32);
        expect(raw.length).assertEqual(64);
        const re = rawToDer(raw);
        expect(bytesToHex(re)).assertEqual(bytesToHex(der));
        checked++;
      }
      expect(checked >= 3).assertTrue();
      // 裸签名直接 roundtrip（r 高位补 0 场景）
      const raw = new Uint8Array(64);
      raw[31] = 0x01; // r = 1（前导零 → DER INTEGER 02 01 01）
      raw[63] = 0xff; // s 高位 1（→ 前补 0x00）
      const der = rawToDer(raw);
      expect(der.length).assertEqual(2 + 3 + 4); // SEQ + (02 01 01) + (02 21 00 ff)
      const back = derToRaw(der, 32);
      expect(bytesEqual(back, raw)).assertTrue();
    });
  });
}
