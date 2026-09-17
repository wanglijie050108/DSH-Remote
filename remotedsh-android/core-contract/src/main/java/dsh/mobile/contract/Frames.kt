// 帧编解码（契约 §3.1–§3.3）——与 js/frames.mjs、go/frames.go 共用 vectors/frames.json
// 11B 大端帧头：ver u8 / type u8 / flags u8 / stream_id u32 / len u32；len ≤ 16373
package dsh.mobile.contract

import java.nio.ByteBuffer

object Frames {
    const val FRAME_HEADER_SIZE = 11
    const val MAX_PAYLOAD = 16373
    const val MAX_FRAME_SIZE = 16384
    const val FRAME_VER = 1

    const val TYPE_OPEN: Byte = 0x01
    const val TYPE_DATA: Byte = 0x02
    const val TYPE_FIN: Byte = 0x03
    const val TYPE_RST: Byte = 0x04
    const val TYPE_WINDOW: Byte = 0x05
    const val TYPE_PING: Byte = 0x06
    const val TYPE_PONG: Byte = 0x07
}

class FrameException(val code: String, message: String) : Exception(message)

data class Frame(
    val ver: Int,
    val type: Int,
    val flags: Int, // 接收方 MUST 忽略非 0（契约 §3.1）
    val streamId: Long,
    val payload: ByteArray,
) {
    override fun equals(other: Any?): Boolean = other is Frame &&
        ver == other.ver && type == other.type && flags == other.flags &&
        streamId == other.streamId && payload.contentEquals(other.payload)
    override fun hashCode(): Int = ver * 31 + type * 7 + streamId.hashCode()
}

object FrameCodec {
    /** 编码一帧；flags 恒写 0（发送方 MUST，契约 §3.1）。超限抛 FrameException("LEN_OVERFLOW") */
    fun encode(type: Int, streamId: Long, payload: ByteArray = ByteArray(0)): ByteArray {
        if (payload.size > Frames.MAX_PAYLOAD) {
            throw FrameException("LEN_OVERFLOW", "len=${payload.size} > ${Frames.MAX_PAYLOAD}")
        }
        if (streamId < 0 || streamId > 0xFFFFFFFFL) {
            throw FrameException("BAD_STREAM_ID", "stream_id=$streamId 超出 u32 范围（契约 §3.1）")
        }
        val out = ByteArray(Frames.FRAME_HEADER_SIZE + payload.size)
        val b = ByteBuffer.wrap(out)
        b.put(Frames.FRAME_VER.toByte()).put(type.toByte()).put(0)
        b.putInt(streamId.toInt()).putInt(payload.size)
        b.put(payload)
        return out
    }

    /** 帧头不完整抛 FrameException("HEADER_INCOMPLETE")；ver!=1 抛 "BAD_VER"；len 超限抛 "LEN_OVERFLOW" */
    fun decode(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset): Frame {
        if (length < Frames.FRAME_HEADER_SIZE) {
            throw FrameException("HEADER_INCOMPLETE", "only $length bytes")
        }
        val b = ByteBuffer.wrap(bytes, offset, length)
        val ver = b.get().toInt() and 0xFF
        if (ver != Frames.FRAME_VER) throw FrameException("BAD_VER", "ver=$ver")
        val type = b.get().toInt() and 0xFF
        val flags = b.get().toInt() and 0xFF
        val streamId = b.int.toLong() and 0xFFFFFFFFL
        // ByteBuffer.getInt() 返回 signed int；契约 len 是 u32（0–16373），转 unsigned 后校验
        val len = b.int.toLong() and 0xFFFFFFFFL
        if (len > Frames.MAX_PAYLOAD) throw FrameException("LEN_OVERFLOW", "len=$len")
        if (length - Frames.FRAME_HEADER_SIZE < len) throw FrameException("HEADER_INCOMPLETE", "truncated")
        val payloadLen = len.toInt()
        val payload = ByteArray(payloadLen)
        b.get(payload)
        return Frame(ver, type, flags, streamId, payload)
    }
}
