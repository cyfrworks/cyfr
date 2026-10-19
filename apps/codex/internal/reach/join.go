// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// JoinDeadline is how long a join waits for its approval. The join
// container carries it in its own command, so it ends then whether or not
// the command that started it lives.
const JoinDeadline = 10 * time.Minute

// joinGrace is how long past its deadline the engine waits for a join
// container to end by itself before it removes it.
const joinGrace = 30 * time.Second

// keyDeadline bounds the call that hands the auth key to the join
// container's standard input.
const keyDeadline = 30 * time.Second

const defaultHostname = "cyfr"

var hostnameGrammar = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

const hostnameRule = "a machine name is 1 to 63 lowercase letters, digits and hyphens, beginning and ending with a letter or a digit"

// joinRecord is join.json: the current join attempt, and once it has
// joined, the machine's name and node id, frozen.
type joinRecord struct {
	JoinID    string    `json:"join_id"`
	RequestID string    `json:"request_id"`
	Deadline  time.Time `json:"deadline"`
	State     string    `json:"state"`
	Name      string    `json:"name,omitempty"`
	NodeID    string    `json:"node_id,omitempty"`
	HTTPS     *bool     `json:"https,omitempty"`
}

// joinAttempt is a join as its journal carries it: the record, the
// request that made it, and what its container needs.
type joinAttempt struct {
	joinRecord
	RequestDigest string `json:"request_digest"`
	Hostname      string `json:"hostname"`
	NewNode       bool   `json:"new_node,omitempty"`
	Image         string `json:"image,omitempty"`
	Container     string `json:"container,omitempty"`
	Key           bool   `json:"key,omitempty"`
}

func (e *Engine) readJoin() (*joinRecord, error) {
	var r joinRecord
	ok, err := readJSON(e.path(joinFile), &r)
	if err != nil || !ok {
		return nil, err
	}
	return &r, nil
}

func (e *Engine) writeJoin(r joinRecord) error { return e.writeJSON(e.path(joinFile), r) }

// refusal is why a switch cannot take the attempt's machine, nil when it
// has joined.
func (r *joinRecord) refusal() *Refusal {
	switch r.State {
	case "joined":
		return nil
	case "https_off":
		return Refuse("tailnet_https_off", map[string]string{"name": r.Name})
	case "expired":
		return Refuse("tailnet_join_expired", nil)
	case "ended":
		return Refuse("tailnet_join_ended", nil)
	case "cancelled":
		return Refuse("tailnet_join_cancelled", nil)
	case "unsupported":
		return Refuse("tailnet_node_id_unsupported", map[string]string{"value": r.NodeID})
	}
	return Refuse("tailnet_not_joined", nil)
}

// frozenJoin is the name and id join joinID froze: join.json's while it
// is current, else its receipt's.
func (e *Engine) frozenJoin(joinID string, cur *joinRecord) *Join {
	if cur != nil && cur.JoinID == joinID {
		if cur.State != "joined" {
			return nil
		}
		return &Join{Name: cur.Name, NodeID: cur.NodeID}
	}
	return e.joinReceiptFor(joinID)
}

// joinReceiptFor is the frozen machine of the join receipt naming joinID.
func (e *Engine) joinReceiptFor(joinID string) *Join {
	entries, err := readDirNames(e.path(receiptsDir))
	if err != nil {
		return nil
	}
	for _, name := range entries {
		var r Receipt
		if ok, err := readJSON(e.path(receiptsDir, name), &r); err == nil && ok && r.Op == "join" && r.Code == "" && r.Payload["join_id"] == joinID {
			return &Join{Name: r.Payload["name"], NodeID: r.Payload["node_id"]}
		}
	}
	return nil
}

// joinRequest is a join's canonical request: the machine name, whether
// the identity is replaced first, and the auth key's fingerprint, never
// the key.
func joinDigest(hostname string, newNode bool, key []byte) string {
	fields := map[string]any{"op": "join", "hostname": hostname, "new_node": newNode}
	if len(key) > 0 {
		fields["auth_key_fingerprint"] = "sha256:" + sha256Hex(key)
	}
	return requestDigest(fields)
}

