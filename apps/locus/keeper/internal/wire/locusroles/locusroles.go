// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package locusroles is the runtime role's row of Prima.LocusRoles in Go:
// the facts of the one role the Go runtime service is, which the core,
// the image and the keeper's flags agree on. Prima's module is the one
// definition, and tests/fixtures/locus_roles.json holds this package to
// its runtime row, every member of it. The builds and backends roles stay
// Elixir's, and the release's facts are the compose file's and the
// image's: no Go role reads them.
package locusroles

// Role is the runtime role's row of the role table, as locus_roles.json
// spells it: a member the runtime does not have is null there and a nil
// pointer here. The other roles' rows are Elixir's; Role does not read
// them.
type Role struct {
	// Name is the role's name, and Key the variable whose key starts it.
	Name string `json:"name"`
	Key  string `json:"key"`
	// User and UID are the account its process runs as, its gid the same.
	User string `json:"user"`
	UID  int    `json:"uid"`
	// Port is its listener's port.
	Port int `json:"port"`
	// Private is whether its spawns' spaces reach private addresses and
	// the core's host API; Floor whether its runners are the warm floor's.
	Private bool `json:"private"`
	Floor   bool `json:"floor"`
	// RunDir and RunSize are its run folder and the size of its tmpfs;
	// HomeRoot and HomeSize its spawns' homes' root and theirs.
	RunDir   string `json:"run_dir"`
	RunSize  string `json:"run_size"`
	HomeRoot string `json:"home_root"`
	HomeSize string `json:"home_size"`
	// Pool is its uid pool, UserPrefix its pooled users' names' prefix,
	// FirstUID and LastUID its first and last pooled uid, and Reach its
	// spawns' spaces' reach, the keeper's --pool suffix.
	Pool       string `json:"pool"`
	UserPrefix string `json:"user_prefix"`
	FirstUID   int    `json:"first_uid"`
	LastUID    int    `json:"last_uid"`
	Reach      string `json:"reach"`
	// The kept folders of a role whose programs keep theirs, and the
	// machines' folder of a role whose sessions run in a person's
	// machine: none for the runtime.
	KeptRoot     *string `json:"kept_root"`
	KeptVolume   *string `json:"kept_volume"`
	KeptFirstUID *int    `json:"kept_first_uid"`
	KeptLastUID  *int    `json:"kept_last_uid"`
	KeptGroup    *string `json:"kept_group"`
	KeptGID      *int    `json:"kept_gid"`
	GuestRoot    *string `json:"guest_root"`
	GuestVolume  *string `json:"guest_volume"`
	// Memory is what the role's process holds of its own.
	Memory Memory `json:"memory"`
}

// Memory is a role's own holdings: its counted bounds (Unread, none for a
// role that keeps none, and Answering, the one count its answers draw on)
// and the runtime's uncounted figures (one pinned fetch's transport read,
// the larger read a fetch takes with its count's room, the most of a
// fetch's head the HTTP client reads, the freed segments its VM keeps).
type Memory struct {
	Unread              *uint64 `json:"unread"`
	Answering           uint64  `json:"answering"`
	FetchReadBytes      uint64  `json:"fetch_read_bytes"`
	FetchReadAheadBytes uint64  `json:"fetch_read_ahead_bytes"`
	FetchHeadBytes      uint64  `json:"fetch_head_bytes"`
	FreedSegmentsBytes  uint64  `json:"freed_segments_bytes"`
}

// Runtime is the runtime role.
var Runtime = Role{
	Name:       "runtime",
	Key:        "LOCUS_RUNTIME_KEY",
	User:       "locus-runtime",
	UID:        10011,
	Port:       4200,
	Private:    true,
	Floor:      true,
	RunDir:     "/run/locus/runtime",
	RunSize:    "16m",
	HomeRoot:   "/var/lib/locus/homes/runtime",
	HomeSize:   "256m",
	Pool:       "runner",
	UserPrefix: "locus-runner",
	FirstUID:   30101,
	LastUID:    30108,
	Reach:      "relay",
	Memory: Memory{
		Answering:           16777216,
		FetchReadBytes:      65536,
		FetchReadAheadBytes: 262144,
		FetchHeadBytes:      262144,
		FreedSegmentsBytes:  69905080,
	},
}
