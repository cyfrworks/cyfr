// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package serve is `cyfr-locus serve`: it checks its own privileges, starts
// a process for each role whose key it is given, each in a space of its own
// with a socketpair on fd 3, and answers each role's requests (package
// protocol) on that role's channel by starting, signalling and retiring
// processes under the uids of that role's pool.
package serve

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"math/big"
	"os/user"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/residue"
)

// Config is the parsed command line.
type Config struct {
	Pools []pool.Spec
	Roles []RoleSpec
	// HomeRoot holds a folder of each role's spawns' homes, named for the
	// role.
	HomeRoot string
	// Command is what every role process runs, in its own environment.
	Command []string
	// Kept is the kept-homes root and uid range, nil for a keeper that
	// keeps no homes.
	Kept *home.Kept
	// Guard is the socket of the island's egress guard's control (package
	// guard), which routes every role's space.
	Guard string
}

// RoleSpec is one --role: a process the keeper starts when its key is set,
// under its own uid, which is its gid, listening on its port in its space,
// whose spawns draw from its one pool. Private gives its route the guard's
// private reach; Kept makes it the one role whose sessions keep homes;
// Floor the one role whose runners the warm floor keeps, whose spawns'
// groups are in work beside rest (package cgroup).
type RoleSpec struct {
	Name    string
	UID     int
	Port    uint16
	Pool    string
	Private bool
	Kept    bool
	Floor   bool
}

// KeyEnv is the role's key variable: the keeper starts the role only when
// its environment holds it, not empty.
func (r RoleSpec) KeyEnv() string { return r.envPrefix() + "KEY" }

// envPrefix is the prefix of every variable of the role's.
func (r RoleSpec) envPrefix() string { return "LOCUS_" + strings.ToUpper(r.Name) + "_" }

// User is the role's user name.
func (r RoleSpec) User() string { return "locus-" + r.Name }

// ParseRole parses `<name>:<uid>:<port>:<pool>[:private][:kept][:floor]`.
// The name is a role's (cgroup.ValidRoleName) and none of `log`, whose
// variables are every role's, `core` and `service`, whose would be the
// pool's LOCUS_CORE_RESERVE_BYTES and LOCUS_SERVICE_BYTES; the uid is not
// root's and the port is 1..65535.
func ParseRole(value string) (RoleSpec, error) {
	fields := strings.Split(value, ":")
	bad := func(why string) (RoleSpec, error) {
		return RoleSpec{}, fmt.Errorf("role %q: %s; want <name>:<uid>:<port>:<pool>[:private][:kept][:floor]", value, why)
	}
	if len(fields) < 4 || len(fields) > 7 {
		return bad("four to seven fields")
	}
	r := RoleSpec{Name: fields[0], Pool: fields[3]}
	if !cgroup.ValidRoleName(r.Name) || r.Name == "log" || r.Name == "core" || r.Name == "service" {
		return bad("its name is a lowercase letter, then lowercase letters and digits, and not log, core, service, keeper or rest")
	}
	uid, err := parseID(fields[1])
	if err != nil || uid == 0 {
		return bad("its uid is a non-root id")
	}
	r.UID = uid
	port, err := strconv.ParseUint(fields[2], 10, 16)
	if err != nil || port == 0 || fields[2] != strconv.FormatUint(port, 10) {
		return bad("its port is 1..65535")
	}
	r.Port = uint16(port)
	if r.Pool == "" {
		return bad("it names its pool")
	}
	flags := fields[4:]
	for i, f := range flags {
		switch {
		case f == "private" && i == 0 && !r.Private:
			r.Private = true
		case f == "kept" && !r.Kept && !r.Floor:
			r.Kept = true
		case f == "floor" && !r.Floor:
			r.Floor = true
		default:
			return bad("its flags are private, then kept, then floor")
		}
	}
	return r, nil
}

type poolFlags []pool.Spec

func (p *poolFlags) String() string { return fmt.Sprint(*p) }

func (p *poolFlags) Set(value string) error {
	spec, err := pool.ParseSpec(value)
	if err != nil {
		return err
	}
	*p = append(*p, spec)
	return nil
}

type roleFlags []RoleSpec

func (r *roleFlags) String() string { return fmt.Sprint(*r) }

func (r *roleFlags) Set(value string) error {
	spec, err := ParseRole(value)
	if err != nil {
		return err
	}
	*r = append(*r, spec)
	return nil
}

