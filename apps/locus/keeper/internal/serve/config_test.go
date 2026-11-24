// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"os/user"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
)

// theRoles is the image's command line, before its pools.
const theRoles = "--role runtime:10011:4200:runner:private --role builds:10012:4100:build --role backends:10013:4101:backends:kept " +
	"--pool runner:30101-30108:relay --pool build:30001-30016:routed --pool backends:20001-20032:routed " +
	"--home-root /var/lib/locus/homes --kept-homes /var/lib/locus/kept:40001-49999 --guard /run/g/guard.sock"

func TestParseArgs(t *testing.T) {
	cfg, err := ParseArgs(strings.Fields(theRoles + " -- /app/bin/locus start"))
	if err != nil {
		t.Fatal(err)
	}
	want := Config{
		Pools: []pool.Spec{
			{Name: "runner", First: 30101, Last: 30108, Reach: pool.ReachRelay},
			{Name: "build", First: 30001, Last: 30016, Reach: pool.ReachRouted},
			{Name: "backends", First: 20001, Last: 20032, Reach: pool.ReachRouted},
		},
		Roles: []RoleSpec{
			{Name: "runtime", UID: 10011, Port: 4200, Pool: "runner", Private: true},
			{Name: "builds", UID: 10012, Port: 4100, Pool: "build"},
			{Name: "backends", UID: 10013, Port: 4101, Pool: "backends", Kept: true},
		},
		HomeRoot: "/var/lib/locus/homes",
		Command:  []string{"/app/bin/locus", "start"},
		Kept:     &home.Kept{Root: "/var/lib/locus/kept", First: 40001, Last: 49999},
		Guard:    "/run/g/guard.sock",
	}
	if !reflect.DeepEqual(cfg, want) {
		t.Fatalf("config %+v", cfg)
	}
	if cfg.Roles[1].KeyEnv() != "LOCUS_BUILDS_KEY" || cfg.Roles[1].User() != "locus-builds" {
		t.Fatalf("role builds: key %s, user %s", cfg.Roles[1].KeyEnv(), cfg.Roles[1].User())
	}

	one, err := ParseArgs(strings.Fields("--role a:100:4000:p --pool p:200-299:relay --home-root /h --guard /g -- run --flag"))
	if err != nil || len(one.Roles) != 1 || one.Kept != nil || !reflect.DeepEqual(one.Command, []string{"run", "--flag"}) {
		t.Fatalf("one role: %+v %v", one, err)
	}
	if one.Routed() || !cfg.Routed() {
		t.Fatal("Routed does not say whether some pool is routed")
	}
}

func TestParseRoleRefusals(t *testing.T) {
	for _, value := range []string{
		"a:100:4000", "a:100:4000:p:private:kept:x", "A:100:4000:p", "a_b:100:4000:p", "log:100:4000:p", "1a:100:4000:p",
		"a:0:4000:p", "a:-1:4000:p", "a:4294967295:4000:p", "a:x:4000:p", "a:100:0:p", "a:100:65536:p", "a:100:04000:p",
		"a:100:4000:", "a:100:4000:p:kept:private", "a:100:4000:p:private:private", "a:100:4000:p:kept:kept", "a:100:4000:p:shared",
	} {
		if r, err := ParseRole(value); err == nil {
			t.Errorf("role %q accepted as %+v", value, r)
		}
	}
}

