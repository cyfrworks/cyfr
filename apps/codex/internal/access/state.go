// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// The engine's state under the project directory. Every file is written
// durably (writeDurable), so a crash leaves each one whole, old or new.
const (
	stateDir      = ".cyfr"
	lockFile      = "lock"
	holderFile    = "holder"
	journalFile   = "journal.json"
	receiptsDir   = "receipts"
	joinFile      = "join.json"
	serveDir      = "tailscale-serve"
	serveFile     = "serve.json"
	resolvedGlob  = "compose.resolved.*.yml"
	resolvedFront = "compose.resolved."
)

// Receipts are kept at least this long and at least this many: a lost
// reply resent within either bound is answered from its receipt.
const (
	receiptAge   = 24 * time.Hour
	receiptCount = 256
)

// requestID is the grammar of a request id: 32 lowercase hexadecimal
// characters, minted per invocation.
var requestID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func (e *Engine) path(parts ...string) string {
	return filepath.Join(append([]string{e.dir, stateDir}, parts...)...)
}

// resolvedName is head digest's materialized configuration, relative to
// the project directory, as every compose command's -f names it.
func resolvedName(digest string) string {
	return filepath.ToSlash(filepath.Join(stateDir, resolvedFront+strings.TrimPrefix(digest, "sha256:")+".yml"))
}

// ensureState creates .cyfr/ and the directories under it, private to
// the owner, since the materialized files hold .env's values; the Serve
// directory alone is readable, by the tailscale container that mounts
// it.
func (e *Engine) ensureState() error {
	for _, dir := range []string{e.path(), e.path(receiptsDir)} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("access: create %s: %w", dir, err)
		}
	}
	// Its mode is set, not left to the umask: the tailscale container's
	// root holds no capability, so it enters only a directory its mode
	// opens to it.
	if err := os.MkdirAll(e.path(serveDir), serveDirMode); err != nil {
		return fmt.Errorf("access: create %s: %w", e.path(serveDir), err)
	}
	if err := os.Chmod(e.path(serveDir), serveDirMode); err != nil {
		return fmt.Errorf("access: create %s: %w", e.path(serveDir), err)
	}
	return nil
}

// writeDurable replaces the file at name with data: a complete temporary
// file synced and renamed over it, then the directory synced, so the
// rename survives a crash. A failure before the rename leaves the old
// file; one after it leaves the new file, perhaps not yet durable.
func (e *Engine) writeDurable(name string, data []byte, mode os.FileMode) error {
	return writeDurable(name, data, mode, e.failWrite)
}

// writeDurable is the durable write, fail the test seam for a failure at
// one of its steps (nil for none).
func writeDurable(name string, data []byte, mode os.FileMode, fail func(name, step string) error) error {
	inject := func(step string) error {
		if fail == nil {
			return nil
		}
		return fail(name, step)
	}
	if err := inject("write"); err != nil {
		return err
	}
	dir := filepath.Dir(name)
	tmp, err := os.CreateTemp(dir, tempPattern(name))
	if err != nil {
		return fmt.Errorf("access: write %s: %w", name, err)
	}
	_, werr := tmp.Write(data)
	err = errors.Join(werr, tmp.Chmod(mode), tmp.Sync(), tmp.Close())
	if err == nil {
		err = inject("rename")
	}
	if err == nil {
		err = replaceFile(tmp.Name(), name)
	}
	if err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("access: write %s: %w", name, err)
	}
	if err := inject("sync"); err != nil {
		return err
	}
	if err := syncDir(dir); err != nil {
		return fmt.Errorf("access: write %s: %w", name, err)
	}
	return nil
}

// tempPattern is the name writeDurable gives the temporary file it
// writes name through, as os.CreateTemp and filepath.Match read it: what
// a write cut short leaves, and the sweep removes.
func tempPattern(name string) string { return "." + filepath.Base(name) + ".tmp-*" }

// isTemp reports whether entry is a temporary file writeDurable made for
// a file named like base ("*" for any).
func isTemp(base, entry string) bool {
	ok, _ := filepath.Match(tempPattern(base), entry)
	return ok
}

