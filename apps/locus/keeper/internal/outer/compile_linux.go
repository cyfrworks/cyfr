// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package outer

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"slices"
	"strconv"
	"strings"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// The filter Compile makes decides each call as Docker's profile does for a
// container holding the given capabilities on amd64, in the BPF layout of
// internal/stage's space filter:
//
//   - A call whose architecture is not x86-64, or whose number carries the
//     x32 bit, kills the process. Docker's archMap lets a container's
//     filter take i386 and x32 calls under their own numbers too; a
//     person's machine takes the 64-bit calls alone.
//   - A run of consecutive numbers that rules decide outright alike is one
//     range test jumping to its own return; a lone number is one equality
//     test. None of these jumps passes more than two instructions, so
//     BPF's 8-bit jump offsets hold however many calls the filter decides.
//   - A call rules decide on its arguments is tested once; its rules
//     follow, each a chain of word tests that jumps past the rule's return
//     when one fails, and the default return closes them. A call whose
//     block a jump cannot cross is refused.
//   - Every other number returns the profile's default action.

// profile is what the compiler reads of a Docker seccomp profile
// (moby/profiles' seccomp.Seccomp). The fields Docker knows and this
// package does not apply (architectures, flags, listenerPath,
// listenerMetadata, a rule's deprecated name) are unknown here, so a
// profile carrying one is refused.
type profile struct {
	DefaultAction   string `json:"defaultAction"`
	DefaultErrnoRet *uint  `json:"defaultErrnoRet"`
	// ArchMap is read and not applied: Docker adds the sub-architectures
	// it lists beside the native one, and the filter takes none of them.
	ArchMap  []archMap `json:"archMap"`
	Syscalls []rule    `json:"syscalls"`
}

type archMap struct {
	Architecture     string   `json:"architecture"`
	SubArchitectures []string `json:"subArchitectures"`
}

type rule struct {
	Names    []string `json:"names"`
	Action   string   `json:"action"`
	ErrnoRet *uint    `json:"errnoRet"`
	Args     []arg    `json:"args"`
	Comment  string   `json:"comment"`
	Includes *filter  `json:"includes"`
	Excludes *filter  `json:"excludes"`
}

type filter struct {
	Caps      []string       `json:"caps"`
	Arches    []string       `json:"arches"`
	MinKernel *kernelVersion `json:"minKernel"`
}

type arg struct {
	Index    uint   `json:"index"`
	Value    uint64 `json:"value"`
	ValueTwo uint64 `json:"valueTwo"`
	Op       string `json:"op"`
}

// Offsets into struct seccomp_data on a little-endian machine: the call's
// number, its architecture, and its arguments, each 64 bits wide with the
// low word first.
const (
	dataNR   = 0
	dataArch = 4
	dataArgs = 16
)

// x32SyscallBit marks a call made through the x32 ABI on x86-64.
const x32SyscallBit = 0x40000000

// dockerArch is Docker's name, in a rule's includes and excludes, for the
// architecture the filter describes.
const dockerArch = "amd64"

// maxErrno is the kernel's MAX_ERRNO, the largest errno a filter's
// SECCOMP_RET_ERRNO delivers as asked.
const maxErrno = 4095

// kernelVersion is a kernel's version and major revision, all Docker
// compares of a release against a rule's minKernel.
type kernelVersion struct{ kernel, major uint64 }

// parseRelease reads a release as moby/profiles' parseRelease does: the
// leading "<kernel>.<major>", any further revision or suffix ignored.
func parseRelease(release string) (kernelVersion, error) {
	var v kernelVersion
	if _, err := fmt.Sscanf(release, "%d.%d", &v.kernel, &v.major); err != nil {
		return v, fmt.Errorf("kernel release %q: %w", release, err)
	}
	return v, nil
}

// UnmarshalJSON reads a rule's minKernel as moby/profiles' KernelVersion
// does: exactly "<kernel>.<major>", each below 256, not 0.0. An empty one,
// which Docker reads as 0.0, is refused.
func (v *kernelVersion) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return fmt.Errorf("minKernel: %w", err)
	}
	kernel, major, ok := strings.Cut(s, ".")
	k, kerr := strconv.ParseUint(kernel, 10, 8)
	m, merr := strconv.ParseUint(major, 10, 8)
	if !ok || kerr != nil || merr != nil || k == 0 && m == 0 {
		return fmt.Errorf("minKernel %q is not <kernel>.<major>", s)
	}
	*v = kernelVersion{k, m}
	return nil
}