func (e *Engine) doJoin(ctx context.Context, r JoinRequest) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	var key []byte
	if r.AuthKey != nil {
		raw, err := io.ReadAll(r.AuthKey)
		if err != nil {
			return Receipt{}, fmt.Errorf("reach: read the auth key: %w", err)
		}
		key = bytes.TrimSpace(raw)
	}
	hostname := strings.ToLower(strings.TrimSpace(r.Hostname))
	if hostname == "" {
		hostname = defaultHostname
	}
	digest := joinDigest(hostname, r.NewNode, key)
	if rc, ok, err := e.lookup(r.ID, digest); err != nil || ok {
		if err != nil {
			return Receipt{}, err
		}
		return answer(rc)
	}
	if rc, blocked, err := e.blocked(r.ID, digest, "join"); blocked || err != nil {
		return rc, err
	}
	refuse := func(err error) (Receipt, error) {
		var ref *Refusal
		if errors.As(err, &ref) {
			return e.reject(r.ID, digest, "join", ref)
		}
		return Receipt{}, err
	}
	if !hostnameGrammar.MatchString(hostname) {
		return refuse(invalid(hostname, "tailnet_name", hostnameRule))
	}
	st, err := e.readState()
	if err != nil {
		return refuse(err)
	}
	if e.tailnetActive(ctx, st) {
		return refuse(Refuse("tailnet_active", map[string]string{"name": st.head.Host}))
	}
	image, err := e.serveImage(ctx)
	if err != nil {
		return refuse(Refuse("docker_unavailable", map[string]string{"reason": err.Error()}))
	}
	js, err := e.observeJoins(ctx)
	if err != nil {
		return refuse(Refuse("docker_unavailable", map[string]string{"reason": err.Error()}))
	}
	for _, c := range js {
		if running(c.State) && e.now().Before(c.expiry()) {
			return refuse(joinBusy(c.JoinID, c.expiry()))
		}
	}

	a := &joinAttempt{
		joinRecord:    joinRecord{JoinID: newRequestID(), RequestID: r.ID, Deadline: e.now().Add(JoinDeadline).UTC().Truncate(time.Second), State: "waiting"},
		RequestDigest: digest, Hostname: hostname, NewNode: r.NewNode, Image: image, Key: len(key) > 0,
	}
	j := &journal{Op: "join", RequestID: r.ID, RequestDigest: digest, Join: a}
	if err := e.setPhase(j, "accepted"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	if err := e.writeJoin(a.joinRecord); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.runJoin(ctx, j, key, r.OnAuthURL)
}

// serveImage is the tailscale service's image, which a join container
// runs.
func (e *Engine) serveImage(ctx context.Context) (string, error) {
	content, err := e.flatten(ctx, Head{Profiles: []string{ModeTailnet}})
	if err != nil {
		return "", err
	}
	c, err := parseConfig(content)
	if err != nil {
		return "", err
	}
	svc, ok := c.Services[serveService]
	if !ok || svc.Image == "" {
		return "", fmt.Errorf("the stack's configuration has no %s service image", serveService)
	}
	return svc.Image, nil
}

func (e *Engine) joinNetwork() string { return e.project + "_tailnet-join" }
func (e *Engine) stateVolume() string { return e.project + "_tailscale_state" }