func TestParseArgsRefusals(t *testing.T) {
	const pools = " --pool p:200-299:routed --pool q:300-399:relay --home-root /h --guard /g"
	for _, args := range []string{
		"--home-root /h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --home-root /h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:relay --pool q:300-399:relay --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:relay --pool q:300-399:relay --home-root h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:relay --pool q:300-399:relay --home-root /h/ --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q" + pools + " --",
		"--role a:100:4000:p --role b:101:4001:q" + pools + " run",
		"--role a:100:4000:p --role b:101:4001:q" + pools + " --unknown x -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:relay --pool p:300-399:relay --home-root /h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:relay --pool q:250-399:relay --home-root /h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:0-199:relay --pool q:300-399:relay --home-root /h --guard /g -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299 --pool q:300-399:relay --home-root /h --guard /g -- run",
		// Every role's space is routed: the guard is required.
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:routed --pool q:300-399:relay --home-root /h -- run",
		"--role a:100:4000:p --role b:101:4001:q --pool p:200-299:routed --pool q:300-399:relay --home-root /h --guard g -- run",
		// The roles are each their own.
		"--pool p:200-299:routed --home-root /h --guard /g -- run",
		"--role a:100:4000:p --role a:101:4001:q" + pools + " -- run",
		"--role a:100:4000:p --role b:100:4001:q" + pools + " -- run",
		"--role a:100:4000:p --role b:101:4000:q" + pools + " -- run",
		"--role a:100:4000:p --role b:101:4001:p" + pools + " -- run",
		"--role a:100:4000:p --role b:101:4001:r" + pools + " -- run",
		"--role a:100:4000:p" + pools + " -- run",
		"--role a:250:4000:p --role b:101:4001:q" + pools + " -- run",
		"--role a:100:4000:p --role b:301:4001:q" + pools + " -- run",
		// Kept on one role of a routed pool, with --kept-homes, and its
		// range holds no role's uid.
		"--role a:100:4000:p:kept --role b:101:4001:q:kept" + pools + " --kept-homes /k:400-499 -- run",
		"--role a:100:4000:p --role b:101:4001:q:kept" + pools + " --kept-homes /k:400-499 -- run",
		"--role a:100:4000:p:kept --role b:101:4001:q" + pools + " -- run",
		"--role a:100:4000:p --role b:101:4001:q" + pools + " --kept-homes /k:400-499 -- run",
		"--role a:450:4000:p:kept --role b:101:4001:q" + pools + " --kept-homes /k:400-499 -- run",
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

// roleUser is the image's user entry of a role.
func roleUser(name string, uid int) user.User {
	return user.User{Uid: strconv.Itoa(uid), Gid: strconv.Itoa(uid), Username: "locus-" + name, HomeDir: "/nonexistent"}
}

var twoRoles = []RoleSpec{{Name: "runtime", UID: 10011, Pool: "runner"}, {Name: "backends", UID: 10013, Pool: "backends"}}

func TestResolveAccounts(t *testing.T) {
	cfg := Config{Pools: []pool.Spec{{Name: "backends", First: 20001, Last: 20003}}, Roles: twoRoles}
	roles, accounts, err := ResolveAccounts(cfg, fakeLookup(roleUser("runtime", 10011), poolUser(20001, 20001), poolUser(20002, 20002)))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(roles, []Account{{UID: 10011, GID: 10011, Name: "locus-runtime"}, {UID: 10013, GID: 10013, Name: "locus-backends"}}) {
		t.Fatalf("roles %+v", roles)
	}
	if accounts[20001].Name != "cyfr-b20001" || accounts[20002].GID != 20002 {
		t.Fatalf("named accounts %+v", accounts)
	}
	if accounts[20003] != (Account{UID: 20003, GID: 20003, Name: "20003"}) {
		t.Fatalf("an unnamed pool uid resolved to %+v", accounts[20003])
	}
}

func TestResolveAccountsRefusesSharedOrPrivilegedIdentities(t *testing.T) {
	cfg := Config{Pools: []pool.Spec{{Name: "backends", First: 20001, Last: 20002}}, Roles: twoRoles}
	cases := map[string][]user.User{
		"a role's uid under another name": {{Uid: "10011", Gid: "10011", Username: "locus"}},
		"a role's uid in another group":   {{Uid: "10011", Gid: "10001", Username: "locus-runtime"}},
		"pool uid in group 0":             {poolUser(20001, 0)},
		"pool uid in a role's group":      {poolUser(20001, 10013)},
		"two pool uids share a group":     {poolUser(20001, 20002)},
	}
	for name, users := range cases {
		if _, _, err := ResolveAccounts(cfg, fakeLookup(users...)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// A role's environment is built from nothing: its own variables but its
// limits, the log's, the image's locale and release variables, and what
// the keeper sets, its channel and run folder; never another role's.
func TestRoleEnvironHoldsTheRolesOwnAndNothingOfAnothers(t *testing.T) {
	environ := []string{
		"PATH=/usr/bin", "HOME=/root", "USER=root", "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "LANGUAGE=en", "ELIXIR_ERL_OPTIONS=+fnu",
		"RELEASE_DISTRIBUTION=none", "RELEASE_TMP=/tmp", "HOSTNAME=locus", "CYFR_LOG_FORMAT=json",
		"LOCUS_RUNTIME_KEY=rk", "LOCUS_RUNTIME_PORT=4200", "LOCUS_RUNTIME_MEMORY_LIMIT=4G", "LOCUS_RUNTIME_CPU_LIMIT=4",
		"LOCUS_BUILDS_KEY=bk", "LOCUS_BUILDS_MEMORY_LIMIT=4G", "LOCUS_RUNTIMES_KEY=x", "LOCUS_LOG_LEVEL=info",
		"KEEPER_CHANNEL=socket:[1]", "KEEPER_RUN_DIR=/elsewhere",
	}
	got := RoleEnviron(environ, RoleSpec{Name: "runtime"}, "/run/locus/runtime", "socket:[4242]")
	want := map[string]string{
		"PATH": "/usr/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "LANGUAGE": "en", "ELIXIR_ERL_OPTIONS": "+fnu", "RELEASE_DISTRIBUTION": "none",
		"LOCUS_RUNTIME_KEY": "rk", "LOCUS_RUNTIME_PORT": "4200", "LOCUS_LOG_LEVEL": "info",
		"RELEASE_TMP": "/run/locus/runtime", "HOME": "/run/locus/runtime", "KEEPER_CHANNEL": "socket:[4242]", "KEEPER_RUN_DIR": "/run/locus/runtime",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ %q", got)
	}
}

func TestKeyedNeedsTheRolesOwnKeyNotEmpty(t *testing.T) {
	r := RoleSpec{Name: "builds"}
	for environ, want := range map[string]bool{
		"LOCUS_BUILDS_KEY=k": true, "LOCUS_BUILDS_KEY=": false, "LOCUS_RUNTIME_KEY=k": false, "LOCUS_BUILDS_KEYS=k": false,
	} {
		if got := Keyed([]string{environ}, r); got != want {
			t.Errorf("Keyed(%q) = %t", environ, got)
		}
	}
}

// A role's bounds are read as Docker reads a container's, and anything
// else refuses the boot by the variable's name.
func TestRoleLimitsReadDockersSyntaxStrictly(t *testing.T) {
	r := RoleSpec{Name: "runtime"}
	for _, c := range []struct {
		memory, cpu string
		want        cgroup.Limits
	}{
		{"4G", "4", cgroup.Limits{MemoryBytes: 4 << 30, CPUQuota: 400_000}},
		{"2g", "0.5", cgroup.Limits{MemoryBytes: 2 << 30, CPUQuota: 50_000}},
		{"512M", "1.25", cgroup.Limits{MemoryBytes: 512 << 20, CPUQuota: 125_000}},
		{"1.5g", "0.01", cgroup.Limits{MemoryBytes: 3 << 29, CPUQuota: 1_000}},
		{"8192", "", cgroup.Limits{MemoryBytes: 8192}},
		{"64k", "", cgroup.Limits{MemoryBytes: 64 << 10}},
		{"1t", "", cgroup.Limits{MemoryBytes: 1 << 40}},
		{"", "", cgroup.Limits{}},
	} {
		environ := []string{"LOCUS_RUNTIME_MEMORY_LIMIT=" + c.memory, "LOCUS_RUNTIME_CPU_LIMIT=" + c.cpu, "LOCUS_BUILDS_MEMORY_LIMIT=nonsense"}
		got, err := RoleLimits(environ, r)
		if err != nil || got != c.want {
			t.Errorf("memory %q, cpu %q: %+v, %v", c.memory, c.cpu, got, err)
		}
	}
	for _, bad := range []string{"0", "4096b0", "4 G", "4GB", "4Gi", "-4G", "4x", ".5g", "1.", "0.3b", "4095", "99999999999t"} {
		if _, err := RoleLimits([]string{"LOCUS_RUNTIME_MEMORY_LIMIT=" + bad}, r); err == nil || !strings.Contains(err.Error(), "LOCUS_RUNTIME_MEMORY_LIMIT") || strings.Contains(err.Error(), strconv.Quote(bad)) {
			t.Errorf("memory %q: %v", bad, err)
		}
	}
	for _, bad := range []string{"0", "0.009", "0.000001", "-1", "1e2", "two", "2 ", ".5", "0x2"} {
		if _, err := RoleLimits([]string{"LOCUS_RUNTIME_CPU_LIMIT=" + bad}, r); err == nil || !strings.Contains(err.Error(), "LOCUS_RUNTIME_CPU_LIMIT") {
			t.Errorf("cpu %q: %v", bad, err)
		}
	}
}

func TestParseArgsKeptHomes(t *testing.T) {
	for _, kept := range []string{
		"/var/lib/locus/kept:20030-20040",       // overlaps a pool
		"/var/lib/locus/homes/kept:40001-40002", // inside the home root
		"/var/lib/locus:40001-40002",            // holds the home root
		"kept:40001-40002",                      // relative
		"/var/lib/locus/kept:40002-40001",       // falling
		"/var/lib/locus/kept:1-70000",           // too many
		"/var/lib/locus/kept",                   // no range
		"/var/lib/locus/kept:10010-10020",       // holds a role's uid
	} {
		args := strings.Replace(theRoles, "/var/lib/locus/kept:40001-49999", kept, 1) + " -- run"
		if _, err := ParseArgs(strings.Fields(args)); err == nil {
			t.Errorf("--kept-homes %s accepted", kept)
		}
	}
}

func TestResolveAccountsRefusesAKeptRangeSharingAnIdentity(t *testing.T) {
	pools := []pool.Spec{{Name: "backends", First: 20001, Last: 20002}}
	kept := func(first, last int) *home.Kept { return &home.Kept{Root: "/k", First: first, Last: last} }
	ok := Config{Pools: pools, Roles: twoRoles, Kept: kept(40001, 40010)}
	if _, _, err := ResolveAccounts(ok, fakeLookup()); err != nil {
		t.Fatalf("a kept range outside every identity: %v", err)
	}
	cases := map[string]struct {
		kept  *home.Kept
		users []user.User
	}{
		"a role's gid": {kept(10010, 10012), nil},
		"a pooled gid": {kept(40001, 40010), []user.User{poolUser(20001, 40005)}},
		"a user entry": {kept(40001, 40010), []user.User{poolUser(40007, 40007)}},
	}
	for name, c := range cases {
		cfg := Config{Pools: pools, Roles: twoRoles, Kept: c.kept}
		if _, _, err := ResolveAccounts(cfg, fakeLookup(c.users...)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestCheckEnvironRefusesEveryUndeclaredKeeperVariableByName(t *testing.T) {
	accepted := []string{"PATH=/usr/bin", "CYFR_LOG_FORMAT=json", "LOCUS_BUILDS_KEY=secret", "KEEPERS=1", "KEEPER_CHANNEL=socket:[1]", "KEEPER_RUN_DIR=/run/locus/x"}
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

// A uid or gid outside 0..(uid_t)-2 is refused where the record is read,
// before any policy sees it: 4294967296 narrows to root in the launchers'
// uint32 credential, and 4294967295 is no id.
func TestResolveAccountsRefusesAnIdOutsideTheLinuxRange(t *testing.T) {
	pools := []pool.Spec{{Name: "backends", First: 20001, Last: 20001}}
	roles := []RoleSpec{{Name: "runtime", UID: 10011, Pool: "backends"}}
	for _, bad := range []string{"-1", "4294967295", "4294967296", "4294987297", "+10001"} {
		roleGroup := roleUser("runtime", 10011)
		roleGroup.Gid = bad
		pooled := poolUser(20001, 20001)
		pooled.Uid = bad
		pooledGroup := poolUser(20001, 20001)
		pooledGroup.Gid = bad
		cases := map[string]Lookup{
			"role gid":   fakeLookup(roleGroup),
			"pooled uid": recordFor(pooled),
			"pooled gid": fakeLookup(pooledGroup),
		}
		for name, lookup := range cases {
			_, _, err := ResolveAccounts(Config{Pools: pools, Roles: roles}, lookup)
			if err == nil || !strings.Contains(err.Error(), strconv.Quote(bad)+" is not an id from 0 to 4294967294") {
				t.Errorf("%s %s: error %v", name, bad, err)
			}
		}
	}
	top := poolUser(20001, 4294967294)
	_, accounts, err := ResolveAccounts(Config{Pools: pools, Roles: roles}, fakeLookup(top))
	if err != nil || accounts[20001].GID != 4294967294 {
		t.Fatalf("the highest gid: %+v, %v", accounts[20001], err)
	}
}

// recordFor answers every uid with record, whatever uid the record
// carries, but the role's, which has none.
func recordFor(record user.User) Lookup {
	return Lookup{
		ByName: fakeLookup().ByName,
		ByID: func(uid string) (*user.User, error) {
			if uid == "10011" {
				return nil, user.UnknownUserIdError(10011)
			}
			return &record, nil
		},
	}
}

func TestPoolAccountsNamesEveryPooledUidAndGid(t *testing.T) {
	got := PoolAccounts(map[int]Account{20001: {UID: 20001, GID: 20001}, 20002: {UID: 20002, GID: 30002}})
	if !got.UIDs[20001] || !got.UIDs[20002] || !got.GIDs[20001] || !got.GIDs[30002] || got.GIDs[20002] || len(got.UIDs) != 2 {
		t.Fatalf("accounts %+v", got)
	}
}