// Usage is the command line `serve` accepts.
const Usage = "cyfr-locus serve --role <name>:<uid>:<port>:<pool>[:private][:kept] [--role …] --pool <name>:<first>-<last>:<relay|routed> [--pool …] --home-root <dir> [--kept-homes <dir>:<first>-<last>] --guard <socket> -- <command> [args…]"

// ParseArgs parses the arguments after `serve`. Pools and roles may repeat:
// pools with distinct names and disjoint ranges, roles with distinct names,
// uids and ports, each role's uid outside every pool and the kept range,
// and each pool named by exactly one role. At most one role is kept, and it
// names a routed pool; --kept-homes is given exactly when one is. At most
// one role keeps the floor.
func ParseArgs(args []string) (Config, error) {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var cfg Config
	var pools poolFlags
	var roles roleFlags
	fs.Var(&roles, "role", "a role process, <name>:<uid>:<port>:<pool>[:private][:kept]")
	fs.Var(&pools, "pool", "a uid pool and its spaces' reach, <name>:<first>-<last>:<relay|routed>")
	fs.StringVar(&cfg.HomeRoot, "home-root", "", "directory holding a folder of each role's spawns' homes")
	var kept string
	fs.StringVar(&kept, "kept-homes", "", "the kept-homes root and the uids its homes own, <dir>:<first>-<last>")
	fs.StringVar(&cfg.Guard, "guard", "", "the socket of the island's egress guard's control")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	if kept != "" {
		k, err := home.ParseKept(kept)
		if err != nil {
			return Config{}, err
		}
		cfg.Kept = &k
	}
	cfg.Pools = pools
	cfg.Roles = roles
	cfg.Command = fs.Args()
	if len(args) < len(cfg.Command)+1 || args[len(args)-len(cfg.Command)-1] != "--" {
		return Config{}, errors.New("the roles' command must follow --")
	}

	if len(cfg.Pools) == 0 {
		return Config{}, errors.New("at least one --pool is required")
	}
	for i, a := range cfg.Pools {
		for _, b := range cfg.Pools[:i] {
			if a.Name == b.Name {
				return Config{}, fmt.Errorf("pool %s is named twice", a.Name)
			}
			if a.Overlaps(b) {
				return Config{}, fmt.Errorf("pools %s and %s overlap", b.Name, a.Name)
			}
		}
	}
	if err := checkRoles(cfg); err != nil {
		return Config{}, err
	}
	if !filepath.IsAbs(cfg.HomeRoot) || filepath.Clean(cfg.HomeRoot) != cfg.HomeRoot {
		return Config{}, errors.New("--home-root must be a clean absolute path")
	}
	if k := cfg.Kept; k != nil {
		for _, p := range cfg.Pools {
			if k.First <= p.Last && p.First <= k.Last {
				return Config{}, fmt.Errorf("the kept-home uids %d-%d overlap pool %s", k.First, k.Last, p.Name)
			}
		}
		if k.Root == cfg.HomeRoot || strings.HasPrefix(k.Root, cfg.HomeRoot+"/") || strings.HasPrefix(cfg.HomeRoot, k.Root+"/") {
			return Config{}, errors.New("--kept-homes and --home-root must not hold one another")
		}
	}
	if cfg.Guard == "" {
		return Config{}, errors.New("every role's space is routed through its island's guard: --guard is required")
	}
	if !filepath.IsAbs(cfg.Guard) || filepath.Clean(cfg.Guard) != cfg.Guard {
		return Config{}, errors.New("--guard must be a clean absolute path")
	}
	if len(cfg.Command) == 0 || cfg.Command[0] == "" {
		return Config{}, errors.New("the roles' command is required after --")
	}
	return cfg, nil
}

