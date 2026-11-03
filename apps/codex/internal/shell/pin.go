// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/holder"
)

// A device without a chip whose home is another machine may keep its key
// under a six-digit PIN its home counts (holder.PINBlob): every open,
// the first after a reboot included, asks the home to evaluate the blinded
// PIN (POST /device/pin/evaluate, by the evaluator's enrollment-bound
// identifier alone: no session, no channel, no proof of the key it
// unwraps), and the home charges the attempt before it answers. Once the
// key opens, it signs the reset challenge that answer carried (purpose
// pin_reset, bound to that evaluation's nonce and the counter's revision)
// and posts it (POST /device/pin/reset), so the count starts again. A
// dropped answer is a charged attempt: nothing here retries it.

var (
	// ErrPINHere is a PIN the home would count where the home is this
	// same machine: its data and this key record share one disk, so the
	// count protects nothing.
	ErrPINHere = errors.New("the home runs on this machine")
	// ErrPINUnknown is a home that evaluates no PIN for this device: its
	// evaluator was removed with the device, or a restore from a backup
	// suspended it until the recovery code brings it back.
	ErrPINUnknown = errors.New("the home evaluates no PIN for this device")
	// ErrPINWrong is a PIN that did not open the key after the home
	// evaluated and counted it.
	ErrPINWrong = errors.New("wrong PIN, counted by the home")
)

// PINWaitError is a home that takes this device's next PIN only at Until,
// after wrong ones: the delay doubles with each charged attempt, up to an
// hour, and never locks the device for good.
type PINWaitError struct {
	Until time.Time
}

func (e *PINWaitError) Error() string {
	return "the home takes the next PIN at " + e.Until.Format(time.RFC3339)
}

// PINEnroll asks the home for a new evaluator for this device's PIN
// (pin.enroll, through the unlocked device's session, under a fresh
// confirmation on this device or another) and answers its identifier. A
// replacement keeps the old evaluator at the home until the new one's
// first successful evaluation and reset.
type PINEnroll func(ctx context.Context) (evaluator string, err error)

// open opens the record's key with secret: the chip or the passphrase
// here, or a PIN its home evaluates, once, followed by the reset the
// opened key signs. A reset the home does not take leaves the key open:
// the attempt stays counted until the next unlock resets it.
func (s *Shell) open(ctx context.Context, secret []byte) (*holder.Key, error) {
	if !s.rec.Hardened() {
		return s.rec.Open(secret)
	}
	if s.cfg.HomeHere {
		return nil, ErrPINHere
	}
	var reset json.RawMessage
	key, err := s.rec.OpenPIN(secret, s.evaluate(ctx, s.rec.PIN.Evaluator, &reset))
	if errors.Is(err, holder.ErrWrongSecret) {
		return nil, ErrPINWrong
	}
	if err != nil {
		return nil, err
	}
	_ = s.resetPIN(ctx, reset, key)
	return key, nil
}

// evaluate is the holder's evaluation by the home, keeping the reset
// challenge the answer carried in reset.
func (s *Shell) evaluate(ctx context.Context, evaluator string, reset *json.RawMessage) holder.Evaluate {
	return func(blinded []byte) ([]byte, error) {
		var got struct {
			Evaluated string          `json:"evaluated"`
			Reset     json.RawMessage `json:"reset"`
		}
		err := post(ctx, s.cfg.Client, s.cfg.Address, "/device/pin/evaluate", nil,
			map[string]any{"evaluator": evaluator, "blinded": b64(blinded)}, &got)
		var home *HomeError
		switch {
		case errors.As(err, &home) && home.Code == "pin_wait" && home.NextAllowedAt > 0:
			return nil, &PINWaitError{Until: time.UnixMilli(home.NextAllowedAt)}
		case errors.As(err, &home) && home.Code == "not_found":
			return nil, ErrPINUnknown
		case err != nil:
			return nil, err
		}
		element, err := unb64(got.Evaluated)
		if err != nil {
			return nil, holder.ErrBadElement
		}
		*reset = got.Reset
		return element, nil
	}
}

