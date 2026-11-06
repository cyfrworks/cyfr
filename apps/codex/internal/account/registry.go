// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"slices"
)

// The registry request (Prima.RegistryRequest) and the handle answer
// (Prima.HandleAnswer).
const (
	RegistryProtocol = "cyfr-registry-request/v2"
	handleProtocol   = "cyfr-handle/v1"
	maxRequestBytes  = 16384
	requestLifetime  = 120000
)

var (
	handleShape = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	envelope    = []string{"protocol", "registry", "operation", "identifier", "signer", "nonce", "expires_at", "body"}
	// Each operation's body keys.
	bodies = map[string][]string{
		"handle.claim":     {"handle"},
		"tokens.mint":      {"label"},
		"policy.accept":    {"policy_version"},
		"appeal.file":      {"action_type", "action_ref", "argument"},
		"publisher.claim":  {"slug"},
		"publisher.verify": {"slug", "label"},
	}
	// The route the registry takes each operation the command line sends
	// itself at.
	routes = map[string]string{
		"handle.claim":  "/v1/namespaces/personal/claim",
		"policy.accept": "/v1/legal/accept",
	}
	// Every refusal: CYFR's name by the code the registry writes.
	registryCodes = map[string]string{
		"REQUEST_MALFORMED": "request_malformed", "WRONG_PROTOCOL": "wrong_protocol",
		"WRONG_REGISTRY": "wrong_registry", "UNKNOWN_OPERATION": "unknown_operation",
		"REQUEST_EXPIRED": "expired", "EXPIRY_TOO_FAR": "expiry_too_far",
		"UNKNOWN_IDENTITY": "unknown_identity", "DIRECTORY_UNAVAILABLE": "directory_unavailable",
		"WRONG_DIRECTORY": "wrong_directory", "BAD_SIGNATURE": "bad_signature", "REPLAYED": "replayed",
		"IDENTITY_BANNED": "banned", "NOT_APPELLANT_OF_RECORD": "not_appellant",
		"ACTION_NOT_FOUND": "action_not_found", "APPEAL_TOO_EARLY": "appeal_too_early",
		"NAMESPACE_UNOWNED": "namespace_unowned", "SLUG_TAKEN": "handle_taken",
		"ALREADY_CLAIMED": "has_other_handle", "INVALID_USERNAME": "handle_invalid",
		"RESERVED": "handle_reserved", "NAMESPACE_RESERVED": "namespace_reserved",
		"CLAIM_NOT_PENDING": "claim_not_pending", "DNS_UNVERIFIED": "dns_unverified",
		"DNS_TIMEOUT": "dns_timeout", "POLICY_ACCEPTANCE_REQUIRED": "policy_required",
		"RATE_LIMITED": "rate_limited", "HANDLE_NOT_FOUND": "handle_not_found",
	}
)

// IsHandle is whether name is a name a person can claim: 1 to 39 of a-z,
// 0-9 and single inner hyphens.
func IsHandle(name string) bool { return len(name) <= 39 && handleShape.MatchString(name) }

// ComposeRegistryRequest is an unsigned request of operation for
// identifier, signed by signer, with a fresh nonce, expiring
// requestLifetime after now (Unix milliseconds).
func ComposeRegistryRequest(registry, operation, identifier, signer string, now int64, body map[string]any) map[string]any {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return map[string]any{"protocol": RegistryProtocol, "registry": registry, "operation": operation,
		"identifier": identifier, "signer": signer, "nonce": B64(nonce), "expires_at": now + requestLifetime, "body": body}
}

// SignRegistryRequest signs request with an Ed25519 key, a device's or a
// recovery key's, and answers the bytes sent: its JCS form with sig. A
// request whose bytes would pass the registry's bound is refused here as
// the registry would refuse it (request_malformed).
func SignRegistryRequest(request map[string]any, key ed25519.PrivateKey) ([]byte, error) {
	signed, err := Sign(normal(request), key)
	if err != nil {
		return nil, refused("request_malformed")
	}
	raw, err := JCS(signed)
	if err != nil || len(raw) > maxRequestBytes {
		return nil, refused("request_malformed")
	}
	return raw, nil
}

