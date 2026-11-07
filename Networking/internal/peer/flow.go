package peer

import "encoding/json"

// Media capacity is private app/helper IPC, not a remote protocol capability.
// A sender opts in and consumes exactly one grant for one encoded access unit.
// References remain intact because new raw pixels are not encoded while the
// preceding access unit is waiting in the network pacer.
func (p *Connection) emitMediaCapacityLocked(available bool) {
	body, _ := json.Marshal(struct {
		Generation uint64 `json:"generation"`
		Available  bool   `json:"available"`
	}{p.mediaGeneration, available})
	p.emit("mediaCapacity", string(body))
}
func (p *Connection) maybeGrantMediaCapacity() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.cfg.MediaFlowControl || p.cfg.Role != "host" || !p.ready || p.closed || !p.connected || !p.authorized || p.mediaGeneration == 0 || !p.flowNeedsGrant || p.flowCredit || p.pacer == nil || !p.pacer.Drained() {
		return
	}
	p.flowCredit = true
	p.flowNeedsGrant = false
	p.emitMediaCapacityLocked(true)
}
func (p *Connection) completeMediaFlow(generation, sequence uint64) {
	p.mu.Lock()
	if !p.cfg.MediaFlowControl || p.closed || !p.authorized || p.mediaGeneration != generation || p.flowSequence != sequence {
		p.mu.Unlock()
		return
	}
	p.flowNeedsGrant = true
	p.mu.Unlock()
	p.maybeGrantMediaCapacity()
}