// checkRoles refuses roles that are not each their own: see ParseArgs.
func checkRoles(cfg Config) error {
	if len(cfg.Roles) == 0 {
		return errors.New("at least one --role is required")
	}
	var kept *RoleSpec
	for i, r := range cfg.Roles {
		for _, other := range cfg.Roles[:i] {
			switch {
			case r.Name == other.Name:
				return fmt.Errorf("role %s is named twice", r.Name)
			case r.UID == other.UID:
				return fmt.Errorf("roles %s and %s share uid %d", other.Name, r.Name, r.UID)
			case r.Port == other.Port:
				return fmt.Errorf("roles %s and %s share port %d", other.Name, r.Name, r.Port)
			case r.Pool == other.Pool:
				return fmt.Errorf("roles %s and %s share pool %s", other.Name, r.Name, r.Pool)
			}
		}
		spec, known := poolOf(cfg.Pools, r.Pool)
		if !known {
			return fmt.Errorf("role %s names pool %s, which no --pool declares", r.Name, r.Pool)
		}
		for _, p := range cfg.Pools {
			if p.Contains(r.UID) {
				return fmt.Errorf("pool %s contains role %s's uid %d", p.Name, r.Name, r.UID)
			}
		}
		if k := cfg.Kept; k != nil && k.Contains(r.UID) {
			return fmt.Errorf("the kept-home uids %d-%d hold role %s's uid %d", k.First, k.Last, r.Name, r.UID)
		}
		if r.Floor {
			for _, other := range cfg.Roles[:i] {
				if other.Floor {
					return fmt.Errorf("roles %s and %s both keep the floor", other.Name, r.Name)
				}
			}
		}
		if r.Kept {
			if kept != nil {
				return fmt.Errorf("roles %s and %s are both kept", kept.Name, r.Name)
			}
			if !spec.Routed() {
				return fmt.Errorf("role %s is kept and its pool %s is not routed: a program's session leaves through its island's guard", r.Name, r.Pool)
			}
			kept = &cfg.Roles[i]
		}
	}
	for _, p := range cfg.Pools {
		if !slices.ContainsFunc(cfg.Roles, func(r RoleSpec) bool { return r.Pool == p.Name }) {
			return fmt.Errorf("pool %s is named by no --role", p.Name)
		}
	}
	switch {
	case kept != nil && cfg.Kept == nil:
		return fmt.Errorf("role %s is kept and no --kept-homes is given", kept.Name)
	case kept == nil && cfg.Kept != nil:
		return errors.New("--kept-homes is given and no role is kept")
	}
	return nil
}

// poolOf is the pool of pools named name.
func poolOf(pools []pool.Spec, name string) (pool.Spec, bool) {
	for _, spec := range pools {
		if spec.Name == name {
			return spec, true
		}
	}
	return pool.Spec{}, false
}

// Routed reports whether some pool is routed.
func (c Config) Routed() bool {
	for _, spec := range c.Pools {
		if spec.Routed() {
			return true
		}
	}
	return false
}

// Account is a resolved user.
type Account struct {
	UID  int
	GID  int
	Name string
	Home string
}

// Lookup resolves users; os/user in production.
type Lookup struct {
	ByName func(name string) (*user.User, error)
	ByID   func(uid string) (*user.User, error)
}

// SystemLookup reads the system user database.
var SystemLookup = Lookup{ByName: user.Lookup, ByID: user.LookupId}

// ResolveAccounts resolves each role's account and every pooled uid. A
// role's account is its uid, as its gid, under its user name (RoleSpec.User):
// a user entry of that uid must say the same. A pooled uid without a user
// entry is named by its number and takes its own number as gid. Every
// pooled gid must be distinct, non-root and no role's, so no spawned
// process shares a group with another or with a role.
func ResolveAccounts(cfg Config, lookup Lookup) ([]Account, map[int]Account, error) {
	roles := make([]Account, len(cfg.Roles))
	roleGIDs := map[int]string{}
	for i, r := range cfg.Roles {
		acct := Account{UID: r.UID, GID: r.UID, Name: r.User()}
		if u, err := lookup.ByID(strconv.Itoa(r.UID)); err == nil {
			found, err := toAccount(u)
			if err != nil {
				return nil, nil, fmt.Errorf("role %s's uid %d: %w", r.Name, r.UID, err)
			}
			if found.Name != acct.Name || found.GID != acct.GID {
				return nil, nil, fmt.Errorf("role %s's uid %d is the user %s of gid %d, not %s of gid %d", r.Name, r.UID, found.Name, found.GID, acct.Name, acct.GID)
			}
		}
		roles[i] = acct
		roleGIDs[acct.GID] = r.Name
	}

	accounts := map[int]Account{}
	gids := map[int]int{}
	for _, spec := range cfg.Pools {
		for uid := spec.First; uid <= spec.Last; uid++ {
			acct := Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
			if u, err := lookup.ByID(strconv.Itoa(uid)); err == nil {
				if acct, err = toAccount(u); err != nil {
					return nil, nil, fmt.Errorf("uid %d: %w", uid, err)
				}
			}
			if role, taken := roleGIDs[acct.GID]; acct.GID == 0 || taken {
				return nil, nil, fmt.Errorf("uid %d has gid %d, which is root's or role %s's", uid, acct.GID, role)
			}
			if other, taken := gids[acct.GID]; taken {
				return nil, nil, fmt.Errorf("uids %d and %d share gid %d", other, uid, acct.GID)
			}
			gids[acct.GID] = uid
			accounts[uid] = acct
		}
	}
	if k := cfg.Kept; k != nil {
		if err := checkKeptUIDs(*k, roleGIDs, gids, lookup); err != nil {
			return nil, nil, err
		}
	}
	return roles, accounts, nil
}

