// FarReachNetwork is a private app helper. Stdout is exclusively framed IPC.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sync"
	"time"

	"farreach.local/networking/internal/peer"
	"farreach.local/networking/internal/wire"
)

const maximumOutputVideoBytes = 8 * 1024 * 1024

type outputQueue struct {
	videoMu         sync.Mutex
	videoBytes      int
	videoGeneration uint64
	controls        chan wire.Frame
	pointer         chan wire.Frame
	video           chan wire.Frame
	stop            chan struct{}
	done            chan struct{}
	once            sync.Once
}

func newOutputQueue() *outputQueue {
	return &outputQueue{controls: make(chan wire.Frame, 64), pointer: make(chan wire.Frame, 1), video: make(chan wire.Frame, 12), stop: make(chan struct{}), done: make(chan struct{})}
}
func newOutput() *outputQueue { q := newOutputQueue(); go q.writeLoop(os.Stdout); return q }
func (q *outputQueue) writeLoop(writer io.Writer) {
	defer close(q.done)
	var transfer uint64
	for {
		var f wire.Frame
		select {
		case f = <-q.controls:
		default:
			select {
			case f = <-q.controls:
			case f = <-q.pointer:
			case f = <-q.video:
			case <-q.stop:
				for {
					select {
					case f = <-q.controls:
						if wire.Write(writer, f) != nil {
							return
						}
					default:
						return
					}
				}
			}
		}
		if f.Kind == wire.Video {
			q.videoMu.Lock()
			q.videoBytes -= len(f.Payload)
			q.videoMu.Unlock()
			transfer++
			for offset := 0; offset < len(f.Payload); offset += wire.MediaChunkSize {
				if !q.currentVideoGeneration(f.Payload) {
					break
				}
				for {
					select {
					case control := <-q.controls:
						if wire.Write(writer, control) != nil {
							return
						}
					default:
						goto controlsDrained
					}
				}
			controlsDrained:
				select {
				case pointer := <-q.pointer:
					if wire.Write(writer, pointer) != nil {
						return
					}
				default:
				}
				if wire.Write(writer, wire.MediaFragment(transfer, f.Payload, offset)) != nil {
					return
				}
			}
		} else if wire.Write(writer, f) != nil {
			return
		}
	}
}
func (q *outputQueue) send(f wire.Frame) bool {
	select {
	case <-q.done:
		return false
	default:
	}
	if f.Kind == wire.Pointer {
		select {
		case q.pointer <- f:
			return true
		default:
		}
		select {
		case <-q.pointer:
		default:
		}
		select {
		case q.pointer <- f:
			return true
		default:
			return false
		}
	}
	if f.Kind == wire.Video {
		q.videoMu.Lock()
		defer q.videoMu.Unlock()
		// Delayed output from an old capture epoch is intentionally ignored. It must
		// not poison the new reference chain by requesting another IDR.
		if frameGeneration(f.Payload) != q.videoGeneration || q.videoGeneration == 0 {
			return true
		}
		if len(f.Payload) > maximumOutputVideoBytes-q.videoBytes {
			return false
		}
		select {
		case q.video <- f:
			q.videoBytes += len(f.Payload)
			return true
		default:
			return false
		}
	}

	select {
	case q.controls <- f:
		return true
	default:
		return false
	}
}
func frameGeneration(data []byte) uint64 {
	if len(data) < 12 || string(data[:4]) != "FRS1" {
		return 0
	}
	return binary.BigEndian.Uint64(data[4:12])
}
func (q *outputQueue) currentVideoGeneration(data []byte) bool {
	q.videoMu.Lock()
	defer q.videoMu.Unlock()
	return q.videoGeneration > 0 && frameGeneration(data) == q.videoGeneration
}
func (q *outputQueue) setMediaGeneration(generation uint64) {
	q.videoMu.Lock()
	defer q.videoMu.Unlock()
	if q.videoGeneration == generation {
		return
	}
	q.videoGeneration = generation
	for {
		select {
		case frame := <-q.video:
			q.videoBytes -= len(frame.Payload)
		default:
			return
		}
	}
}
func (q *outputQueue) event(kind, value string) {
	b, _ := json.Marshal(peer.Event{Type: kind, Value: value})
	q.send(wire.Frame{Kind: wire.Event, Payload: b})
}
func (q *outputQueue) close() { q.once.Do(func() { close(q.stop) }); <-q.done }
func decodeJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil {
		return errors.New("invalid helper configuration")
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("invalid trailing configuration")
	}
	return nil
}

func main() { os.Exit(run()) }
func run() int {
	out := newOutput()
	defer out.close()
	type readResult struct {
		frame wire.Frame
		err   error
	}
	incoming := make(chan readResult, 1)
	go func() {
		for {
			f, e := wire.Read(os.Stdin)
			incoming <- readResult{f, e}
			if e != nil {
				return
			}
		}
	}()
	var media wire.MediaAssembler
	var previousAuthorization peer.MediaAuthorization
	var connection *peer.Connection
	var done <-chan struct{}
	var started bool
	startErrors := make(chan error, 1)
	defer func() {
		if connection != nil {
			connection.Close()
		}
	}()
	for {
		select {
		case err := <-startErrors:
			if err != nil {
				out.event("error", err.Error())
				return 1
			}
		case <-done:
			return 0
		case item := <-incoming:
			if item.err != nil {
				if item.err != io.EOF {
					out.event("error", "invalid or truncated helper input")
					return 1
				}
				return 0
			}
			f := item.frame
			if !started {
				if f.Kind != wire.Configure {
					out.event("error", "configure the helper before sending messages")
					return 1
				}
				var config peer.Config
				if err := decodeJSON(f.Payload, &config); err != nil {
					out.event("error", err.Error())
					return 1
				}
				var err error
				connection, err = peer.New(config, out.send)
				if err != nil {
					out.event("error", err.Error())
					return 1
				}
				started = true
				done = connection.Done()
				go func() { startErrors <- connection.Start() }()
				continue
			}
			if f.Kind == wire.ApplyAnswer {
				var command struct {
					Response string `json:"response"`
				}
				if err := decodeJSON(f.Payload, &command); err != nil {
					out.event("error", err.Error())
					return 1
				}
				if err := connection.ApplyAnswer(command.Response); err != nil {
					out.event("error", err.Error())
					return 1
				}
				continue
			}
			if f.Kind == wire.Configure {
				out.event("error", "helper cannot be reconfigured")
				return 1
			}
			if f.Kind == wire.MediaAuthorization {
				var authorization peer.MediaAuthorization
				if err := decodeJSON(f.Payload, &authorization); err != nil {
					out.event("error", err.Error())
					return 1
				}
				if !authorization.Authorized {
					authorization.Generation = 0
				}
				if authorization != previousAuthorization {
					media.Reset()
					out.setMediaGeneration(authorization.Generation)
					previousAuthorization = authorization
				}
				if err := connection.AuthorizeMedia(authorization); err != nil {
					out.event("error", err.Error())
					return 1
				}
				continue
			}
			if f.Kind == wire.MediaChunk {
				data, err := media.Push(f.Payload, time.Now())
				if err != nil {
					out.event("error", err.Error())
					return 1
				}
				if data == nil {
					continue
				}
				f = wire.Frame{Kind: wire.Video, Payload: data}
			}
			if err := connection.Send(f); err != nil {
				out.event("error", err.Error())
				return 1
			}
		}
	}
}
