// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"errors"
	"os/user"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
)

func TestParseArgs(t *testing.T) {
	cfg, err := ParseArgs(strings.Fields("--pool backends:20001-20032 --home-root /var/lib/locus/homes --client-user locus -- /app/bin/locus start"))
	if err != nil {
		t.Fatal(err)
	}
	want := Config{
		Pools:      []pool.Spec{{Name: "backends", First: 20001, Last: 20032}},
		HomeRoot:   "/var/lib/locus/homes",
		ClientUser: "locus",
		ClientArgv: []string{"/app/bin/locus", "start"},
	}
	if !reflect.DeepEqual(cfg, want) {
		t.Fatalf("config %+v", cfg)
	}

	two, err := ParseArgs(strings.Fields("--pool a:100-199 --pool b:200-299 --home-root /h --client-user c -- run --flag"))
	if err != nil || len(two.Pools) != 2 || !reflect.DeepEqual(two.ClientArgv, []string{"run", "--flag"}) {
		t.Fatalf("two pools: %+v %v", two, err)
	}

	// The locus-runtime service's command line: the runner pool is isolated.
	isolated, err := ParseArgs(strings.Fields("--pool runner:30101-30108:netns --home-root /var/lib/locus/homes --client-user locus -- /app/bin/locus start"))
	if err != nil || !reflect.DeepEqual(isolated.Pools, []pool.Spec{{Name: "runner", First: 30101, Last: 30108, Isolated: true}}) {
		t.Fatalf("an isolated pool: %+v %v", isolated, err)
	}
	if !isolated.Isolating() || cfg.Isolating() {
		t.Fatal("Isolating does not say whether some pool is isolated")
	}
}

func TestParseArgsRefusals(t *testing.T) {
	for _, args := range []string{
		"--home-root /h --client-user c -- run",
		"--pool a:100-199 --client-user c -- run",
		"--pool a:100-199 --home-root h --client-user c -- run",
		"--pool a:100-199 --home-root /h/ --client-user c -- run",
		"--pool a:100-199 --home-root /h -- run",
		"--pool a:100-199 --home-root /h --client-user c --",
		"--pool a:100-199 --home-root /h --client-user c run",
		"--pool a:100-199 --pool a:200-299 --home-root /h --client-user c -- run",
		"--pool a:100-199 --pool b:150-299 --home-root /h --client-user c -- run",
		"--pool a:0-199 --home-root /h --client-user c -- run",
		"--pool a:100-199 --home-root /h --client-user c --unknown x -- run",
	} {
		if _, err := ParseArgs(strings.Fields(args)); err == nil {
			t.Errorf("%q accepted", args)
		}
	}
}

func fakeLookup(users ...user.User) Lookup {
	return Lookup{
		ByName: func(name string) (*user.User, error) {
			for i := range users {
				if users[i].Username == name {
					return &users[i], nil
				}
			}
			return nil, user.UnknownUserError(name)
		},
		ByID: func(uid string) (*user.User, error) {
			for i := range users {
				if users[i].Uid == uid {
					return &users[i], nil
				}
			}
			n, _ := strconv.Atoi(uid)
			return nil, user.UnknownUserIdError(n)
		},
	}
}

func poolUser(uid int, gid int) user.User {
	name := "cyfr-b" + strconv.Itoa(uid)
	return user.User{Uid: strconv.Itoa(uid), Gid: strconv.Itoa(gid), Username: name, HomeDir: "/nonexistent"}
}

var locusUser = user.User{Uid: "10001", Gid: "10001", Username: "locus", HomeDir: "/nonexistent"}

