// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"github.com/google/go-tpm/tpm2/transport"
	"github.com/google/go-tpm/tpm2/transport/linuxudstpm"
)

// UseTPM points the chip holder at the TPM serving the Unix socket sock, a
// software TPM a test runs (holdertest.SWTPM), and answers the restore of
// the chip it used before. Only tests call it: CYFR opens the machine's
// own chip.
func UseTPM(sock string) (restore func()) {
	saved := openTPM
	openTPM = func() (transport.TPMCloser, error) { return linuxudstpm.Open(sock) }
	return func() { openTPM = saved }
}
