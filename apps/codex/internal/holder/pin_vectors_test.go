// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import "testing"

type rfcVector struct {
	key, input, blind, blinded, evaluated, output []byte
}

// rfc9497Vectors is RFC 9497 Appendix A.1.1, OPRF(ristretto255, SHA-512)
// in mode 0.
func rfc9497Vectors(t *testing.T) []rfcVector {
	t.Helper()
	key := hexBytes(t, "5ebcea5ee37023ccb9fc2d2019f9d7737be85591ae8652ffa9ef0f4d37063b0e")
	blind := hexBytes(t, "64d37aed22a27f5191de1c1d69fadb899d8862b58eb4220029e036ec4c1f6706")
	return []rfcVector{
		{key: key, blind: blind, input: hexBytes(t, "00"),
			blinded:   hexBytes(t, "609a0ae68c15a3cf6903766461307e5c8bb2f95e7e6550e1ffa2dc99e412803c"),
			evaluated: hexBytes(t, "7ec6578ae5120958eb2db1745758ff379e77cb64fe77b0b2d8cc917ea0869c7e"),
			output:    hexBytes(t, "527759c3d9366f277d8c6020418d96bb393ba2afb20ff90df23fb7708264e2f3ab9135e3bd69955851de4b1f9fe8a0973396719b7912ba9ee8aa7d0b5e24bcf6")},
		{key: key, blind: blind, input: hexBytes(t, "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"),
			blinded:   hexBytes(t, "da27ef466870f5f15296299850aa088629945a17d1f5b7f5ff043f76b3c06418"),
			evaluated: hexBytes(t, "b4cbf5a4f1eeda5a63ce7b77c7d23f461db3fcab0dd28e4e17cecb5c90d02c25"),
			output:    hexBytes(t, "f4a74c9c592497375e796aa837e907b1a045d34306a749db9f34221f7e750cb4f2a6413a6bf6fa5e19ba6348eb673934a722a7ede2e7621306d18951e7cf2c73")},
	}
}
