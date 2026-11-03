// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package holder

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io/fs"
	"os"

	"github.com/google/go-tpm/tpm2"
	"github.com/google/go-tpm/tpm2/transport"
	"github.com/google/go-tpm/tpm2/transport/linuxtpm"
)

// tpmPath is the kernel's resource-managed TPM device. Closing it flushes
// whatever the connection left loaded, beneath the flushes below.
const tpmPath = "/dev/tpmrm0"

// The dictionary-attack policy a six-digit PIN needs: the chip locks after
// eight wrong PINs and restores one try every ten minutes, and after a wrong
// lockout authorization it refuses the next for a day. With the lockout
// authorization set to a value nobody keeps, nothing resets the count early.
const (
	daMaxTries        = 8
	daRecoveryTime    = 600
	daLockoutRecovery = 86400
)

// permanentLockoutAuthSet is TPMA_PERMANENT's lockoutAuthSet bit (TPM 2.0
// Part 2, 8.6): the lockout hierarchy's authorization is not empty.
const permanentLockoutAuthSet = 1 << 2

// openTPM opens the chip. Tests point it at a disposable swtpm.
var openTPM = func() (transport.TPMCloser, error) { return linuxtpm.Open(tpmPath) }

func init() {
	chip = &chipOps{
		present: func() bool { _, err := os.Stat(tpmPath); return err == nil },
		seal:    tpmSeal,
		unseal:  tpmUnseal,
	}
}

// parentTemplate is the TCG reference ECC P-256 storage key template, written
// out here so a go-tpm update cannot change it. The owner hierarchy's seed
// turns it into the same key every time, so the parent needs no persistent
// handle, and it can be neither duplicated nor exported.
var parentTemplate = tpm2.TPMTPublic{
	Type:    tpm2.TPMAlgECC,
	NameAlg: tpm2.TPMAlgSHA256,
	ObjectAttributes: tpm2.TPMAObject{
		FixedTPM:            true,
		FixedParent:         true,
		SensitiveDataOrigin: true,
		UserWithAuth:        true,
		NoDA:                true,
		Restricted:          true,
		Decrypt:             true,
	},
	Parameters: tpm2.NewTPMUPublicParms(tpm2.TPMAlgECC, &tpm2.TPMSECCParms{
		Symmetric: tpm2.TPMTSymDefObject{
			Algorithm: tpm2.TPMAlgAES,
			KeyBits:   tpm2.NewTPMUSymKeyBits(tpm2.TPMAlgAES, tpm2.TPMKeyBits(128)),
			Mode:      tpm2.NewTPMUSymMode(tpm2.TPMAlgAES, tpm2.TPMAlgCFB),
		},
		CurveID: tpm2.TPMECCNistP256,
	}),
	Unique: tpm2.NewTPMUPublicID(tpm2.TPMAlgECC, &tpm2.TPMSECCPoint{
		X: tpm2.TPM2BECCParameter{Buffer: make([]byte, 32)},
		Y: tpm2.TPM2BECCParameter{Buffer: make([]byte, 32)},
	}),
}

// sealedTemplate is the sealed seed's public area. Its attributes are
// fixedTPM and fixedParent, so the object never leaves this chip or its
// parent, and userWithAuth, so the PIN alone authorizes it. sensitiveDataOrigin
// stays clear because the seed comes from the caller, and noDA stays clear so
// every wrong PIN counts toward the chip's lockout. The TPM fills Unique.
func sealedTemplate() tpm2.TPMTPublic {
	return tpm2.TPMTPublic{
		Type:             tpm2.TPMAlgKeyedHash,
		NameAlg:          tpm2.TPMAlgSHA256,
		ObjectAttributes: tpm2.TPMAObject{FixedTPM: true, FixedParent: true, UserWithAuth: true},
		Parameters: tpm2.NewTPMUPublicParms(tpm2.TPMAlgKeyedHash, &tpm2.TPMSKeyedHashParms{
			Scheme: tpm2.TPMTKeyedHashScheme{Scheme: tpm2.TPMAlgNull},
		}),
		Unique: tpm2.NewTPMUPublicID(tpm2.TPMAlgKeyedHash, &tpm2.TPM2BDigest{}),
	}
}

// dial opens the chip: a missing device is no chip, any other failure a chip
// the holder cannot use.
func dial() (transport.TPMCloser, error) {
	t, err := openTPM()
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("%w: %v", ErrNoChip, err)
	}
	if err != nil {
		return nil, &ChipRefusedError{Reason: fmt.Sprintf("the chip could not be opened: %v", err)}
	}
	return t, nil
}

func flush(t transport.TPM, h tpm2.TPMHandle) {
	_, _ = tpm2.FlushContext{FlushHandle: h}.Execute(t)
}

