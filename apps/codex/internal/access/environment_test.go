// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"slices"
	"testing"
)

// Compose reads a variable of its environment ahead of .env's line, so no
// device setting of cyfr's environment reaches a docker call, nor the proxy
// trust, in any case of its name, and the engine's own read of .env
// interpolates none of the devices: a shell's value can neither name another
// device nor take the devices away, nor choose whom the proxy listener
// trusts.
func TestDockersEnvironmentHoldsNoDeviceSetting(t *testing.T) {
	got := sanitizedEnv([]string{"COMPOSE_FILE=x", "CYFR_LOCUS_KVM=/dev/sda", "CYFR_LOCUS_TUN=", "cyfr_locus_kvm=/dev/sdb", "DOCKER_HOST=unix:///run/docker.sock",
		"CYFR_TRUSTED_PROXY_HOPS=3", "cyfr_trusted_proxy_cidrs=0.0.0.0/0", "CYFR_LOCUS_APPARMOR=p"})
	if want := []string{"DOCKER_HOST=unix:///run/docker.sock", "CYFR_LOCUS_APPARMOR=p"}; !slices.Equal(got, want) {
		t.Errorf("docker's environment is %q, want %q", got, want)
	}
	t.Setenv(KVMSetting, "/dev/sda")
	t.Setenv(TunSetting, "/dev/sdb")
	values, err := EnvValues([]byte(KVMSetting + "=${" + KVMSetting + "}\n" + TunSetting + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := values[TunSetting]; values[KVMSetting] != "" || ok {
		t.Errorf("the engine read .env's devices as %q and %q (assigned %t), from the environment compose never sees", values[KVMSetting], v, ok)
	}
}
