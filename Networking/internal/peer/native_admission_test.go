package peer

import (
	"encoding/binary"
	"io"
	"os"
	"strconv"
	"testing"

	"farreach.local/networking/internal/video"
)

func TestNativeKeyframeAdmissionDiagnostics(t *testing.T) {
	path := os.Getenv("FARREACH_NATIVE_FRAME_FIXTURE")
	if path == "" {
		t.Skip("set FARREACH_NATIVE_FRAME_FIXTURE to measure native access-unit admission")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	expectAdmission := os.Getenv("FARREACH_REQUIRE_NATIVE_KEYFRAME_ADMISSION") == "1"
	rate := 2_000_000
	if value := os.Getenv("FARREACH_NATIVE_PACER_BITRATE"); value != "" {
		rate, err = strconv.Atoi(value)
		if err != nil {
			t.Fatal(err)
		}
	}
	p := newPacer()
	defer p.Close()
	p.SetTargetBitrate(rate)
	effectiveRate := p.rate
	frames, keys, rejectedKeys, rejectedDeltas := 0, 0, 0, 0
	for {
		var header [4]byte
		if _, err = io.ReadFull(file, header[:]); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		n := binary.BigEndian.Uint32(header[:])
		if n < 37 || n > video.MaxFrame {
			t.Fatal("fixture bounds")
		}
		data := make([]byte, n)
		if _, err = io.ReadFull(file, data); err != nil {
			t.Fatal(err)
		}
		frames++
		packets, err := video.Packetize(data, uint64(frames), uint32(frames*3000), 0, 1)
		if err != nil {
			t.Fatal(err)
		}
		meta, err := video.ParseMetadata(packets[0].GetExtension(1))
		if err != nil {
			t.Fatal(err)
		}
		wireBytes := 0
		for _, packet := range packets {
			wireBytes += packet.MarshalSize() + 8
		}
		p.SetGeneration(meta.Generation)
		admitted := p.BeginFrame(meta, wireBytes, 1)
		if meta.Keyframe {
			keys++
			if !admitted {
				rejectedKeys++
			}
			t.Logf("NATIVE_KEYFRAME_ADMISSION frame=%d encodedBytes=%d packetizedBytes=%d requestedBitrate=%d pacerBitrate=%d normalBudgetBytes=%d accepted=%t", frames, len(data), wireBytes, rate, effectiveRate, int(float64(effectiveRate)*meta.Budget().Seconds()/8), admitted)
		} else if !admitted {
			rejectedDeltas++
		}
	}
	t.Logf("NATIVE_ADMISSION_SUMMARY frames=%d keyframes=%d rejectedKeys=%d rejectedDeltas=%d pacerBitrate=%d", frames, keys, rejectedKeys, rejectedDeltas, rate)
	if keys == 0 {
		t.Fatal("fixture has no native keyframe")
	}
	if expectAdmission && rejectedKeys > 0 {
		t.Fatalf("native recovery pictures cannot enter the transport: %d/%d rejected", rejectedKeys, keys)
	}
}