// parent is the loaded storage key the sealed seed lives under.
type parent struct {
	handle tpm2.TPMHandle
	name   tpm2.TPM2BName
	public tpm2.TPMTPublic
}

// createParent re-creates the storage key under the owner hierarchy with its
// empty authorization. The holder never sets, changes or clears the owner's
// authorization; a chip whose owner set one is refused.
func createParent(t transport.TPM) (*parent, error) {
	rsp, err := tpm2.CreatePrimary{PrimaryHandle: tpm2.TPMRHOwner, InPublic: tpm2.New2B(parentTemplate)}.Execute(t)
	if errors.Is(err, tpm2.TPMRCBadAuth) || errors.Is(err, tpm2.TPMRCAuthFail) {
		return nil, &ChipRefusedError{Reason: "the chip's owner hierarchy has a password someone else set, and CYFR never changes it"}
	}
	if err != nil {
		return nil, fmt.Errorf("create the chip's storage key: %w", err)
	}
	pub, err := rsp.OutPublic.Contents()
	if err != nil {
		flush(t, rsp.ObjectHandle)
		return nil, err
	}
	// The name is computed here from the public area the session's salt is
	// encrypted to, never taken from the chip's word for it.
	name, err := tpm2.ObjectName(pub)
	if err != nil || !bytes.Equal(name.Buffer, rsp.Name.Buffer) {
		flush(t, rsp.ObjectHandle)
		return nil, &ChipRefusedError{Reason: "the chip's storage key does not match its own name"}
	}
	return &parent{handle: rsp.ObjectHandle, name: *name, public: *pub}, nil
}

// encryptIn is an HMAC session salted to the parent's key that AES-encrypts a
// command's first parameter, so a secret in it does not cross the bus in
// clear. It rides along as an extra session and authorizes nothing.
func (p *parent) encryptIn() tpm2.Session {
	return tpm2.HMAC(tpm2.TPMAlgSHA256, 16, tpm2.Salted(p.handle, p.public), tpm2.AESEncryption(128, tpm2.EncryptIn))
}

func (p *parent) auth() tpm2.AuthHandle {
	return tpm2.AuthHandle{Handle: p.handle, Name: p.name, Auth: tpm2.PasswordAuth(nil)}
}

// tpmSeal provisions the chip's dictionary-attack policy, seals seed under
// pin, loads the sealed object back and refuses unless the chip reports the
// object and the policy as the holder needs them.
func tpmSeal(seed, pin []byte) (*ChipBlob, error) {
	t, err := dial()
	if err != nil {
		return nil, err
	}
	defer t.Close()
	p, err := createParent(t)
	if err != nil {
		return nil, err
	}
	defer flush(t, p.handle)
	if err := provisionDA(t, p); err != nil {
		return nil, err
	}
	// The command buffer go-tpm marshals holds the seed and PIN until the
	// garbage collector reclaims it; the session encrypts them on the bus.
	created, err := tpm2.Create{
		ParentHandle: p.auth(),
		InSensitive: tpm2.TPM2BSensitiveCreate{Sensitive: &tpm2.TPMSSensitiveCreate{
			UserAuth: tpm2.TPM2BAuth{Buffer: pin},
			Data:     tpm2.NewTPMUSensitiveCreate(&tpm2.TPM2BSensitiveData{Buffer: seed}),
		}},
		InPublic: tpm2.New2B(sealedTemplate()),
	}.Execute(t, p.encryptIn())
	if err != nil {
		return nil, fmt.Errorf("seal the key in the chip: %w", err)
	}
	blob := &ChipBlob{Public: tpm2.Marshal(created.OutPublic), Private: tpm2.Marshal(created.OutPrivate), Parent: p.name.Buffer}
	obj, err := load(t, p, blob)
	if err != nil {
		return nil, err
	}
	defer flush(t, obj.ObjectHandle)
	if err := checkSealed(t, obj.ObjectHandle, blob.Public); err != nil {
		return nil, err
	}
	if err := checkDA(t); err != nil {
		return nil, err
	}
	return blob, nil
}