// removeDurable removes the file at name, if it exists, and syncs its
// directory.
func (e *Engine) removeDurable(name string) error {
	if err := e.inject(name, "remove"); err != nil {
		return err
	}
	if err := os.Remove(name); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("access: remove %s: %w", name, err)
	}
	if err := syncDir(filepath.Dir(name)); err != nil {
		return fmt.Errorf("access: remove %s: %w", name, err)
	}
	return nil
}

// inject is the test seam for a write's failure at one of its steps.
func (e *Engine) inject(name, step string) error {
	if e.failWrite == nil {
		return nil
	}
	return e.failWrite(name, step)
}

// writeJSON writes v durably as indented JSON, private to the owner.
func (e *Engine) writeJSON(name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return e.writeDurable(name, append(data, '\n'), 0o600)
}

// readJSON reads the JSON file at name into v, reporting false when there
// is none.
func readJSON(name string, v any) (bool, error) {
	data, err := os.ReadFile(name)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("access: read %s: %w", name, err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		return false, fmt.Errorf("access: read %s: %w", name, err)
	}
	return true, nil
}

// journal is the operation in flight: from its acceptance until its
// receipt is durable, every phase it reaches is written here first.
type journal struct {
	Op            string    `json:"op"`
	RequestID     string    `json:"request_id"`
	RequestDigest string    `json:"request_digest"`
	ContentDigest string    `json:"content_digest,omitempty"`
	Phase         string    `json:"phase"`
	At            time.Time `json:"at"`

	// A switch: both heads, the access settings .env held before (OldKeys) and
	// is written with (NewKeys), "" for a key it does not hold; whether
	// cyfr was running when it was accepted; every service its stop and
	// verify stops; why the new head's start failed, once a rollback
	// began.
	OldHead  *Head             `json:"old_head,omitempty"`
	NewHead  *Head             `json:"new_head,omitempty"`
	OldKeys  map[string]string `json:"old_keys,omitempty"`
	NewKeys  map[string]string `json:"new_keys,omitempty"`
	Running  bool              `json:"running,omitempty"`
	Services []string          `json:"services,omitempty"`
	Reason   string            `json:"reason,omitempty"`
	// Reopen is a switch to the head .env already holds, a tailnet home
	// whose Serve is closed: it runs the start path alone.
	Reopen bool `json:"reopen,omitempty"`
	// Why a stop and verify was uncertain.
	Why string `json:"why,omitempty"`

	// The materialized configurations the operation holds, relative to
	// the project directory, and what its last stop and verify saw
	// running.
	Files    []string `json:"files,omitempty"`
	Observed []string `json:"observed,omitempty"`

	// A join's attempt; a cancel's journal carries the join it cancels.
	Join *joinAttempt `json:"join,omitempty"`
}

func (e *Engine) readJournal() (*journal, error) {
	var j journal
	ok, err := readJSON(e.path(journalFile), &j)
	if err != nil || !ok {
		return nil, err
	}
	return &j, nil
}

// setPhase writes j in phase durably, then runs the test seam named for
// the phase.
func (e *Engine) setPhase(j *journal, phase string) error {
	j.Phase = phase
	if err := e.saveJournal(j); err != nil {
		return err
	}
	e.reached("journal:" + j.Op + ":" + phase)
	return nil
}

// saveJournal writes j durably, its free text redacted (redactor): a
// resumed operation answers what it reads back.
func (e *Engine) saveJournal(j *journal) error {
	j.At = e.now()
	r := e.redactor()
	saved := *j
	saved.Reason, saved.Why, saved.Observed = r.text(j.Reason), r.text(j.Why), r.texts(j.Observed)
	return e.writeJSON(e.path(journalFile), &saved)
}

// reached is the test seam at a named point of an operation.
func (e *Engine) reached(point string) {
	if e.hook != nil {
		e.hook(point)
	}
}

// receiptOf is the answer journal j gives while it is unfinished.
func (j *journal) receipt() Receipt {
	r := Receipt{RequestID: j.RequestID, RequestDigest: j.RequestDigest, ContentDigest: j.ContentDigest, Op: j.Op, State: "accepted", Phase: j.Phase, At: j.At}
	if j.Phase == "uncertain" {
		r.Code = "access_uncertain"
		r.Payload = map[string]string{"observed": observedText(j.Observed)}
		r.Observed = slices.Clone(j.Observed)
	}
	return r
}