// ReadToSign reads the registry request a CYFR hands a signer: every
// envelope field but signer and sig, its protocol, a known operation and
// exactly that operation's body keys.
func ReadToSign(v any) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, refused("request_malformed")
	}
	m = normal(m)
	if fields(m, slices.DeleteFunc(slices.Clone(envelope), func(f string) bool { return f == "signer" }), nil) != nil {
		return nil, refused("request_malformed")
	}
	if _, err := JCS(m); err != nil {
		return nil, refused("request_malformed")
	}
	reg, _ := m["registry"].(string)
	_, isString := m["protocol"].(string)
	_, okOp := m["operation"].(string)
	_, nonce := UnB64(m["nonce"], 16, 16)
	_, exp := ms(m["expires_at"])
	body, isBody := m["body"].(map[string]any)
	if !isString || !isHost(reg) || !okOp || !IsIdentifier(m["identifier"]) || !nonce || !exp || !isBody {
		return nil, refused("request_malformed")
	}
	if m["protocol"] != RegistryProtocol {
		return nil, refused("wrong_protocol")
	}
	keys, known := bodies[m["operation"].(string)]
	if !known {
		return nil, refused("unknown_operation")
	}
	if fields(body, keys, nil) != nil {
		return nil, refused("request_malformed")
	}
	for _, k := range keys {
		if _, ok := body[k].(string); !ok {
			return nil, refused("request_malformed")
		}
	}
	return m, nil
}

// RegistryRefusal reads an error envelope's refusal: its first error's
// code in the table with a string message, the envelope holding no null;
// anything else is malformed_answer.
func RegistryRefusal(raw []byte) string {
	v, err := Decode(raw)
	env, ok := v.(map[string]any)
	if err != nil || !ok {
		return "malformed_answer"
	}
	list, _ := env["errors"].([]any)
	if len(list) == 0 {
		return "malformed_answer"
	}
	first, _ := list[0].(map[string]any)
	code, _ := first["code"].(string)
	_, message := first["message"].(string)
	name, known := registryCodes[code]
	if !known || !message {
		return "malformed_answer"
	}
	if _, err := JCS(env); err != nil {
		return "malformed_answer"
	}
	return name
}

// HandleAnswer is who holds a name: the registry asked, the name, the
// account's identifier and the directory its log lives at.
type HandleAnswer struct {
	Registry, Handle, Identifier, Directory string
}

// ReadHandle reads the registry's answer for handle asked of registry
// (its host): the answer, or the envelope's refusal, or malformed_answer.
func ReadHandle(raw []byte, handle, registry string) (HandleAnswer, error) {
	v, err := Decode(raw)
	m, ok := v.(map[string]any)
	if err != nil || !ok {
		return HandleAnswer{}, refused("malformed_answer")
	}
	if _, isEnvelope := m["errors"]; isEnvelope {
		return HandleAnswer{}, refused(RegistryRefusal(raw))
	}
	if fields(m, []string{"protocol", "registry", "handle", "identifier", "directory"}, nil) != nil ||
		m["protocol"] != handleProtocol || m["registry"] != registry || m["handle"] != handle ||
		!isHost(registry) || !IsHandle(handle) || !IsIdentifier(m["identifier"]) || !IsDirectoryURL(m["directory"]) {
		return HandleAnswer{}, refused("malformed_answer")
	}
	return HandleAnswer{Registry: registry, Handle: handle, Identifier: m["identifier"].(string),
		Directory: m["directory"].(string)}, nil
}

// Registry is a registry's HTTP: the handle read and the operations the
// command line sends signed itself.
type Registry struct {
	Origin string
	Client *http.Client
}

// Host is the registry's host, the registry a request names.
func (r Registry) Host() string {
	u, err := url.Parse(r.Origin)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// Handle reads who holds name: the answer, a *Refusal (handle_not_found
// for a name no one holds), or ErrUnreachable.
func (r Registry) Handle(ctx context.Context, name string) (HandleAnswer, error) {
	if !IsHandle(name) {
		return HandleAnswer{}, refused("handle_invalid")
	}
	_, body, err := call(ctx, r.Client, http.MethodGet, r.Origin+"/v1/handles/"+url.PathEscape(name), nil)
	if err != nil {
		return HandleAnswer{}, err
	}
	return ReadHandle(body, name, r.Host())
}

// Send sends a signed operation's bytes: nil for its success, its
// refusal, or ErrUnreachable for an answer that never came (it may have
// landed).
func (r Registry) Send(ctx context.Context, operation string, signed []byte) error {
	route, ok := routes[operation]
	if !ok {
		return errors.New("the command line does not send " + operation + " itself")
	}
	status, body, err := call(ctx, r.Client, http.MethodPost, r.Origin+route, signed)
	if err != nil {
		return err
	}
	if status < 200 || status > 299 {
		return refused(RegistryRefusal(body))
	}
	return nil
}
