// Package invitation authenticates manually exchanged WebRTC descriptions.
// It supplies peer authentication; DTLS, supplied by Pion, encrypts traffic.
package invitation

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

const MaxSDP = 128 * 1024
const MaxEncoded = 192 * 1024
const Lifetime = 30 * time.Minute
const OfferPrefix = "farreach-offer://v2/"
const AnswerPrefix = "farreach-answer://v2/"

type Offer struct {
	Version   int    `json:"v"`
	SessionID string `json:"sessionID"`
	Expires   int64  `json:"expires"`
	SDP       string `json:"sdp"`
	Key       string `json:"key"`
}
type Answer struct {
	Version   int    `json:"v"`
	SessionID string `json:"sessionID"`
	Expires   int64  `json:"expires"`
	SDP       string `json:"sdp"`
	MAC       string `json:"mac"`
}

func NewOffer(sdp string, now time.Time) (Offer, error) {
	if err := ValidateSDP(sdp); err != nil {
		return Offer{}, err
	}
	key := make([]byte, 32)
	sid := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		return Offer{}, err
	}
	if _, err := rand.Read(sid); err != nil {
		return Offer{}, err
	}
	return Offer{2, base64.RawURLEncoding.EncodeToString(sid), now.Add(Lifetime).Unix(), sdp, base64.RawURLEncoding.EncodeToString(key)}, nil
}
func (o Offer) String() (string, error) { return encode(OfferPrefix, o) }
func ParseOffer(s string, now time.Time) (Offer, error) {
	var o Offer
	if err := decode(s, OfferPrefix, &o); err != nil {
		return o, err
	}
	if err := o.Validate(now); err != nil {
		return Offer{}, err
	}
	return o, nil
}
func (o Offer) Validate(now time.Time) error {
	if o.Version != 2 || !validToken(o.SessionID, 16) || !validToken(o.Key, 32) || o.Expires <= now.Unix() || o.Expires > now.Add(Lifetime+time.Minute).Unix() {
		return errors.New("invalid or expired invitation")
	}
	return ValidateSDP(o.SDP)
}
func NewAnswer(o Offer, sdp string, now time.Time) (Answer, error) {
	if err := o.Validate(now); err != nil {
		return Answer{}, err
	}
	if err := ValidateSDP(sdp); err != nil {
		return Answer{}, err
	}
	a := Answer{Version: 2, SessionID: o.SessionID, Expires: o.Expires, SDP: sdp}
	a.MAC = base64.RawURLEncoding.EncodeToString(mac(o, a))
	return a, nil
}
func (a Answer) String() (string, error) { return encode(AnswerPrefix, a) }
func ParseAnswer(s string, o Offer, now time.Time) (Answer, error) {
	var a Answer
	if err := decode(s, AnswerPrefix, &a); err != nil {
		return a, err
	}
	if err := o.Validate(now); err != nil {
		return Answer{}, err
	}
	if a.Version != 2 || a.SessionID != o.SessionID || a.Expires != o.Expires || !validToken(a.MAC, 32) {
		return Answer{}, errors.New("answer does not belong to this invitation")
	}
	got, _ := base64.RawURLEncoding.DecodeString(a.MAC)
	if !hmac.Equal(got, mac(o, a)) {
		return Answer{}, errors.New("answer authentication failed")
	}
	if err := ValidateSDP(a.SDP); err != nil {
		return Answer{}, err
	}
	return a, nil
}
func mac(o Offer, a Answer) []byte {
	b, _ := base64.RawURLEncoding.DecodeString(o.Key)
	m := hmac.New(sha256.New, b)
	offerHash := sha256.Sum256([]byte(o.SDP))
	fmt.Fprintf(m, "FarReach-answer-v%d\x00%s\x00%d\x00", a.Version, a.SessionID, a.Expires)
	m.Write(offerHash[:])
	m.Write([]byte(a.SDP))
	return m.Sum(nil)
}
func validToken(s string, n int) bool {
	b, e := base64.RawURLEncoding.DecodeString(s)
	return e == nil && len(b) == n && base64.RawURLEncoding.EncodeToString(b) == s
}
func encode(prefix string, v any) (string, error) {
	b, e := json.Marshal(v)
	if e != nil {
		return "", e
	}
	s := prefix + base64.RawURLEncoding.EncodeToString(b)
	if len(s) > MaxEncoded {
		return "", errors.New("invitation exceeds size limit")
	}
	return s, nil
}
func decode(s, prefix string, v any) error {
	if strings.HasPrefix(s, "farreach-offer://v1/") || strings.HasPrefix(s, "farreach-answer://v1/") {
		return errors.New("incompatible protocol version; update both Macs")
	}
	if len(s) > MaxEncoded || !strings.HasPrefix(s, prefix) {
		return errors.New("invalid invitation format")
	}
	encoded := strings.TrimPrefix(s, prefix)
	b, e := base64.RawURLEncoding.DecodeString(encoded)
	if e != nil || base64.RawURLEncoding.EncodeToString(b) != encoded {
		return errors.New("invalid invitation encoding")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e = d.Decode(v); e != nil {
		return errors.New("invalid invitation data")
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing invitation data")
	}
	return nil
}
func ValidateSDP(s string) error {
	if len(s) < 20 || len(s) > MaxSDP || strings.ContainsRune(s, '\x00') {
		return errors.New("invalid connection description")
	}
	fingerprint := false
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "a=fingerprint:sha-256 ") {
			value := strings.TrimPrefix(line, "a=fingerprint:sha-256 ")
			raw, err := hex.DecodeString(strings.ReplaceAll(value, ":", ""))
			if err != nil || len(raw) != 32 {
				return errors.New("invalid DTLS fingerprint")
			}
			fingerprint = true
		}
		if strings.HasPrefix(line, "a=candidate:") {
			fields := strings.Fields(line)
			typ := ""
			for i := 0; i+1 < len(fields); i++ {
				if fields[i] == "typ" {
					typ = fields[i+1]
				}
			}
			if typ != "host" && typ != "srflx" && typ != "prflx" {
				return errors.New("relay or unknown ICE candidates are forbidden")
			}
		}
	}
	if !fingerprint {
		return errors.New("connection description has no SHA-256 identity")
	}
	return nil
}