func TestResolveAccounts(t *testing.T) {
	cfg := Config{Pools: []pool.Spec{{Name: "backends", First: 20001, Last: 20003}}, ClientUser: "locus"}
	client, accounts, err := ResolveAccounts(cfg, fakeLookup(locusUser, poolUser(20001, 20001), poolUser(20002, 20002)))
	if err != nil {
		t.Fatal(err)
	}
	if client != (Account{UID: 10001, GID: 10001, Name: "locus", Home: "/nonexistent"}) {
		t.Fatalf("client %+v", client)
	}
	if accounts[20001].Name != "cyfr-b20001" || accounts[20002].GID != 20002 {
		t.Fatalf("named accounts %+v", accounts)
	}
	if accounts[20003] != (Account{UID: 20003, GID: 20003, Name: "20003"}) {
		t.Fatalf("an unnamed pool uid resolved to %+v", accounts[20003])
	}
}

func TestResolveAccountsRefusesSharedOrPrivilegedIdentities(t *testing.T) {
	pools := []pool.Spec{{Name: "backends", First: 20001, Last: 20002}}
	cases := map[string]struct {
		cfg   Config
		users []user.User
	}{
		"unknown client": {Config{Pools: pools, ClientUser: "nobody-here"}, nil},
		"root client": {Config{Pools: pools, ClientUser: "root"},
			[]user.User{{Uid: "0", Gid: "0", Username: "root"}}},
		"client in group 0": {Config{Pools: pools, ClientUser: "locus"},
			[]user.User{{Uid: "10001", Gid: "0", Username: "locus"}}},
		"client uid in a pool": {Config{Pools: []pool.Spec{{Name: "p", First: 10000, Last: 10002}}, ClientUser: "locus"},
			[]user.User{locusUser}},
		"pool uid in group 0": {Config{Pools: pools, ClientUser: "locus"},
			[]user.User{locusUser, poolUser(20001, 0)}},
		"pool uid in the client's group": {Config{Pools: pools, ClientUser: "locus"},
			[]user.User{locusUser, poolUser(20001, 10001)}},
		"two pool uids share a group": {Config{Pools: pools, ClientUser: "locus"},
			[]user.User{locusUser, poolUser(20001, 20002)}},
	}
	for name, c := range cases {
		if _, _, err := ResolveAccounts(c.cfg, fakeLookup(c.users...)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestClientEnvironDescribesTheClientUserAndItsChannel(t *testing.T) {
	got := ClientEnviron([]string{"PATH=/usr/bin", "HOME=/root", "USER=root", "CYFR_LOCUS_BACKENDS_KEY=t", "KEEPER_CHANNEL=socket:[1]", "LOGNAME=root"},
		Account{Name: "locus", Home: "/nonexistent"}, "socket:[4242]", nil)
	want := []string{"PATH=/usr/bin", "CYFR_LOCUS_BACKENDS_KEY=t", "HOME=/nonexistent", "USER=locus", "LOGNAME=locus", "KEEPER_CHANNEL=socket:[4242]"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ %q", got)
	}

	// A keeper that keeps homes names them; an inherited value is replaced.
	kept := &home.Kept{Root: "/var/lib/locus/kept", First: 40001, Last: 49999}
	got = ClientEnviron([]string{"KEEPER_KEPT_HOMES=/elsewhere:1-2", "PATH=/usr/bin"}, Account{Name: "locus"}, "socket:[1]", kept)
	want = []string{"PATH=/usr/bin", "HOME=/", "USER=locus", "LOGNAME=locus", "KEEPER_CHANNEL=socket:[1]", "KEEPER_KEPT_HOMES=/var/lib/locus/kept:40001-49999"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ with kept homes %q", got)
	}
}

func TestParseArgsKeptHomes(t *testing.T) {
	cfg, err := ParseArgs(strings.Fields("--pool backends:20001-20032 --home-root /var/lib/locus/homes --kept-homes /var/lib/locus/kept:40001-49999 --client-user locus -- /app/bin/locus start"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Kept == nil || *cfg.Kept != (home.Kept{Root: "/var/lib/locus/kept", First: 40001, Last: 49999}) {
		t.Fatalf("kept homes %+v", cfg.Kept)
	}
	for _, kept := range []string{
		"/var/lib/locus/kept:20030-20040",       // overlaps the pool
		"/var/lib/locus/homes/kept:40001-40002", // inside the home root
		"/var/lib/locus:40001-40002",            // holds the home root
		"kept:40001-40002",                      // relative
		"/var/lib/locus/kept:40002-40001",       // falling
		"/var/lib/locus/kept:1-70000",           // too many
		"/var/lib/locus/kept",                   // no range
	} {
		args := "--pool backends:20001-20032 --home-root /var/lib/locus/homes --kept-homes " + kept + " --client-user locus -- run"
		if _, err := ParseArgs(strings.Fields(args)); err == nil {
			t.Errorf("--kept-homes %s accepted", kept)
		}
	}
}

func TestResolveAccountsRefusesAKeptRangeSharingAnIdentity(t *testing.T) {
	pools := []pool.Spec{{Name: "backends", First: 20001, Last: 20002}}
	kept := func(first, last int) *home.Kept { return &home.Kept{Root: "/k", First: first, Last: last} }
	ok := Config{Pools: pools, ClientUser: "locus", Kept: kept(40001, 40010)}
	if _, _, err := ResolveAccounts(ok, fakeLookup(locusUser)); err != nil {
		t.Fatalf("a kept range outside every identity: %v", err)
	}
	cases := map[string]struct {
		kept  *home.Kept
		users []user.User
	}{
		"the client's uid": {kept(10000, 10002), []user.User{locusUser}},
		"a pooled gid":     {kept(40001, 40010), []user.User{locusUser, poolUser(20001, 40005)}},
		"a user entry":     {kept(40001, 40010), []user.User{locusUser, poolUser(40007, 40007)}},
	}
	for name, c := range cases {
		cfg := Config{Pools: pools, ClientUser: "locus", Kept: c.kept}
		if _, _, err := ResolveAccounts(cfg, fakeLookup(c.users...)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestCheckEnvironRefusesEveryUndeclaredKeeperVariableByName(t *testing.T) {
	accepted := []string{"PATH=/usr/bin", "CYFR_LOG_FORMAT=json", "LOCUS_BUILDS_KEY=secret", "KEEPERS=1", "KEEPER_CHANNEL=socket:[1]", "KEEPER_KEPT_HOMES=/k:1-2"}
	if err := CheckEnviron(accepted); err != nil {
		t.Fatalf("refused %q: %v", accepted, err)
	}

	err := CheckEnviron(append(accepted, "KEEPER_POOL=build:1-2", "KEEPER_=x", "KEEPER_POOL=again"))
	if err == nil {
		t.Fatal("an undeclared KEEPER_ variable was accepted")
	}
	if !strings.HasPrefix(err.Error(), "KEEPER_, KEEPER_POOL: ") {
		t.Fatalf("error %q does not name each undeclared variable once, sorted", err)
	}
	for _, value := range []string{"build:1-2", "again", "socket:[1]", "secret"} {
		if strings.Contains(err.Error(), value) {
			t.Fatalf("error %q carries the value %q", err, value)
		}
	}
}

func TestPoolAccountsNamesEveryPooledUidAndGid(t *testing.T) {
	got := PoolAccounts(map[int]Account{20001: {UID: 20001, GID: 20001}, 20002: {UID: 20002, GID: 30002}})
	if !got.UIDs[20001] || !got.UIDs[20002] || !got.GIDs[20001] || !got.GIDs[30002] || got.GIDs[20002] || len(got.UIDs) != 2 {
		t.Fatalf("accounts %+v", got)
	}
}

func TestUnknownUserErrorsAreWrapped(t *testing.T) {
	_, _, err := ResolveAccounts(Config{ClientUser: "ghost"}, fakeLookup())
	var unknown user.UnknownUserError
	if !errors.As(err, &unknown) {
		t.Fatalf("error %v does not wrap the lookup failure", err)
	}
}
