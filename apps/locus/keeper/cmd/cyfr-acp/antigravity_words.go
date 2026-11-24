// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

// Antigravity's own names for where it keeps its sessions, word for word,
// since the driver removes and looks for those files by them: the
// program's words, not CYFR's, held in this one file alone.
const (
	// agySessionDatabases is the folder of each session's database.
	agySessionDatabases = "conversations"
	// agySummaryIndex is the program's one index of every session's title
	// and summary, which CYFR never writes.
	agySummaryIndex = "conversation_summaries.db"
)