// runJoin starts the accepted join's container and waits for its end:
// joined, HTTPS off, expired at its deadline, or cancelled with ctx.
func (e *Engine) runJoin(ctx context.Context, j *journal, key []byte, onAuthURL func(string)) (Receipt, error) {
	a := j.Join
	bg := context.WithoutCancel(ctx)
	if why := e.prepareJoin(bg, a); why != "" {
		return e.outcomeUnknown(j, errors.New(why))
	}
	if a.NewNode {
		if err := e.setPhase(j, "new_node"); err != nil {
			return e.outcomeUnknown(j, err)
		}
	}
	name, why := e.startJoinContainer(bg, a)
	if why != "" {
		return e.outcomeUnknown(j, errors.New(why))
	}
	a.Container = name
	if err := e.setPhase(j, "waiting"); err != nil {
		return e.outcomeUnknown(j, err)
	}

	// The key reaches containerboot on its standard input alone. The
	// call that carries it is killed once tailscaled answers, which it
	// does only after the key was read.
	var stopKey context.CancelFunc = func() {}
	if len(key) > 0 {
		keyCtx, cancel := context.WithCancel(bg)
		stopKey = cancel
		go e.docker.Run(keyCtx, Call{Args: []string{"attach", "--sig-proxy=false", name}, Stdin: bytes.NewReader(append(key, '\n')), Deadline: keyDeadline, Stdout: io.Discard, Stderr: io.Discard})
	}
	defer stopKey()

	shown := ""
	status := []string{"exec", name, "tailscale", "status", "--json"}
	for {
		if ctx.Err() != nil {
			return e.cancelJoin(bg, j, nil)
		}
		s, err := e.readStatus(bg, status)
		if err == nil {
			stopKey()
			if s.BackendState == "Running" {
				if err := e.sleep(bg, time.Second); err != nil {
					return e.outcomeUnknown(j, err)
				}
				if again, err := e.readStatus(bg, status); err == nil && again.agrees(s) {
					return e.joined(bg, j, s)
				}
				continue
			}
			if s.AuthURL != "" && s.AuthURL != shown && onAuthURL != nil {
				shown = s.AuthURL
				onAuthURL(s.AuthURL)
			}
		} else if gone, err := e.joinGone(bg, a); err == nil && gone {
			if !e.now().Before(a.Deadline) {
				return e.expireJoin(bg, j)
			}
			return e.endedJoin(bg, j)
		}
		if !e.now().Before(a.Deadline.Add(joinGrace)) {
			return e.expireJoin(bg, j)
		}
		if err := e.sleep(ctx, time.Second); err != nil && ctx.Err() == nil {
			return e.outcomeUnknown(j, err)
		}
	}
}

// prepareJoin clears the way for a join container: the tailscale
// service stopped and removed, so no two tailscaleds share the state;
// with --new-node, the state removed too, so the machine joins afresh;
// the state volume and the join's own network created.
func (e *Engine) prepareJoin(ctx context.Context, a *joinAttempt) string {
	cs, err := e.observe(ctx)
	if err != nil {
		return err.Error()
	}
	var serve []string
	for _, c := range cs {
		if c.Service == serveService {
			serve = append(serve, c.Name)
		}
	}
	if len(serve) > 0 {
		if why := e.stopRemove(ctx, serve); why != "" {
			return why
		}
	}
	if a.NewNode {
		res, err := e.docker.Run(ctx, Call{Args: []string{"volume", "rm", "--force", e.stateVolume()}, Deadline: StopDeadline})
		if err != nil {
			return fmt.Sprintf("docker volume rm failed (%v): %s", err, lastLine(res.Stderr))
		}
	}
	if _, err := e.docker.Run(ctx, Call{Args: []string{"volume", "inspect", e.stateVolume()}, Deadline: probeDeadline}); err != nil {
		res, err := e.docker.Run(ctx, Call{Args: []string{"volume", "create", "--label", labelProject + "=" + e.project, "--label", "com.docker.compose.volume=tailscale_state", e.stateVolume()}, Deadline: StopDeadline})
		if err != nil {
			return fmt.Sprintf("docker volume create failed (%v): %s", err, lastLine(res.Stderr))
		}
	}
	if _, err := e.docker.Run(ctx, Call{Args: []string{"network", "inspect", e.joinNetwork()}, Deadline: probeDeadline}); err != nil {
		res, err := e.docker.Run(ctx, Call{Args: []string{"network", "create", "--label", labelJoinProject + "=" + e.project, e.joinNetwork()}, Deadline: StopDeadline})
		if err != nil {
			return fmt.Sprintf("docker network create failed (%v): %s", err, lastLine(res.Stderr))
		}
	}
	return ""
}

