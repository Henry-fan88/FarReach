package invitation

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

const testSDP = "v=0\r\na=fingerprint:sha-256 01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F:20\r\na=candidate:1 1 udp 1 127.0.0.1 9000 typ host\r\n"

func TestRoundTripAndAuthenticatedAnswer(t *testing.T) {
	now := time.Now()
	offer, e := NewOffer(testSDP, now)
	if e != nil {
		t.Fatal(e)
	}
	s, _ := offer.String()
	parsed, e := ParseOffer(s, now)
	if e != nil {
		t.Fatal(e)
	}
	a, e := NewAnswer(parsed, testSDP+"a=setup:active\r\n", now)
	if e != nil {
		t.Fatal(e)
	}
	response, _ := a.String()
	if _, e = ParseAnswer(response, offer, now); e != nil {
		t.Fatal(e)
	}
	altered := offer
	altered.SDP += "a=changed:yes\r\n"
	if _, e = ParseAnswer(response, altered, now); e == nil {
		t.Fatal("answer failed to bind original offer")
	}
	a.SDP += "a=tampered:yes\r\n"
	bad, _ := a.String()
	if _, e = ParseAnswer(bad, offer, now); e == nil {
		t.Fatal("tampered answer accepted")
	}
	other, _ := NewOffer(testSDP, now)
	if _, e = ParseAnswer(response, other, now); e == nil {
		t.Fatal("wrong session accepted")
	}
	if _, e = ParseAnswer(response, offer, now.Add(Lifetime+time.Second)); e == nil {
		t.Fatal("expired answer accepted")
	}
	if _, e = ParseOffer(response, now); e == nil {
		t.Fatal("wrong role accepted")
	}
	if _, e = ParseAnswer(s, offer, now); e == nil {
		t.Fatal("offer accepted as answer")
	}
}
func TestRejectsRelayAndOversizedDescription(t *testing.T) {
	for _, s := range []string{strings.Replace(testSDP, "typ host", "typ relay", 1), strings.Repeat("a", MaxSDP+1), "v=0\r\nno fingerprint", strings.Replace(testSDP, "typ host", "typ unknown", 1)} {
		if ValidateSDP(s) == nil {
			t.Fatal("invalid SDP accepted")
		}
	}
	now := time.Now()
	offer, _ := NewOffer(testSDP, now)
	offer.Key = base64.RawURLEncoding.EncodeToString(make([]byte, 31))
	s, _ := offer.String()
	if _, e := ParseOffer(s, now); e == nil {
		t.Fatal("short key accepted")
	}
	if _, e := ParseOffer(OfferPrefix+strings.Repeat("a", MaxEncoded), now); e == nil {
		t.Fatal("oversized invitation accepted")
	}
}