func (v kernelVersion) atLeast(min kernelVersion) bool {
	return v.kernel > min.kernel || v.kernel == min.kernel && v.major >= min.major
}

// action is a rule's or the default's action as a filter's return value.
// SCMP_ACT_ERRNO without an errno is EPERM, as runc's getAction makes it:
// a rule's errnoRet does not fall back to the profile's defaultErrnoRet.
// An errno of 0, which would make a refused call look successful, is
// refused.
func action(name string, errnoRet *uint) (uint32, error) {
	switch name {
	case "SCMP_ACT_ALLOW":
		if errnoRet != nil {
			return 0, errors.New("SCMP_ACT_ALLOW carries an errno")
		}
		return unix.SECCOMP_RET_ALLOW, nil
	case "SCMP_ACT_ERRNO":
		errno := uint(unix.EPERM)
		if errnoRet != nil {
			errno = *errnoRet
		}
		if errno == 0 || errno > maxErrno {
			return 0, fmt.Errorf("errno %d is outside 1 to %d", errno, maxErrno)
		}
		return unix.SECCOMP_RET_ERRNO | uint32(errno), nil
	}
	return 0, fmt.Errorf("action %q is not one the filter applies", name)
}

// wordTest passes when the 32-bit word at off, masked, equals datum (when
// equal) or differs from it (when not).
type wordTest struct {
	off   uint32
	mask  uint32
	datum uint32
	equal bool
}

// comparison is one argument condition as word tests that must all pass.
// libseccomp compares the whole 64-bit argument, while the kernel reads an
// int argument as its low word alone: socket(0x1_0000_0028) is AF_VSOCK
// (40) to the kernel and passes a 64-bit test of "family != 40". Every
// condition here gates an allow, so the filter takes the stricter of the
// two readings: EQ and MASKED_EQ need both words to match, which implies
// the low word does; NE needs the low words to differ, which implies the
// 64-bit values do. A 64-bit argument whose low word alone matches an NE's
// value is therefore refused. MASKED_EQ's value is the mask and valueTwo
// the datum, masked too, as libseccomp's db.c reads them. The ordered
// comparisons are refused: the kernel reads an int argument signed, a BPF
// comparison is unsigned, and the two disagree below zero.
func comparison(a arg) ([]wordTest, error) {
	if a.Index > 5 {
		return nil, fmt.Errorf("argument %d: a call has six", a.Index)
	}
	lo := uint32(dataArgs + 8*a.Index)
	hi := lo + 4
	switch a.Op {
	case "SCMP_CMP_EQ", "SCMP_CMP_NE":
		if a.ValueTwo != 0 {
			return nil, fmt.Errorf("%s carries a valueTwo", a.Op)
		}
		if a.Op == "SCMP_CMP_NE" {
			return []wordTest{{lo, math.MaxUint32, uint32(a.Value), false}}, nil
		}
		return []wordTest{
			{lo, math.MaxUint32, uint32(a.Value), true},
			{hi, math.MaxUint32, uint32(a.Value >> 32), true},
		}, nil
	case "SCMP_CMP_MASKED_EQ":
		mask, datum := a.Value, a.ValueTwo&a.Value
		return []wordTest{
			{lo, uint32(mask), uint32(datum), true},
			{hi, uint32(mask >> 32), uint32(datum >> 32), true},
		}, nil
	}
	return nil, fmt.Errorf("comparison %q is not one the filter applies", a.Op)
}

// applies reports whether a rule holds for a container holding caps on a
// kernel, as moby/profiles' setupSeccomp decides: a rule is dropped when
// excludes lists amd64, any capability the container holds, or a minKernel
// the kernel reaches, and kept only when includes lists amd64 (or no
// architecture), every capability it lists is held, and the kernel reaches
// its minKernel.
func (r rule) applies(held map[string]bool, kernel kernelVersion) bool {
	if e := r.Excludes; e != nil {
		if slices.Contains(e.Arches, dockerArch) || slices.ContainsFunc(e.Caps, func(c string) bool { return held[c] }) ||
			e.MinKernel != nil && kernel.atLeast(*e.MinKernel) {
			return false
		}
	}
	if i := r.Includes; i != nil {
		if len(i.Arches) > 0 && !slices.Contains(i.Arches, dockerArch) ||
			slices.ContainsFunc(i.Caps, func(c string) bool { return !held[c] }) ||
			i.MinKernel != nil && !kernel.atLeast(*i.MinKernel) {
			return false
		}
	}
	return true
}