// startJoinContainer runs the one-off join container: the tailscale
// service's image on its own network with the state volume, labelled
// with its join id and deadline, ending by itself at the deadline.
func (e *Engine) startJoinContainer(ctx context.Context, a *joinAttempt) (string, string) {
	seconds := int(math.Ceil(a.Deadline.Sub(e.now()).Seconds()))
	if seconds < 1 {
		seconds = 1
	}
	name := e.project + "-tailnet-join-" + a.JoinID[:12]
	args := []string{"run", "-d"}
	if a.Key {
		args = append(args, "-i")
	}
	args = append(args, "--rm", "--name", name,
		"--label", labelJoinProject+"="+e.project,
		"--label", labelJoinID+"="+a.JoinID,
		"--label", labelJoinDeadline+"="+a.Deadline.UTC().Format(time.RFC3339),
		"--network", e.joinNetwork(),
		"-v", e.stateVolume()+":/var/lib/tailscale",
		"-e", "TS_USERSPACE=true", "-e", "TS_STATE_DIR=/var/lib/tailscale", "-e", "TS_AUTH_ONCE=true",
		"-e", "TS_ACCEPT_DNS=false", "-e", "TS_SOCKET=/var/run/tailscale/tailscaled.sock", "-e", "TS_HOSTNAME="+a.Hostname,
		a.Image)
	timeout := "timeout -s TERM " + strconv.Itoa(seconds) + " containerboot"
	if a.Key {
		args = append(args, "sh", "-c", "IFS= read -r TS_AUTHKEY && export TS_AUTHKEY && exec "+timeout)
	} else {
		args = append(args, strings.Fields(timeout)...)
	}
	res, err := e.docker.Run(ctx, Call{Args: args, Deadline: StartDeadline})
	if err != nil {
		return "", fmt.Sprintf("docker run of the join container failed (%v): %s", err, lastLine(res.Stderr))
	}
	return name, ""
}

// joinGone reports whether the attempt's container no longer runs.
func (e *Engine) joinGone(ctx context.Context, a *joinAttempt) (bool, error) {
	js, err := e.observeJoins(ctx)
	if err != nil {
		return false, err
	}
	for _, c := range js {
		if c.JoinID == a.JoinID && running(c.State) {
			return false, nil
		}
	}
	return true, nil
}