// resetPIN checks the reset challenge an evaluation answered against this
// device's binding, signs it with the opened key and posts it.
func (s *Shell) resetPIN(ctx context.Context, raw json.RawMessage, key *holder.Key) error {
	c, err := Challenge(raw, "pin_reset", s.binding(), nil)
	if err != nil {
		return err
	}
	proof, err := Prove(c, key)
	if err != nil {
		return err
	}
	return post(ctx, s.cfg.Client, s.cfg.Address, "/device/pin/reset", nil, map[string]any{"proof": proof}, nil)
}

// SetPIN keeps this unlocked device's key under a six-digit PIN its home
// counts, in place of its passphrase, or under a new PIN and evaluator in
// place of the old: the home names a new evaluator once the change is
// freshly confirmed (Config.EnrollPIN), the new PIN, given twice, is
// evaluated once, and the record is replaced on disk before the reset
// tells the home the new evaluator works. A device that dies before the
// record is written keeps the record it had, which still opens: the home
// keeps the old evaluator until the new one's first reset.
func (s *Shell) SetPIN(ctx context.Context, pin, again []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(pin, again)
	switch {
	case s.key == nil || s.ch == nil:
		return
	case s.cfg.HomeHere:
		s.say("%s", s.sentence(ErrPINHere))
		return
	case s.rec.Kind != holder.KindSoftware:
		s.say("This %s's chip keeps its PIN already.", s.cfg.Noun)
		return
	case s.cfg.EnrollPIN == nil:
		s.say("This %s cannot keep its key under a PIN CYFR counts.", s.cfg.Noun)
		return
	case !bytes.Equal(pin, again):
		s.say("The two entries differ. Enter the same one twice.")
		return
	}
	if err := holder.CheckPIN(pin); err != nil {
		s.say("A PIN is six digits.")
		return
	}
	evaluator, err := s.cfg.EnrollPIN(ctx)
	if err != nil {
		s.say("CYFR did not set up the PIN: %s. Nothing changed on this %s.", strings.TrimSuffix(s.sentence(err), "."), s.cfg.Noun)
		return
	}
	var reset json.RawMessage
	hard, err := s.rec.HardenPIN(s.key, evaluator, pin, s.evaluate(ctx, evaluator, &reset))
	if err != nil {
		s.say("CYFR did not set up the PIN: %s. Nothing changed on this %s.", strings.TrimSuffix(s.sentence(err), "."), s.cfg.Noun)
		return
	}
	if err := hard.Save(s.cfg.Record); err != nil {
		s.say("This %s could not save its key under the new PIN (%v): it still opens as before.", s.cfg.Noun, err)
		return
	}
	s.rec = hard
	_ = s.resetPIN(ctx, reset, s.key)
	s.say("This %s's key is now kept under your six-digit PIN. CYFR counts every try, so a copy of this %s's disk cannot guess it.", s.cfg.Noun, s.cfg.Noun)
}

// pinSentence is what the person reads for a failure of a PIN the home
// evaluates, or "" for any other failure.
func pinSentence(err error, noun string) string {
	var wait *PINWaitError
	switch {
	case errors.As(err, &wait):
		return fmt.Sprintf("Too many wrong PINs: CYFR takes this %s's next try at %s.", noun, wait.Until.Local().Format("15:04:05"))
	case errors.Is(err, ErrPINWrong):
		return "That is not this " + noun + "'s PIN. CYFR counted the try: each wrong one makes the next wait longer."
	case errors.Is(err, ErrPINUnknown):
		return "CYFR does not take this " + noun + "'s PIN: it was removed, or a restore from a backup suspended it. If it was suspended, your recovery code brings it back."
	case errors.Is(err, ErrPINHere):
		return PINHereSentence(noun)
	case errors.Is(err, holder.ErrBadElement):
		return "CYFR's answer to this " + noun + "'s PIN was not one it can use. Nothing was unlocked."
	}
	return ""
}

// PINHereSentence is why a device of noun keeps no PIN its home counts
// where the home is this same machine.
func PINHereSentence(noun string) string {
	return "CYFR runs on this machine, so a six-digit PIN cannot protect this " + noun + "'s key: CYFR's data and the key would share one disk. A self-contained box keeps its key under its chip's PIN or a passphrase."
}