// call is the profile's decision for one system call: its action, taken
// outright when unconditional and otherwise when every test of any one of
// rules passes; the default action otherwise.
type call struct {
	action        uint32
	unconditional bool
	rules         [][]wordTest
}

// policy is what a profile decides on one kernel for one container.
type policy struct {
	defaultAction uint32
	calls         map[uint32]*call
	// skipped are the names applicable rules list that the kernel's table
	// lacks, left to the default action as libseccomp leaves a name the
	// architecture does not know.
	skipped []string
}

// resolve reads a profile and decides it for the container and kernel.
// Every rule must be one the filter can apply, applicable or not. Of the
// applicable rules, one whose action is the default's is skipped, as runc's
// matchCall skips it; a call's remaining rules must agree on one action,
// any unconditional one deciding the call outright; and a conditional rule
// must allow, so that its stricter reading is the one that allows less.
func resolve(profileJSON []byte, table map[string]uint32, caps []string, kernelRelease string) (policy, error) {
	var p profile
	decoder := json.NewDecoder(bytes.NewReader(profileJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&p); err != nil {
		return policy{}, fmt.Errorf("seccomp profile: %w", err)
	}
	if _, err := decoder.Token(); err != io.EOF {
		return policy{}, errors.New("seccomp profile: data after the profile")
	}
	if len(table) == 0 {
		return policy{}, errors.New("the syscall table is empty")
	}
	kernel, err := parseRelease(kernelRelease)
	if err != nil {
		return policy{}, err
	}
	held := map[string]bool{}
	for _, c := range caps {
		if !strings.HasPrefix(c, "CAP_") {
			return policy{}, fmt.Errorf("capability %q is not named CAP_*", c)
		}
		held[c] = true
	}
	defaultAction, err := action(p.DefaultAction, p.DefaultErrnoRet)
	if err != nil {
		return policy{}, fmt.Errorf("seccomp profile default: %w", err)
	}
	decided := policy{defaultAction: defaultAction, calls: map[uint32]*call{}}
	skipped := map[string]bool{}
	for i, r := range p.Syscalls {
		act, tests, err := r.shape()
		if err != nil {
			return policy{}, fmt.Errorf("seccomp profile rule %d: %w", i, err)
		}
		if !r.applies(held, kernel) || act == defaultAction {
			continue
		}
		if tests != nil && act != unix.SECCOMP_RET_ALLOW {
			return policy{}, fmt.Errorf("seccomp profile rule %d: a conditional rule must allow", i)
		}
		for _, name := range r.Names {
			nr, ok := table[name]
			if !ok {
				skipped[name] = true
				continue
			}
			c := decided.calls[nr]
			if c == nil {
				c = &call{action: act}
				decided.calls[nr] = c
			}
			if c.action != act {
				return policy{}, fmt.Errorf("seccomp profile rule %d: %s has rules of two actions", i, name)
			}
			if tests == nil {
				c.unconditional, c.rules = true, nil
			} else if !c.unconditional {
				c.rules = append(c.rules, tests)
			}
		}
	}
	for name := range skipped {
		decided.skipped = append(decided.skipped, name)
	}
	slices.Sort(decided.skipped)
	return decided, nil
}

// shape checks a rule is one the filter can apply and returns its action
// and its argument tests, nil when it has no condition. Two conditions on
// one argument are refused: runc adds each as a rule of its own, so they
// would allow when either holds, not both.
func (r rule) shape() (uint32, []wordTest, error) {
	if len(r.Names) == 0 || slices.Contains(r.Names, "") {
		return 0, nil, errors.New("a rule names no call or an empty one")
	}
	act, err := action(r.Action, r.ErrnoRet)
	if err != nil {
		return 0, nil, err
	}
	var tests []wordTest
	seen := map[uint]bool{}
	for _, a := range r.Args {
		if seen[a.Index] {
			return 0, nil, fmt.Errorf("two conditions on argument %d", a.Index)
		}
		seen[a.Index] = true
		words, err := comparison(a)
		if err != nil {
			return 0, nil, err
		}
		tests = append(tests, words...)
	}
	return act, tests, nil
}

// program is the policy's filter.
func (p policy) program() ([]bpf.Instruction, error) {
	kill := bpf.RetConstant{Val: unix.SECCOMP_RET_KILL_PROCESS}
	program := []bpf.Instruction{
		bpf.LoadAbsolute{Off: dataArch, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.AUDIT_ARCH_X86_64, SkipTrue: 1},
		kill,
		bpf.LoadAbsolute{Off: dataNR, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpGreaterOrEqual, Val: x32SyscallBit, SkipFalse: 1},
		kill,
	}
	numbers := make([]uint32, 0, len(p.calls))
	for nr := range p.calls {
		numbers = append(numbers, nr)
	}
	slices.Sort(numbers)
	for i := 0; i < len(numbers); {
		first := numbers[i]
		c := p.calls[first]
		if !c.unconditional {
			block, err := c.block(first, p.defaultAction)
			if err != nil {
				return nil, err
			}
			program = append(program, block...)
			i++
			continue
		}
		last := i
		for last+1 < len(numbers) && numbers[last+1] == numbers[last]+1 {
			next := p.calls[numbers[last+1]]
			if !next.unconditional || next.action != c.action {
				break
			}
			last++
		}
		ret := bpf.RetConstant{Val: c.action}
		if last == i {
			program = append(program, bpf.JumpIf{Cond: bpf.JumpEqual, Val: first, SkipFalse: 1}, ret)
		} else {
			program = append(program,
				bpf.JumpIf{Cond: bpf.JumpGreaterOrEqual, Val: first, SkipFalse: 2},
				bpf.JumpIf{Cond: bpf.JumpGreaterThan, Val: numbers[last], SkipTrue: 1},
				ret)
		}
		i = last + 1
	}
	program = append(program, bpf.RetConstant{Val: p.defaultAction})
	if len(program) > unix.BPF_MAXINSNS {
		return nil, fmt.Errorf("the filter is %d instructions, over the kernel's %d", len(program), unix.BPF_MAXINSNS)
	}
	return program, nil
}

// block is a conditional call's part of the filter: the test of its
// number, which skips the block for any other, then each rule, then the
// default return. The block loads arguments over the number, so every way
// through it returns.
func (c *call) block(nr uint32, defaultAction uint32) ([]bpf.Instruction, error) {
	var body []bpf.Instruction
	for _, tests := range c.rules {
		var rule []bpf.Instruction
		var fails []int
		for _, t := range tests {
			// A word masked to nothing matches any datum masked alike.
			if t.mask == 0 {
				continue
			}
			rule = append(rule, bpf.LoadAbsolute{Off: t.off, Size: 4})
			if t.mask != math.MaxUint32 {
				rule = append(rule, bpf.ALUOpConstant{Op: bpf.ALUOpAnd, Val: t.mask})
			}
			// The jump is taken when the test fails.
			cond := bpf.JumpEqual
			if t.equal {
				cond = bpf.JumpNotEqual
			}
			fails = append(fails, len(rule))
			rule = append(rule, bpf.JumpIf{Cond: cond, Val: t.datum})
		}
		rule = append(rule, bpf.RetConstant{Val: c.action})
		for _, at := range fails {
			jump := rule[at].(bpf.JumpIf)
			jump.SkipTrue = uint8(len(rule) - at - 1)
			rule[at] = jump
		}
		body = append(body, rule...)
	}
	body = append(body, bpf.RetConstant{Val: defaultAction})
	if len(body) > math.MaxUint8 {
		return nil, fmt.Errorf("call %d's rules are %d instructions, over a jump's reach", nr, len(body))
	}
	return append([]bpf.Instruction{bpf.JumpIf{Cond: bpf.JumpEqual, Val: nr, SkipFalse: uint8(len(body))}}, body...), nil
}

// Compile is the profile's filter, as Docker applies it to a container
// holding exactly caps (its bounding set: Docker's defaults it keeps and
// its cap_add, each named CAP_*) on amd64 and a kernel of kernelRelease,
// for the calls table numbers. A name the table lacks is skipped. A
// profile, rule, action or comparison the filter cannot apply as Docker
// would is refused with an error, never compiled to a filter that allows
// more.
func Compile(profile []byte, table map[string]uint32, caps []string, kernelRelease string) ([]bpf.RawInstruction, error) {
	p, err := resolve(profile, table, caps, kernelRelease)
	if err != nil {
		return nil, err
	}
	program, err := p.program()
	if err != nil {
		return nil, err
	}
	raw, err := bpf.Assemble(program)
	if err != nil {
		return nil, fmt.Errorf("assembling the filter: %w", err)
	}
	return raw, nil
}