// KeptAccount is the account a kept home's uid runs as: no user entry, its
// own number as its name and as its gid.
func KeptAccount(uid int) Account {
	return Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
}

// checkKeptUIDs refuses a kept-home range that holds a role's gid, a pooled
// gid, or a uid with a user entry: a kept home's uid runs as KeptAccount, so
// its gid is its own number, which no other account may hold.
func checkKeptUIDs(k home.Kept, roleGIDs map[int]string, poolGIDs map[int]int, lookup Lookup) error {
	for gid, role := range roleGIDs {
		if k.Contains(gid) {
			return fmt.Errorf("the kept-home uids %d-%d hold role %s's gid %d", k.First, k.Last, role, gid)
		}
	}
	for gid := range poolGIDs {
		if k.Contains(gid) {
			return fmt.Errorf("the kept-home uids %d-%d hold the pooled gid %d", k.First, k.Last, gid)
		}
	}
	for uid := k.First; uid <= k.Last; uid++ {
		if _, err := lookup.ByID(strconv.Itoa(uid)); err == nil {
			return fmt.Errorf("kept-home uid %d has a user entry; the range must lie outside the user database", uid)
		}
	}
	return nil
}

// toAccount refuses a record whose uid or gid is not a Linux id, 0 to
// (uid_t)-2: the launchers narrow an Account's ids into a uint32 process
// credential, so a larger value would run as an id no policy here checked,
// and (uid_t)-1 means "unchanged" to setresuid and setresgid.
func toAccount(u *user.User) (Account, error) {
	uid, err := parseID(u.Uid)
	if err != nil {
		return Account{}, fmt.Errorf("uid %w", err)
	}
	gid, err := parseID(u.Gid)
	if err != nil {
		return Account{}, fmt.Errorf("gid %w", err)
	}
	return Account{UID: uid, GID: gid, Name: u.Username, Home: u.HomeDir}, nil
}

// int holds every id parseID answers: this constant does not compile where
// it cannot (a 32-bit build), so no build converts an id into a wrapped int.
const _ = uint(math.MaxInt - protocol.MaxUID)

func parseID(s string) (int, error) {
	n, err := strconv.ParseUint(s, 10, 32)
	if err != nil || n > protocol.MaxUID {
		return 0, fmt.Errorf("%q is not an id from 0 to %d", s, uint64(protocol.MaxUID))
	}
	// n is at most protocol.MaxUID, which int holds (the constant above).
	return int(n), nil
}

// EnvPrefix is the prefix of the keeper's own variable names.
const EnvPrefix = "KEEPER_"

// DeclaredEnv are the KEEPER_ names the keeper knows: ChannelEnv and
// RunDirEnv, which it sets for each role; an inherited value is replaced,
// never read (RoleEnviron).
var DeclaredEnv = []string{protocol.ChannelEnv, protocol.RunDirEnv}

// CheckEnviron is the one reader of the keeper's KEEPER_ environment: it
// refuses every KEEPER_ name DeclaredEnv does not hold, naming each, so a
// misspelled or retired setting stops the start instead of being ignored.
// The error never carries a value.
func CheckEnviron(environ []string) error {
	var unknown []string
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(name, EnvPrefix) && !slices.Contains(DeclaredEnv, name) {
			unknown = append(unknown, name)
		}
	}
	if len(unknown) == 0 {
		return nil
	}
	slices.Sort(unknown)
	return fmt.Errorf("%s: not a variable cyfr-locus reads (it knows %s)",
		strings.Join(slices.Compact(unknown), ", "), strings.Join(DeclaredEnv, ", "))
}

// releaseEnv are the image's locale, release and toolchain variables every
// role process is given as the keeper has them: rustup and cargo find the
// image's toolchains by RUSTUP_HOME and CARGO_HOME, and a role's HOME is
// its run folder, which holds none.
var releaseEnv = []string{"LANG", "LANGUAGE", "LC_ALL", "ELIXIR_ERL_OPTIONS", "RELEASE_DISTRIBUTION", "PATH", "RUSTUP_HOME", "CARGO_HOME"}

