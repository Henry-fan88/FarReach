package wire

import (
	"encoding/binary"
	"errors"
	"time"
)

const MediaChunkSize = 16384

// MediaAssembler accepts one ordered local IPC transfer. Control frames may be
// interleaved between chunks; no network peer may send this local-only command.
type MediaAssembler struct {
	id            uint64
	total, offset int
	data          []byte
	started       time.Time
}

func (a *MediaAssembler) Reset() { *a = MediaAssembler{} }
func (a *MediaAssembler) Push(b []byte, now time.Time) ([]byte, error) {
	if len(b) <= 16 || len(b) > 16+MediaChunkSize {
		return nil, errors.New("invalid media IPC chunk")
	}
	id := binary.BigEndian.Uint64(b[:8])
	total := int(binary.BigEndian.Uint32(b[8:12]))
	offset := int(binary.BigEndian.Uint32(b[12:16]))
	if id == 0 || total < 25 || total > MaxVideo || offset > total || len(b)-16 > total-offset {
		return nil, errors.New("invalid media IPC bounds")
	}
	if offset == 0 {
		a.id = id
		a.total = total
		a.offset = 0
		a.data = make([]byte, 0, total)
		a.started = now
	}
	if a.id == 0 && offset > 0 {
		return nil, nil
	}
	if id != a.id || total != a.total || offset != a.offset || now.Sub(a.started) > 2*time.Second {
		a.Reset()
		return nil, errors.New("invalid media IPC sequence")
	}
	a.data = append(a.data, b[16:]...)
	a.offset += len(b) - 16
	if a.offset != a.total {
		return nil, nil
	}
	data := a.data
	a.Reset()
	return data, nil
}
func MediaFragment(id uint64, data []byte, offset int) Frame {
	end := min(offset+MediaChunkSize, len(data))
	b := make([]byte, 16+end-offset)
	binary.BigEndian.PutUint64(b[:8], id)
	binary.BigEndian.PutUint32(b[8:12], uint32(len(data)))
	binary.BigEndian.PutUint32(b[12:16], uint32(offset))
	copy(b[16:], data[offset:end])
	return Frame{Kind: MediaChunk, Payload: b}
}