// observedText is the list of what was still running, as access_uncertain
// names it.
func observedText(observed []string) string {
	if len(observed) == 0 {
		return "containers docker could not report"
	}
	return strings.Join(observed, ", ")
}

func (e *Engine) receiptPath(id string) string { return e.path(receiptsDir, id+".json") }

// readReceipt reads request id's receipt.
func (e *Engine) readReceipt(id string) (Receipt, bool, error) {
	var r Receipt
	ok, err := readJSON(e.receiptPath(id), &r)
	return r, ok, err
}

// finish makes an operation terminal: its receipt durable first, then
// its materialized files and its journal removed and the directory
// synced, so a crash between the two leaves recovery only the journal to
// remove.
func (e *Engine) finish(j *journal, r Receipt) (Receipt, error) {
	r.At = e.now()
	if err := e.writeReceipt(r); err != nil {
		return r, err
	}
	e.reached("receipt:" + r.Op)
	var files []string
	if j != nil {
		files = j.Files
	}
	if err := e.dropFiles(files, true); err != nil {
		return r, err
	}
	if j != nil {
		if err := e.removeDurable(e.path(journalFile)); err != nil {
			return r, err
		}
	}
	e.prune()
	return r, nil
}

// writeReceipt writes r durably, its free text redacted (redactor), so a
// resend answers it redacted too.
func (e *Engine) writeReceipt(r Receipt) error {
	return e.writeJSON(e.receiptPath(r.RequestID), e.redactor().receipt(r))
}

// prune removes every receipt both older than receiptAge and outside the
// newest receiptCount. It runs under the lock; a failure leaves the
// receipt, which costs nothing but space.
func (e *Engine) prune() {
	entries, err := os.ReadDir(e.path(receiptsDir))
	if err != nil {
		return
	}
	type aged struct {
		name string
		at   time.Time
	}
	var all []aged
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		var r Receipt
		if ok, err := readJSON(e.path(receiptsDir, entry.Name()), &r); err == nil && ok {
			all = append(all, aged{entry.Name(), r.At})
		}
	}
	slices.SortFunc(all, func(a, b aged) int { return b.at.Compare(a.at) })
	cutoff := e.now().Add(-receiptAge)
	removed := false
	for i, r := range all {
		if i >= receiptCount && r.at.Before(cutoff) {
			os.Remove(e.path(receiptsDir, r.name))
			removed = true
		}
	}
	if removed {
		syncDir(e.path(receiptsDir))
	}
}

// latestReceipt is the newest receipt, for status.
func (e *Engine) latestReceipt() (*Receipt, error) {
	entries, err := os.ReadDir(e.path(receiptsDir))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var latest *Receipt
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		var r Receipt
		if ok, err := readJSON(e.path(receiptsDir, entry.Name()), &r); err == nil && ok && (latest == nil || r.At.After(latest.At)) {
			latest = &r
		}
	}
	return latest, nil
}

// sweepStrays removes what a killed operation can leave that no journal
// names: the temporary files of an interrupted write, and every
// materialized configuration but the journal's.
func (e *Engine) sweepStrays(j *journal) {
	keep := map[string]bool{}
	if j != nil {
		for _, f := range j.Files {
			keep[filepath.Base(f)] = true
		}
	}
	// In .cyfr/ every file is the engine's; beside .env (the project
	// directory, or where a link to it leads) only .env's own.
	dirs := map[string]string{e.path(): "*", e.path(receiptsDir): "*", e.path(serveDir): "*", e.dir: ".env"}
	if target, err := filepath.EvalSymlinks(e.envPath()); err == nil {
		dirs[filepath.Dir(target)] = filepath.Base(target)
	}
	for dir, base := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			stray := isTemp(base, name)
			if dir == e.path() && strings.HasPrefix(name, resolvedFront) && strings.HasSuffix(name, ".yml") && !keep[name] {
				stray = true
			}
			if stray {
				os.Remove(filepath.Join(dir, name))
			}
		}
		syncDir(dir)
	}
}

// newRequestID mints a request id for an engine-made operation.
func newRequestID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// requestDigest is sha256: and the hex of a request's canonical JSON:
// its fields in byte order, absent ones omitted.
func requestDigest(fields map[string]any) string {
	return "sha256:" + sha256Hex(canonicalJSON(fields))
}