// tpmUnseal unseals the seed with pin as the object's authorization, through
// an HMAC session salted to the parent: the PIN goes over the bus only as an
// HMAC keyed with a secret the bus never carries, and the seed comes back
// AES-encrypted. The salt is encrypted to the parent the seed was sealed
// under, its name pinned in the blob, so neither an observer of the bus nor a
// device that impersonates the chip on it learns what the PIN's HMAC is
// keyed with. Each call is a fresh authorization the chip counts.
func tpmUnseal(b *ChipBlob, pin []byte) ([]byte, error) {
	t, err := dial()
	if err != nil {
		return nil, err
	}
	defer t.Close()
	p, err := createParent(t)
	if err != nil {
		return nil, err
	}
	defer flush(t, p.handle)
	if !bytes.Equal(p.name.Buffer, b.Parent) {
		return nil, &ChipRefusedError{Reason: "the chip's storage key is not the one this key was sealed under"}
	}
	obj, err := load(t, p, b)
	if err != nil {
		return nil, err
	}
	defer flush(t, obj.ObjectHandle)
	rsp, err := tpm2.Unseal{ItemHandle: tpm2.AuthHandle{
		Handle: obj.ObjectHandle,
		Name:   obj.Name,
		Auth: tpm2.HMAC(tpm2.TPMAlgSHA256, 16, tpm2.Auth(pin),
			tpm2.Salted(p.handle, p.public), tpm2.AESEncryption(128, tpm2.EncryptOut)),
	}}.Execute(t)
	switch {
	case errors.Is(err, tpm2.TPMRCLockout):
		return nil, fmt.Errorf("%w: %v", ErrLockedOut, err)
	case errors.Is(err, tpm2.TPMRCAuthFail), errors.Is(err, tpm2.TPMRCBadAuth):
		return nil, fmt.Errorf("%w: %v", ErrWrongSecret, err)
	case err != nil:
		return nil, fmt.Errorf("unseal the key: %w", err)
	}
	return rsp.OutData.Buffer, nil
}

// load loads a sealed blob under the parent. It fails once the chip was
// cleared, or for a blob another chip sealed.
func load(t transport.TPM, p *parent, b *ChipBlob) (*tpm2.LoadResponse, error) {
	pub, err := tpm2.Unmarshal[tpm2.TPM2BPublic](b.Public)
	if err != nil {
		return nil, fmt.Errorf("the key record's chip blob is unreadable: %w", err)
	}
	priv, err := tpm2.Unmarshal[tpm2.TPM2BPrivate](b.Private)
	if err != nil {
		return nil, fmt.Errorf("the key record's chip blob is unreadable: %w", err)
	}
	rsp, err := tpm2.Load{ParentHandle: p.auth(), InPrivate: *priv, InPublic: *pub}.Execute(t)
	if err != nil {
		return nil, fmt.Errorf("the chip cannot load this key; it was cleared or the record belongs to another chip: %w", err)
	}
	return rsp, nil
}

// checkSealed reads the loaded object's public area back from the chip and
// refuses it unless it is the area TPM2_Create returned and, apart from the
// Unique the TPM computes, exactly sealedTemplate.
func checkSealed(t transport.TPM, h tpm2.TPMHandle, created []byte) error {
	rsp, err := tpm2.ReadPublic{ObjectHandle: h}.Execute(t)
	if err != nil {
		return fmt.Errorf("read the sealed key's public area: %w", err)
	}
	if !bytes.Equal(tpm2.Marshal(rsp.OutPublic), created) {
		return &ChipRefusedError{Reason: "the chip reads back another public area than the one it created"}
	}
	got, err := rsp.OutPublic.Contents()
	if err != nil {
		return fmt.Errorf("read the sealed key's public area: %w", err)
	}
	want := sealedTemplate()
	if !bytes.Equal(tpm2.Marshal(&got.ObjectAttributes), tpm2.Marshal(&want.ObjectAttributes)) {
		return &ChipRefusedError{Reason: fmt.Sprintf("the sealed key's attributes are %x, not %x",
			tpm2.Marshal(&got.ObjectAttributes), tpm2.Marshal(&want.ObjectAttributes))}
	}
	got.Unique = want.Unique
	if !bytes.Equal(tpm2.Marshal(got), tpm2.Marshal(&want)) {
		return &ChipRefusedError{Reason: "the sealed key's public area is not the one CYFR asked for"}
	}
	return nil
}

// provisionDA gives a chip whose lockout authorization is still empty the
// holder's dictionary-attack policy, then sets the lockout authorization to
// random bytes nobody keeps. A chip whose lockout authorization is already
// set is left alone and accepted only if it already has the policy.
func provisionDA(t transport.TPM, p *parent) error {
	perm, err := property(t, tpm2.TPMPTPermanent)
	if err != nil {
		return err
	}
	if perm&permanentLockoutAuthSet != 0 {
		var refused *ChipRefusedError
		if err := checkDA(t); errors.As(err, &refused) {
			return &ChipRefusedError{Reason: "the chip's lockout is set by someone else, and " + refused.Reason}
		} else if err != nil {
			return err
		}
		return nil
	}
	if err := daParameters(t, daMaxTries, daRecoveryTime, daLockoutRecovery); err != nil {
		return fmt.Errorf("set the chip's wrong-PIN limits: %w", err)
	}
	auth := make([]byte, 32)
	defer clear(auth)
	if _, err := rand.Read(auth); err != nil {
		return err
	}
	_, err = tpm2.HierarchyChangeAuth{
		AuthHandle: tpm2.AuthHandle{Handle: tpm2.TPMRHLockout, Auth: tpm2.PasswordAuth(nil)},
		NewAuth:    tpm2.TPM2BAuth{Buffer: auth},
	}.Execute(t, p.encryptIn())
	if err != nil {
		return fmt.Errorf("lock the chip's lockout hierarchy: %w", err)
	}
	return nil
}

