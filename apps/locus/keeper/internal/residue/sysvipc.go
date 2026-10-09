// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package residue

import (
	"bufio"
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

// IPC names one System V IPC object.
type IPC struct {
	// Kind is "shm", "sem" or "msg", the name of its /proc/sysvipc table.
	Kind string
	// ID is the object's identifier.
	ID int
}

// IPCKinds are the System V IPC tables, in the order they are cleared.
var IPCKinds = []string{"shm", "sem", "msg"}

var idColumn = map[string]string{"shm": "shmid", "sem": "semid", "msg": "msqid"}

// ParseSysvipc returns the objects of one /proc/sysvipc table whose owner or
// creator is uid. Either may remove the object; the owner can be changed
// with IPC_SET, the creator cannot.
func ParseSysvipc(kind string, data []byte, uid int) ([]IPC, error) {
	idName, ok := idColumn[kind]
	if !ok {
		return nil, fmt.Errorf("sysvipc: unknown table %q", kind)
	}
	sc := bufio.NewScanner(bytes.NewReader(data))
	if !sc.Scan() {
		return nil, sc.Err()
	}
	columns := map[string]int{}
	for i, name := range strings.Fields(sc.Text()) {
		columns[name] = i
	}
	idAt, uidAt, cuidAt := column(columns, idName), column(columns, "uid"), column(columns, "cuid")
	if idAt < 0 || uidAt < 0 || cuidAt < 0 {
		return nil, fmt.Errorf("sysvipc %s: header lacks %s, uid or cuid", kind, idName)
	}
	var out []IPC
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 0 {
			continue
		}
		values := make([]int, 3)
		for i, at := range []int{idAt, uidAt, cuidAt} {
			if at >= len(fields) {
				return nil, fmt.Errorf("sysvipc %s: short line %q", kind, sc.Text())
			}
			n, err := strconv.Atoi(fields[at])
			if err != nil {
				return nil, fmt.Errorf("sysvipc %s: %q is not a number", kind, fields[at])
			}
			values[i] = n
		}
		if values[1] == uid || values[2] == uid {
			out = append(out, IPC{Kind: kind, ID: values[0]})
		}
	}
	return out, sc.Err()
}

func column(columns map[string]int, name string) int {
	if i, ok := columns[name]; ok {
		return i
	}
	return -1
}
