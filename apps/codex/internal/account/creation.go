// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
)

// Attempt is an account being made from a device, as it is kept until it
// is done: the genesis and the device's add_key, both signed by the
// recovery key, the name and the policy version accepted, and the step
// reached. It holds nothing secret; the recovery key lives in memory
// alone, and a run that finds an attempt asks for the recovery code again.
type Attempt struct {
	Identifier string         `json:"identifier"`
	Name       string         `json:"name"`
	Directory  string         `json:"directory"`
	Registry   string         `json:"registry"`
	Accepted   string         `json:"accepted,omitempty"`
	AcceptDone bool           `json:"accept_done,omitempty"`
	Genesis    map[string]any `json:"genesis"`
	AddKey     map[string]any `json:"add_key"`
	Step       string         `json:"step"`
}

// The steps an attempt is submitted in.
const (
	StepRegister = "register"
	StepAppend   = "append"
	StepName     = "name"
	StepDone     = "done"
)

// The refusals of making an account that ask the person for something.
var (
	// ErrNameTaken is a name someone else holds: another is asked.
	ErrNameTaken = errors.New("name_taken")
	// ErrNameReserved is a name the registry keeps from every account,
	// whose lookup answers not found as a free name's does: another is
	// asked.
	ErrNameReserved = errors.New("name_reserved")
	// ErrPolicyChanged is a registry that asks for a newer policy than the
	// one accepted: it is asked of the person again.
	ErrPolicyChanged = errors.New("policy_changed")
)

// CheckName is whether name can be claimed at r: nil, ErrNameTaken, the
// registry's refusal, or ErrUnreachable.
func CheckName(ctx context.Context, r Registry, name string) error {
	if !IsHandle(name) {
		return refused("handle_invalid")
	}
	_, err := r.Handle(ctx, name)
	var ref *Refusal
	switch {
	case err == nil:
		return ErrNameTaken
	case errors.As(err, &ref) && ref.Reason == "handle_not_found":
		return nil
	}
	return err
}

// Begin draws a recovery secret and composes the account at c's directory
// with the device key pub its first key: the genesis and the add_key,
// both signed by the recovery key. It answers the attempt, the secret
// (whose code the person saves before anything is sent) and the recovery
// key.
func Begin(c Config, name, accepted string, pub []byte, now int64) (Attempt, []byte, ed25519.PrivateKey, error) {
	secret := NewRecoverySecret()
	key := RecoveryKey(secret)
	rpub := key.Public().(ed25519.PublicKey)
	genesis, err := Sign(Genesis(c.Directory, [][]byte{rpub}, now, RecoverySigner(rpub)), key)
	if err != nil {
		return Attempt{}, nil, nil, err
	}
	genesis = normal(genesis)
	state, err := Walk([]any{genesis})
	if err != nil {
		return Attempt{}, nil, nil, err
	}
	add, err := Sign(Next(state, "add_key", map[string]any{"key": DeviceKey(pub).Map()}, now, RecoverySigner(rpub)), key)
	if err != nil {
		return Attempt{}, nil, nil, err
	}
	return Attempt{Identifier: state.Identifier, Name: name, Directory: c.Directory, Registry: c.Registry,
		Accepted: accepted, Genesis: genesis, AddKey: normal(add), Step: StepRegister}, secret, key, nil
}

// Submit sends a from the step it reached, saving it after each step:
// register and append, each sent again with the same bytes after a lost
// answer (the directory's exists is success), then the name. The name
// step reads the handle first, so a claim whose answer was lost is
// reconciled: the account's is done, another's is ErrNameTaken, a free
// name is claimed (a reserved one refused ErrNameReserved), after the policy is accepted when a was made under
// one. Each registry request is signed afresh by key, since a nonce is
// spent once. ErrUnreachable leaves the step to send again.
func Submit(ctx context.Context, a *Attempt, key ed25519.PrivateKey, now func() int64, client *http.Client, save func(Attempt) error) error {
	d := Directory{URL: a.Directory, Client: client}
	r := Registry{Origin: a.Registry, Client: client}
	for a.Step != StepDone {
		var err error
		switch a.Step {
		case StepRegister:
			_, err = d.Register(ctx, a.Genesis)
		case StepAppend:
			_, err = d.Append(ctx, a.Identifier, a.AddKey)
		case StepName:
			err = claim(ctx, r, a, key, now, save)
		}
		if err != nil {
			return err
		}
		a.Step = map[string]string{StepRegister: StepAppend, StepAppend: StepName, StepName: StepDone}[a.Step]
		if err := save(*a); err != nil {
			return err
		}
	}
	return nil
}

func claim(ctx context.Context, r Registry, a *Attempt, key ed25519.PrivateKey, now func() int64, save func(Attempt) error) error {
	found, err := r.Handle(ctx, a.Name)
	var ref *Refusal
	switch {
	case err == nil && found.Identifier == a.Identifier:
		return nil
	case err == nil:
		return ErrNameTaken
	case !errors.As(err, &ref) || ref.Reason != "handle_not_found":
		return err
	}
	signer := RecoverySigner(key.Public().(ed25519.PublicKey))
	if a.Accepted != "" && !a.AcceptDone {
		req := ComposeRegistryRequest(r.Host(), "policy.accept", a.Identifier, signer, now(), map[string]any{"policy_version": a.Accepted})
		if err := send(ctx, r, "policy.accept", req, key); err != nil {
			return err
		}
		a.AcceptDone = true
		if err := save(*a); err != nil {
			return err
		}
	}
	req := ComposeRegistryRequest(r.Host(), "handle.claim", a.Identifier, signer, now(), map[string]any{"handle": a.Name})
	err = send(ctx, r, "handle.claim", req, key)
	switch {
	case errors.As(err, &ref) && ref.Reason == "handle_taken":
		return ErrNameTaken
	case errors.As(err, &ref) && ref.Reason == "handle_reserved":
		return ErrNameReserved
	case errors.As(err, &ref) && ref.Reason == "policy_required":
		return ErrPolicyChanged
	}
	return err
}

func send(ctx context.Context, r Registry, operation string, req map[string]any, key ed25519.PrivateKey) error {
	signed, err := SignRegistryRequest(req, key)
	if err != nil {
		return err
	}
	return r.Send(ctx, operation, signed)
}