// canonicalJSON writes a flat object of strings and booleans in RFC 8785
// form: keys in byte order (these are ASCII), empty strings omitted.
func canonicalJSON(fields map[string]any) []byte {
	keys := make([]string, 0, len(fields))
	for k, v := range fields {
		if s, ok := v.(string); ok && s == "" {
			continue
		}
		keys = append(keys, k)
	}
	slices.Sort(keys)
	var b strings.Builder
	b.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		writeString(&b, k)
		b.WriteByte(':')
		switch v := fields[k].(type) {
		case string:
			writeString(&b, v)
		case bool:
			if v {
				b.WriteString("true")
			} else {
				b.WriteString("false")
			}
		default:
			panic(fmt.Sprintf("access: request field %s has type %T", k, v))
		}
	}
	b.WriteByte('}')
	return []byte(b.String())
}

// lookup answers a request id already seen: its unfinished journal's
// phase, its receipt when the digest is the same, access_request_reused
// when it is not. ok is false for an id never accepted.
func (e *Engine) lookup(id, digest string) (Receipt, bool, error) {
	if !requestID.MatchString(id) {
		return Receipt{}, false, fmt.Errorf("access: the request id %q is not 32 lowercase hexadecimal characters", id)
	}
	j, err := e.readJournal()
	if err != nil {
		return Receipt{}, false, err
	}
	if j != nil {
		switch {
		case j.RequestID == id && j.RequestDigest != digest:
			return reused(id, digest, j.Op), true, nil
		case j.RequestID == id:
			return j.receipt(), true, nil
		case j.Op == "cancel" && j.Join != nil && j.Join.RequestID == id && j.Join.RequestDigest != digest:
			return reused(id, digest, "join"), true, nil
		case j.Op == "cancel" && j.Join != nil && j.Join.RequestID == id:
			return Receipt{RequestID: id, RequestDigest: digest, Op: "join", State: "accepted", Phase: "cancelling", At: j.At}, true, nil
		}
	}
	r, ok, err := e.readReceipt(id)
	if err != nil || !ok {
		return Receipt{}, false, err
	}
	if r.RequestDigest != digest {
		return reused(id, digest, r.Op), true, nil
	}
	return r, true, nil
}

func reused(id, digest, op string) Receipt {
	return Receipt{RequestID: id, RequestDigest: digest, Op: op, State: "rejected", Code: "access_request_reused"}
}

// reject answers a refusal made before acceptance with a rejected
// receipt, written so a resend of the same id answers the same: nothing
// changed.
func (e *Engine) reject(id, digest, op string, ref *Refusal) (Receipt, error) {
	return e.rejectContent(id, digest, "", op, ref)
}

// rejectContent is reject for a request bound to its content.
func (e *Engine) rejectContent(id, digest, content, op string, ref *Refusal) (Receipt, error) {
	r := Receipt{RequestID: id, RequestDigest: digest, ContentDigest: content, Op: op, State: "rejected", Code: ref.Code, Payload: ref.Payload, At: e.now()}
	if err := e.writeReceipt(r); err != nil {
		return r, err
	}
	e.prune()
	return r, ref
}

// answer is a receipt as a method returns it: with its refusal as the
// error when it carries a code, so the CLI's errors.As finds it.
func answer(r Receipt) (Receipt, error) {
	if ref := r.Refusal(); ref != nil {
		return r, ref
	}
	return r, nil
}

// equalBytes reports whether the file at name holds exactly data.
func equalBytes(name string, data []byte) bool {
	got, err := os.ReadFile(name)
	return err == nil && bytes.Equal(got, data)
}

// sleep waits d on the engine's clock, or until ctx ends.
func (e *Engine) sleep(ctx context.Context, d time.Duration) error {
	if e.clock != nil {
		return e.clock.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (e *Engine) now() time.Time {
	if e.clock != nil {
		return e.clock.Now()
	}
	return time.Now().UTC()
}

// clock is the engine's time, which tests advance without waiting.
type clock interface {
	Now() time.Time
	Sleep(ctx context.Context, d time.Duration) error
}