// checkDA refuses a chip whose dictionary-attack policy is not the holder's
// or whose lockout authorization is empty, since anyone could then reset the
// wrong-PIN count.
func checkDA(t transport.TPM) error {
	maxTries, err := property(t, tpm2.TPMPTMaxAuthFail)
	if err != nil {
		return err
	}
	interval, err := property(t, tpm2.TPMPTLockoutInterval)
	if err != nil {
		return err
	}
	perm, err := property(t, tpm2.TPMPTPermanent)
	if err != nil {
		return err
	}
	switch {
	case maxTries != daMaxTries:
		return &ChipRefusedError{Reason: fmt.Sprintf("the chip locks after %d wrong PINs, not %d", maxTries, daMaxTries)}
	case interval != daRecoveryTime:
		return &ChipRefusedError{Reason: fmt.Sprintf("the chip restores a try every %d seconds, not %d", interval, daRecoveryTime)}
	case perm&permanentLockoutAuthSet == 0:
		return &ChipRefusedError{Reason: "the chip's lockout has no password, so anyone could reset the wrong-PIN count"}
	}
	return nil
}

// property reads one TPM_PT property. GetCapability answers from the first
// property at or after the one asked for, so the tag is checked.
func property(t transport.TPM, pt tpm2.TPMPT) (uint32, error) {
	rsp, err := tpm2.GetCapability{Capability: tpm2.TPMCapTPMProperties, Property: uint32(pt), PropertyCount: 1}.Execute(t)
	if err != nil {
		return 0, fmt.Errorf("read the chip's property %#x: %w", uint32(pt), err)
	}
	props, err := rsp.CapabilityData.Data.TPMProperties()
	if err != nil {
		return 0, fmt.Errorf("read the chip's property %#x: %w", uint32(pt), err)
	}
	if len(props.TPMProperty) == 0 || props.TPMProperty[0].Property != pt {
		return 0, fmt.Errorf("the chip does not report property %#x", uint32(pt))
	}
	return props.TPMProperty[0].Value, nil
}

// daParameters runs TPM2_DictionaryAttackParameters (TPM 2.0 Part 3, 25.3)
// with the lockout hierarchy's empty password. go-tpm's tpm2 package lacks
// the command, so it is encoded here; none of its fields is secret.
func daParameters(t transport.TPM, maxTries, recoveryTime, lockoutRecovery uint32) error {
	cmd := binary.BigEndian.AppendUint16(nil, uint16(tpm2.TPMSTSessions))
	cmd = binary.BigEndian.AppendUint32(cmd, 0) // commandSize, set below
	cmd = binary.BigEndian.AppendUint32(cmd, uint32(tpm2.TPMCCDictionaryAttackParameters))
	cmd = binary.BigEndian.AppendUint32(cmd, uint32(tpm2.TPMRHLockout))
	cmd = binary.BigEndian.AppendUint32(cmd, 9) // authorizationSize: one password session
	cmd = binary.BigEndian.AppendUint32(cmd, uint32(tpm2.TPMRSPW))
	cmd = binary.BigEndian.AppendUint16(cmd, 0) // nonceCaller
	cmd = append(cmd, 0)                        // sessionAttributes
	cmd = binary.BigEndian.AppendUint16(cmd, 0) // the empty password
	cmd = binary.BigEndian.AppendUint32(cmd, maxTries)
	cmd = binary.BigEndian.AppendUint32(cmd, recoveryTime)
	cmd = binary.BigEndian.AppendUint32(cmd, lockoutRecovery)
	binary.BigEndian.PutUint32(cmd[2:], uint32(len(cmd)))
	rsp, err := t.Send(cmd)
	if err != nil {
		return err
	}
	if len(rsp) < 10 {
		return fmt.Errorf("the chip's response is %d bytes, shorter than a header", len(rsp))
	}
	if rc := tpm2.TPMRC(binary.BigEndian.Uint32(rsp[6:10])); rc != tpm2.TPMRCSuccess {
		return rc
	}
	return nil
}
