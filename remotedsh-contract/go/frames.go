// Package contract 是 remotedsh-contract 的 Go 参考实现。
// 帧编解码依据：契约 §3.1–§3.3（11B 大端帧头；len ≤ 16373；flags 恒 0；PING/PONG stream_id=0）。
package contract

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	FrameHeaderSize = 11
	MaxPayload      = 16373 // len ≤ 16373 ⇒ 总帧 ≤ 16384（契约 §3.1）
	MaxFrameSize    = 16384
	FrameVer        = 1
)

// 帧类型（契约 §3.2）
const (
	TypeOpen   = 0x01
	TypeData   = 0x02
	TypeFin    = 0x03
	TypeRst    = 0x04
	TypeWindow = 0x05
	TypePing   = 0x06
	TypePong   = 0x07
)

var (
	ErrBadVer          = errors.New("contract: frame ver != 1 (契约 §3.1 非 1 立即断开)")
	ErrLenOverflow     = errors.New("contract: frame len > 16373 (契约 §3.1)")
	ErrHeaderIncomplet = errors.New("contract: frame header incomplete")
	ErrTruncated       = errors.New("contract: frame payload truncated")
)

type Frame struct {
	Ver      uint8
	Type     uint8
	Flags    uint8 // 接收方 MUST 忽略非 0（契约 §3.1）；发送方由本库恒写 0
	StreamID uint32
	Payload  []byte
}

// EncodeFrame 编码一帧。payload 超限返回 ErrLenOverflow（发送侧防线）。
func EncodeFrame(typ uint8, streamID uint32, payload []byte) ([]byte, error) {
	if len(payload) > MaxPayload {
		return nil, fmt.Errorf("%w: len=%d", ErrLenOverflow, len(payload))
	}
	out := make([]byte, FrameHeaderSize+len(payload))
	out[0] = FrameVer
	out[1] = typ
	out[2] = 0 // flags 恒 0
	binary.BigEndian.PutUint32(out[3:7], streamID)
	binary.BigEndian.PutUint32(out[7:11], uint32(len(payload)))
	copy(out[FrameHeaderSize:], payload)
	return out, nil
}

// DecodeFrame 解码一帧（无拷贝：Payload 引用入参切片）。
func DecodeFrame(b []byte) (*Frame, error) {
	if len(b) < FrameHeaderSize {
		return nil, fmt.Errorf("%w: have %d bytes", ErrHeaderIncomplet, len(b))
	}
	ver := b[0]
	if ver != FrameVer {
		return nil, fmt.Errorf("%w: ver=%d", ErrBadVer, ver)
	}
	length := binary.BigEndian.Uint32(b[7:11])
	if length > MaxPayload {
		return nil, fmt.Errorf("%w: len=%d", ErrLenOverflow, length)
	}
	if uint32(len(b)-FrameHeaderSize) < length {
		return nil, ErrTruncated
	}
	f := &Frame{
		Ver:      ver,
		Type:     b[1],
		Flags:    b[2], // 读取但不得据此拒帧
		StreamID: binary.BigEndian.Uint32(b[3:7]),
		Payload:  b[FrameHeaderSize : FrameHeaderSize+length],
	}
	return f, nil
}
