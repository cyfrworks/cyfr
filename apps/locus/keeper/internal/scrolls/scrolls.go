// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package scrolls is where a session's space holds the packs its person
// switched on, read only: the stage binds the person's pack generation
// there, and a brain driver lists the folders it finds there. It is a
// package of its own so that a driver, which runs inside the person's
// space, links this name and none of the keeper's stage.
package scrolls

// Path is where a space sees its person's packs, one folder for each.
const Path = "/run/cyfr/scrolls"
