// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"sync/atomic"
	"testing"
)

// cheapDerivationMarker is the panic CheapDerivationForTests refuses with.
// A binary holds it only where something in it calls that function, so
// scripts/ci/release-binary-check.sh, which reads it from this file, refuses
// to release one that does.
const cheapDerivationMarker = "holder.CheapDerivationForTests: a cheap key derivation runs in a test binary alone"

// testCost is nil, which is the fixed cost, in every program but a test
// binary that called CheapDerivationForTests.
var testCost atomic.Pointer[argonCost]

// CheapDerivationForTests makes a test binary derive keys cheaply, until
// fixed is called. It panics wherever testing.Testing is false, and takes
// nothing from a flag, the environment, a setting or a file. Its callers are
// tests alone (TestNoProgramReachesTheCheapDerivation holds each reference).
//
// A build with a caller planted and -ldflags '-X testing.testBinary=1' does
// derive cheaply, and such a build is nobody's release. The released build
// holds no caller for that override to enable, the release's check refuses
// any binary holding this function, and that test lets no caller reach main
// unseen.
func CheapDerivationForTests() (fixed func()) {
	if !testing.Testing() {
		panic(cheapDerivationMarker)
	}
	testCost.Store(&argonCost{time: 1, memoryKiB: 64})
	return func() { testCost.Store(nil) }
}
