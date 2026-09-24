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

	"github.com/cyfr/keeper/internal/pool"
)

func TestParseArgs(t *testing.T) {
	cfg, err := ParseArgs(strings.Fields("--pool backends:20001-20032 --home-root /var/lib/cyfr-bridge/homes --client-user cyfr-bridge -- node server.mjs"))
	if err != nil {
		t.Fatal(err)
	}
	want := Config{
		Pools:      []pool.Spec{{Name: "backends", First: 20001, Last: 20032}},
		HomeRoot:   "/var/lib/cyfr-bridge/homes",
		ClientUser: "cyfr-bridge",
		ClientArgv: []string{"node", "server.mjs"},
	}
	if !reflect.DeepEqual(cfg, want) {
		t.Fatalf("config %+v", cfg)
	}

	two, err := ParseArgs(strings.Fields("--pool a:100-199 --pool b:200-299 --home-root /h --client-user c -- run --flag"))
	if err != nil || len(two.Pools) != 2 || !reflect.DeepEqual(two.ClientArgv, []string{"run", "--flag"}) {
		t.Fatalf("two pools: %+v %v", two, err)
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

var bridgeUser = user.User{Uid: "10001", Gid: "10001", Username: "cyfr-bridge", HomeDir: "/nonexistent"}

func TestResolveAccounts(t *testing.T) {
	cfg := Config{Pools: []pool.Spec{{Name: "backends", First: 20001, Last: 20003}}, ClientUser: "cyfr-bridge"}
	client, accounts, err := ResolveAccounts(cfg, fakeLookup(bridgeUser, poolUser(20001, 20001), poolUser(20002, 20002)))
	if err != nil {
		t.Fatal(err)
	}
	if client != (Account{UID: 10001, GID: 10001, Name: "cyfr-bridge", Home: "/nonexistent"}) {
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
		"client in group 0": {Config{Pools: pools, ClientUser: "cyfr-bridge"},
			[]user.User{{Uid: "10001", Gid: "0", Username: "cyfr-bridge"}}},
		"client uid in a pool": {Config{Pools: []pool.Spec{{Name: "p", First: 10000, Last: 10002}}, ClientUser: "cyfr-bridge"},
			[]user.User{bridgeUser}},
		"pool uid in group 0": {Config{Pools: pools, ClientUser: "cyfr-bridge"},
			[]user.User{bridgeUser, poolUser(20001, 0)}},
		"pool uid in the client's group": {Config{Pools: pools, ClientUser: "cyfr-bridge"},
			[]user.User{bridgeUser, poolUser(20001, 10001)}},
		"two pool uids share a group": {Config{Pools: pools, ClientUser: "cyfr-bridge"},
			[]user.User{bridgeUser, poolUser(20001, 20002)}},
	}
	for name, c := range cases {
		if _, _, err := ResolveAccounts(c.cfg, fakeLookup(c.users...)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestClientEnvironDescribesTheClientUserAndItsChannel(t *testing.T) {
	got := ClientEnviron([]string{"PATH=/usr/bin", "HOME=/root", "USER=root", "CYFR_MCP_BRIDGE_KEY=t", "KEEPER_CHANNEL=socket:[1]", "LOGNAME=root"},
		Account{Name: "cyfr-bridge", Home: "/nonexistent"}, "socket:[4242]")
	want := []string{"PATH=/usr/bin", "CYFR_MCP_BRIDGE_KEY=t", "HOME=/nonexistent", "USER=cyfr-bridge", "LOGNAME=cyfr-bridge", "KEEPER_CHANNEL=socket:[4242]"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ %q", got)
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
