// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"testing"
)

// The shell reads every recovery code of tests/fixtures/recovery_code.json
// as Prima.RecoveryCode reads it, and refuses each refused text with its
// reason.
func TestDecodeRecoveryCode_ReadsTheFixture(t *testing.T) {
	var v struct {
		Valid     []struct{ Code, Identifier, Secret, Name string } `json:"valid"`
		Spellings []struct{ Code, Text, Name string }               `json:"spellings"`
		Refused   []struct{ Error, Text, Name string }              `json:"refused"`
	}
	fixture(t, "recovery_code.json", &v)
	read := map[string][2]string{}
	for _, c := range v.Valid {
		id, secret, err := DecodeRecoveryCode(c.Code)
		if err != nil || id != c.Identifier || b64(secret) != c.Secret {
			t.Errorf("%s: %s %s %v", c.Name, id, b64(secret), err)
		}
		read[c.Code] = [2]string{id, b64(secret)}
	}
	for _, c := range v.Spellings {
		id, secret, err := DecodeRecoveryCode(c.Text)
		want, known := read[c.Code]
		if !known {
			want[0], _, _ = DecodeRecoveryCode(c.Code)
			_, s, _ := DecodeRecoveryCode(c.Code)
			want[1] = b64(s)
		}
		if err != nil || id != want[0] || b64(secret) != want[1] {
			t.Errorf("spelling %s: %v", c.Name, err)
		}
	}
	for _, c := range v.Refused {
		if _, _, err := DecodeRecoveryCode(c.Text); err == nil || err.Error() != c.Error {
			t.Errorf("refused %s: %v, want %s", c.Name, err, c.Error)
		}
	}
}
