// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package serve is `cyfr-keeper serve`: it checks its own privileges, starts
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
	"strconv"
	"strings"

	"github.com/cyfr/keeper/internal/pool"
	"github.com/cyfr/keeper/internal/protocol"
	"github.com/cyfr/keeper/internal/residue"
)

// Config is the parsed command line.
type Config struct {
	Pools      []pool.Spec
	HomeRoot   string
	ClientUser string
	ClientArgv []string
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
const Usage = "cyfr-keeper serve --pool <name>:<first>-<last> [--pool …] --home-root <dir> --client-user <user> -- <command> [args…]"

// ParseArgs parses the arguments after `serve`. Pools may repeat but must
// have distinct names and disjoint ranges.
func ParseArgs(args []string) (Config, error) {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var cfg Config
	var pools poolFlags
	fs.Var(&pools, "pool", "a uid pool, <name>:<first>-<last>")
	fs.StringVar(&cfg.HomeRoot, "home-root", "", "directory holding the spawned processes' homes")
	fs.StringVar(&cfg.ClientUser, "client-user", "", "user the client command runs as")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
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
	if cfg.ClientUser == "" {
		return Config{}, errors.New("--client-user is required")
	}
	if len(cfg.ClientArgv) == 0 || cfg.ClientArgv[0] == "" {
		return Config{}, errors.New("a client command is required after --")
	}
	return cfg, nil
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
	return client, accounts, nil
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

// ClientEnviron is the client's environment: the spawner's own, with HOME,
// USER and LOGNAME describing the client user and protocol.ChannelEnv
// naming the channel socket on fd 3.
func ClientEnviron(environ []string, client Account, channel string) []string {
	out := make([]string, 0, len(environ)+4)
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case "HOME", "USER", "LOGNAME", protocol.ChannelEnv:
			continue
		}
		out = append(out, kv)
	}
	home := client.Home
	if home == "" {
		home = "/"
	}
	return append(out, "HOME="+home, "USER="+client.Name, "LOGNAME="+client.Name, protocol.ChannelEnv+"="+channel)
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
