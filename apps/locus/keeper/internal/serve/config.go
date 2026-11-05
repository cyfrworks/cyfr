// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package serve is `cyfr-locus serve`: it checks its own privileges, starts
// the client command as the client user with a socketpair on fd 3, and
// answers the client's requests (package protocol) by starting, signalling
// and retiring processes under pooled uids.
package serve

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/residue"
)

// Config is the parsed command line.
type Config struct {
	Pools      []pool.Spec
	HomeRoot   string
	ClientUser string
	ClientArgv []string
	// Kept is the kept-homes root and uid range, nil for a keeper that
	// keeps no homes.
	Kept *home.Kept
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

// Usage is the command line `serve` accepts.
const Usage = "cyfr-locus serve --pool <name>:<first>-<last>[:netns] [--pool …] --home-root <dir> [--kept-homes <dir>:<first>-<last>] --client-user <user> -- <command> [args…]"

// ParseArgs parses the arguments after `serve`. Pools may repeat but must
// have distinct names and disjoint ranges.
func ParseArgs(args []string) (Config, error) {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var cfg Config
	var pools poolFlags
	fs.Var(&pools, "pool", "a uid pool, <name>:<first>-<last>, isolated with :netns")
	fs.StringVar(&cfg.HomeRoot, "home-root", "", "directory holding the spawned processes' homes")
	fs.StringVar(&cfg.ClientUser, "client-user", "", "user the client command runs as")
	var kept string
	fs.StringVar(&kept, "kept-homes", "", "the kept-homes root and the uids its homes own, <dir>:<first>-<last>")
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
	cfg.ClientArgv = fs.Args()
	if len(args) < len(cfg.ClientArgv)+1 || args[len(args)-len(cfg.ClientArgv)-1] != "--" {
		return Config{}, errors.New("the client command must follow --")
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
	if cfg.ClientUser == "" {
		return Config{}, errors.New("--client-user is required")
	}
	if len(cfg.ClientArgv) == 0 || cfg.ClientArgv[0] == "" {
		return Config{}, errors.New("a client command is required after --")
	}
	return cfg, nil
}

// Isolating reports whether some pool is isolated, so the keeper must be
// able to clone a user and network namespace before it serves.
func (c Config) Isolating() bool {
	for _, spec := range c.Pools {
		if spec.Isolated {
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

// ResolveAccounts resolves the client user and every pooled uid. A pooled
// uid without a user entry is named by its number and takes its own number
// as gid. The client and every pooled uid must be non-root, no pooled uid
// may be the client's, and every pooled gid must be distinct, non-root and
// not the client's, so no spawned process shares a group with another or
// with the client.
func ResolveAccounts(cfg Config, lookup Lookup) (Account, map[int]Account, error) {
	u, err := lookup.ByName(cfg.ClientUser)
	if err != nil {
		return Account{}, nil, fmt.Errorf("client user %s: %w", cfg.ClientUser, err)
	}
	client, err := toAccount(u)
	if err != nil {
		return Account{}, nil, fmt.Errorf("client user %s: %w", cfg.ClientUser, err)
	}
	if client.UID == 0 || client.GID == 0 {
		return Account{}, nil, fmt.Errorf("client user %s must not be root or in group 0", cfg.ClientUser)
	}

	accounts := map[int]Account{}
	gids := map[int]int{}
	for _, spec := range cfg.Pools {
		if spec.Contains(client.UID) {
			return Account{}, nil, fmt.Errorf("pool %s contains the client uid %d", spec.Name, client.UID)
		}
		for uid := spec.First; uid <= spec.Last; uid++ {
			acct := Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
			if u, err := lookup.ByID(strconv.Itoa(uid)); err == nil {
				if acct, err = toAccount(u); err != nil {
					return Account{}, nil, fmt.Errorf("uid %d: %w", uid, err)
				}
			}
			if acct.GID == 0 || acct.GID == client.GID {
				return Account{}, nil, fmt.Errorf("uid %d has gid %d, which is root's or the client's", uid, acct.GID)
			}
			if other, taken := gids[acct.GID]; taken {
				return Account{}, nil, fmt.Errorf("uids %d and %d share gid %d", other, uid, acct.GID)
			}
			gids[acct.GID] = uid
			accounts[uid] = acct
		}
	}
	if k := cfg.Kept; k != nil {
		if err := checkKeptUIDs(*k, client, gids, lookup); err != nil {
			return Account{}, nil, err
		}
	}
	return client, accounts, nil
}

// KeptAccount is the account a kept home's uid runs as: no user entry, its
// own number as its name and as its gid.
func KeptAccount(uid int) Account {
	return Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
}

// checkKeptUIDs refuses a kept-home range that holds the client's uid or
// gid, a pooled gid, or a uid with a user entry: a kept home's uid runs as
// KeptAccount, so its gid is its own number, which no other account may
// hold.
func checkKeptUIDs(k home.Kept, client Account, poolGIDs map[int]int, lookup Lookup) error {
	if k.Contains(client.UID) || k.Contains(client.GID) {
		return fmt.Errorf("the kept-home uids %d-%d hold the client's uid or gid", k.First, k.Last)
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

func toAccount(u *user.User) (Account, error) {
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return Account{}, fmt.Errorf("uid %q is not numeric", u.Uid)
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return Account{}, fmt.Errorf("gid %q is not numeric", u.Gid)
	}
	return Account{UID: uid, GID: gid, Name: u.Username, Home: u.HomeDir}, nil
}

// EnvPrefix is the prefix of the keeper's own variable names.
const EnvPrefix = "KEEPER_"

// DeclaredEnv are the KEEPER_ names the keeper knows. ChannelEnv and
// KeptHomesEnv are the ones it sets for its client; an inherited value is
// replaced, never read (ClientEnviron).
var DeclaredEnv = []string{protocol.ChannelEnv, protocol.KeptHomesEnv}

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

// ClientEnviron is the client's environment: the keeper's own, with HOME,
// USER and LOGNAME describing the client user, protocol.ChannelEnv naming
// the channel socket on fd 3 and, for a keeper that keeps homes,
// protocol.KeptHomesEnv naming the kept-homes root and uid range.
func ClientEnviron(environ []string, client Account, channel string, kept *home.Kept) []string {
	out := make([]string, 0, len(environ)+5)
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case "HOME", "USER", "LOGNAME", protocol.ChannelEnv, protocol.KeptHomesEnv:
			continue
		}
		out = append(out, kv)
	}
	dir := client.Home
	if dir == "" {
		dir = "/"
	}
	out = append(out, "HOME="+dir, "USER="+client.Name, "LOGNAME="+client.Name, protocol.ChannelEnv+"="+channel)
	if kept != nil {
		out = append(out, protocol.KeptHomesEnv+"="+kept.String())
	}
	return out
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