// joined freezes the machine the join's container reports, stops the
// container, and answers: joined, HTTPS off, or a machine this home
// cannot take.
func (e *Engine) joined(ctx context.Context, j *journal, s tsStatus) (Receipt, error) {
	a := j.Join
	a.Name, a.NodeID = s.name(), s.id()
	https := s.https()
	a.HTTPS = &https
	var ref *Refusal
	switch {
	case !NodeID(a.NodeID):
		a.State, ref = "unsupported", Refuse("tailnet_node_id_unsupported", map[string]string{"value": a.NodeID})
	case !TailnetName(a.Name):
		a.State, ref = "unsupported", invalid(a.Name, "tailnet_name", tailnetNameRule)
	case !https:
		a.State, ref = "https_off", Refuse("tailnet_https_off", map[string]string{"name": a.Name})
	default:
		a.State = "joined"
	}
	if err := e.writeJoin(a.joinRecord); err != nil {
		return e.outcomeUnknown(j, err)
	}
	if err := e.setPhase(j, "frozen"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.endJoin(ctx, j, ref)
}

// endJoin removes the attempt's container and writes its receipt.
func (e *Engine) endJoin(ctx context.Context, j *journal, ref *Refusal) (Receipt, error) {
	a := j.Join
	if why := e.removeJoinContainers(ctx, a.JoinID); why != "" {
		return e.outcomeUnknown(j, errors.New(why))
	}
	r := Receipt{RequestID: a.RequestID, RequestDigest: a.RequestDigest, Op: "join", State: "completed", Outcome: "ok", Payload: map[string]string{}}
	switch {
	case ref != nil:
		r.Code, r.Payload = ref.Code, maps.Clone(ref.Payload)
		if a.State != "https_off" {
			r.Outcome = "failed"
		}
	case a.State == "joined":
		r.Payload = map[string]string{"name": a.Name, "node_id": a.NodeID}
	}
	if r.Payload == nil {
		r.Payload = map[string]string{}
	}
	r.Payload["join_id"] = a.JoinID
	if j.Op == "join" {
		return e.finishAnswer(j, r)
	}
	// A cancel's journal: the join's receipt first, then the cancel's.
	r.At = e.now()
	if err := e.writeReceipt(r); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.finishAnswer(j, Receipt{RequestID: j.RequestID, RequestDigest: j.RequestDigest, Op: "cancel", State: "completed", Outcome: "ok"})
}

// removeJoinContainers removes the containers of join joinID ("" for
// every join container of the project).
func (e *Engine) removeJoinContainers(ctx context.Context, joinID string) string {
	js, err := e.observeJoins(ctx)
	if err != nil {
		return err.Error()
	}
	var names []string
	for _, c := range js {
		if joinID == "" || c.JoinID == joinID {
			names = append(names, c.Name)
		}
	}
	if len(names) == 0 {
		return ""
	}
	res, err := e.docker.Run(ctx, Call{Args: append([]string{"rm", "-f"}, names...), Deadline: StopDeadline})
	if err != nil && !onlyGone(res.Stderr) {
		return fmt.Sprintf("docker rm failed (%v): %s", err, lastLine(res.Stderr))
	}
	return ""
}

// endedJoin ends an attempt whose container ended, or is gone, before
// its deadline without joining: a key Tailscale refused, or the container
// removed.
func (e *Engine) endedJoin(ctx context.Context, j *journal) (Receipt, error) {
	j.Join.State = "ended"
	if err := e.writeJoin(j.Join.joinRecord); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.endJoin(ctx, j, Refuse("tailnet_join_ended", nil))
}

func (e *Engine) expireJoin(ctx context.Context, j *journal) (Receipt, error) {
	j.Join.State = "expired"
	if err := e.writeJoin(j.Join.joinRecord); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.endJoin(ctx, j, Refuse("tailnet_join_expired", nil))
}

// cancelJoin ends the join j holds as cancelled. cancel is the cancel
// request that asked for it, nil when the join's own owner did.
func (e *Engine) cancelJoin(ctx context.Context, j *journal, cancel *CancelRequest) (Receipt, error) {
	if cancel != nil {
		j.Op, j.RequestID, j.RequestDigest = "cancel", cancel.ID, cancelDigest(cancel.JoinID)
		if err := e.setPhase(j, "accepted"); err != nil {
			return e.outcomeUnknown(j, err)
		}
	}
	j.Join.State = "cancelled"
	if err := e.writeJoin(j.Join.joinRecord); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.endJoin(ctx, j, Refuse("tailnet_join_cancelled", nil))
}

func cancelDigest(joinID string) string {
	return requestDigest(map[string]any{"op": "cancel", "join_id": joinID})
}

func (e *Engine) doCancelJoin(ctx context.Context, r CancelRequest) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	digest := cancelDigest(r.JoinID)
	if rc, ok, err := e.lookup(r.ID, digest); err != nil || ok {
		if err != nil {
			return Receipt{}, err
		}
		return answer(rc)
	}
	j, err := e.readJournal()
	if err != nil {
		return Receipt{}, err
	}
	if j == nil || j.Op != "join" || j.Join == nil || j.Join.JoinID != r.JoinID || j.Join.State != "waiting" {
		if j != nil && j.Phase == "uncertain" {
			return answer(j.receipt())
		}
		return e.reject(r.ID, digest, "cancel", Refuse("tailnet_join_not_current", nil))
	}
	return e.cancelJoin(context.WithoutCancel(ctx), j, &r)
}