// cpuLimitEnv is the keeper's alone: a role's processors, which its groups
// hold and the role never reads.
const cpuLimitEnv = "CPU_LIMIT"

// RoleEnviron is a role process's whole environment, built from nothing:
// releaseEnv's variables as environ has them, every variable of the role's
// own (LOCUS_<NAME>_…, its key among them) but its processors, every LOCUS_LOG_
// variable, RELEASE_TMP and HOME naming its run folder, ChannelEnv naming
// its channel socket and RunDirEnv its run folder. No other role's variable
// reaches it.
func RoleEnviron(environ []string, r RoleSpec, runDir, channel string) map[string]string {
	env := map[string]string{}
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		own, isOwn := strings.CutPrefix(name, r.envPrefix())
		switch {
		case slices.Contains(releaseEnv, name), strings.HasPrefix(name, "LOCUS_LOG_"):
		case isOwn && own != cpuLimitEnv:
		default:
			continue
		}
		env[name] = value
	}
	env["RELEASE_TMP"] = runDir
	env["HOME"] = runDir
	env[protocol.ChannelEnv] = channel
	env[protocol.RunDirEnv] = runDir
	return env
}

// Keyed reports whether environ holds the role's key, not empty.
func Keyed(environ []string, r RoleSpec) bool {
	for _, kv := range environ {
		if name, value, _ := strings.Cut(kv, "="); name == r.KeyEnv() && value != "" {
			return true
		}
	}
	return false
}

var (
	cpusPattern = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+)?$`)
)

// RoleCPU reads the role's processors from environ, as Compose reads a
// container's: LOCUS_<NAME>_CPU_LIMIT, a number of processors such as 2 or
// 0.5, at least two hundredths of one, answered in microseconds of every
// cgroup.CPUPeriod: the role's service and its work each take half of the
// least, and the kernel takes no cpu.max quota under 1000 microseconds. Absent or empty is no bound, zero; anything else is
// refused by its name, never its value.
func RoleCPU(environ []string, r RoleSpec) (uint64, error) {
	var quota uint64
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		if value == "" || name != r.envPrefix()+cpuLimitEnv {
			continue
		}
		cpus, ok := new(big.Rat), cpusPattern.MatchString(value)
		if ok {
			_, ok = cpus.SetString(value)
		}
		q := new(big.Rat)
		if ok {
			q.Mul(cpus, new(big.Rat).SetInt64(cgroup.CPUPeriod))
			ok = q.IsInt() && q.Num().IsUint64() && q.Num().Uint64() >= 2*cgroup.CPUPeriod/100
		}
		if !ok {
			return 0, fmt.Errorf("%s is not a number of processors of at least 0.02 in hundred-thousandths, such as 2 or 0.5", name)
		}
		quota = q.Num().Uint64()
	}
	return quota, nil
}

// The pool's two numbers, the keeper's alone (no role reads them): the
// memory kept for core beside Locus, or for the host itself, and the
// services' share, each a count of bytes. Absent or empty is 0.
const (
	ReserveEnv = "LOCUS_CORE_RESERVE_BYTES"
	ShareEnv   = "LOCUS_SERVICE_BYTES"
)

// PoolMemory reads the reserve and the share from environ: each a decimal
// count of bytes, absent or empty 0, anything else refused by its name.
func PoolMemory(environ []string) (reserve, share uint64, err error) {
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		if value == "" || (name != ReserveEnv && name != ShareEnv) {
			continue
		}
		bytes, perr := strconv.ParseUint(value, 10, 64)
		if perr != nil || value != strconv.FormatUint(bytes, 10) || bytes > 1<<50 {
			return 0, 0, fmt.Errorf("%s is not a count of bytes, such as 2415919104", name)
		}
		if name == ReserveEnv {
			reserve = bytes
		} else {
			share = bytes
		}
	}
	return reserve, share, nil
}

// PoolAccounts is the set of pooled uids and gids.
func PoolAccounts(accounts map[int]Account) residue.Accounts {
	set := residue.Accounts{UIDs: map[int]bool{}, GIDs: map[int]bool{}}
	for uid, acct := range accounts {
		set.UIDs[uid] = true
		set.GIDs[acct.GID] = true
	}
	return set
}