func (e *Engine) cancelWaitingJoin(ctx context.Context) error {
	if err := e.requireLock(); err != nil {
		return err
	}
	j, err := e.readJournal()
	if err != nil || j == nil || j.Op != "join" || j.Join == nil || j.Join.State != "waiting" {
		return err
	}
	_, err = e.cancelJoin(context.WithoutCancel(ctx), j, &CancelRequest{ID: newRequestID(), JoinID: j.Join.JoinID})
	var ref *Refusal
	if errors.As(err, &ref) && ref.Code == "tailnet_join_cancelled" {
		return nil
	}
	return err
}

func (e *Engine) forgetJoin() error {
	if err := e.requireLock(); err != nil {
		return err
	}
	return e.removeDurable(e.path(joinFile))
}

// recoverJoin finishes a join whose owner died: one past its deadline is
// removed and expired; one whose container is gone ended; one
// whose machine has joined is frozen and receipted; one still waiting
// stays, its container ending at its own deadline. done is false for
// that last.
func (e *Engine) recoverJoin(ctx context.Context, j *journal) (Receipt, bool, error) {
	a := j.Join
	if j.Op == "cancel" {
		rc, err := e.cancelJoin(ctx, j, nil)
		rc, err = e.cancelAnswer(j, rc, err)
		return rc, true, err
	}
	switch a.State {
	case "joined", "https_off", "unsupported":
		var ref *Refusal
		if a.State != "joined" {
			ref = (&a.joinRecord).refusal()
		}
		rc, err := e.endJoin(ctx, j, ref)
		return rc, true, err
	case "expired":
		rc, err := e.expireJoin(ctx, j)
		return rc, true, err
	case "ended":
		rc, err := e.endedJoin(ctx, j)
		return rc, true, err
	case "cancelled":
		rc, err := e.cancelJoin(ctx, j, nil)
		return rc, true, err
	}
	js, err := e.observeJoins(ctx)
	if err != nil {
		return Receipt{}, false, err
	}
	live := ""
	for _, c := range js {
		if c.JoinID == a.JoinID && running(c.State) {
			live = c.Name
		}
	}
	switch {
	case !e.now().Before(a.Deadline):
		rc, err := e.expireJoin(ctx, j)
		return rc, true, err
	case live == "":
		rc, err := e.endedJoin(ctx, j)
		return rc, true, err
	}
	if s, ok := e.statusOnce(ctx, []string{"exec", live, "tailscale", "status", "--json"}); ok && s.BackendState == "Running" {
		rc, err := e.joined(ctx, j, s)
		return rc, true, err
	}
	return Receipt{}, false, nil
}

// cancelAnswer is a finished cancel's receipt, which the cancel's own
// journal writes last.
func (e *Engine) cancelAnswer(j *journal, rc Receipt, err error) (Receipt, error) {
	if r, ok, _ := e.readReceipt(j.RequestID); ok {
		return r, nil
	}
	return rc, err
}

// reapJoins removes every join container no waiting attempt owns: one
// past its deadline, or one a journal no longer names.
func (e *Engine) reapJoins(ctx context.Context, j *journal) error {
	js, err := e.observeJoins(ctx)
	if err != nil {
		return err
	}
	var names []string
	for _, c := range js {
		owned := j != nil && j.Join != nil && j.Join.JoinID == c.JoinID && j.Join.State == "waiting"
		if !owned || !e.now().Before(c.expiry()) {
			names = append(names, c.Name)
		}
	}
	if len(names) == 0 {
		return nil
	}
	res, err := e.docker.Run(ctx, Call{Args: append([]string{"rm", "-f"}, names...), Deadline: StopDeadline})
	if err != nil && !onlyGone(res.Stderr) {
		return fmt.Errorf("docker rm failed (%v): %s", err, lastLine(res.Stderr))
	}
	return nil
}
