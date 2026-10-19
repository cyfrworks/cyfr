// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package reach

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// run runs docker in a Job Object of its own, created with
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: the job's one handle is cyfr's, so
// when cyfr dies, however it dies, the kernel closes it and kills docker
// and everything docker started. The child starts suspended and runs only
// once it is in the job, so nothing it starts escapes. The deadline, a
// cancelled ctx and the call's end each terminate the whole job.
func (s *systemDocker) run(ctx context.Context, bin string, args []string, deadline time.Duration, streams func(*exec.Cmd)) (int, error) {
	job, err := newKillOnCloseJob()
	if err != nil {
		return -1, err
	}
	defer windows.CloseHandle(job)

	cmd := exec.Command(bin, args...)
	streams(cmd)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup | windows.CREATE_SUSPENDED}
	cmd.WaitDelay = waitGrace
	if err := cmd.Start(); err != nil {
		return -1, err
	}
	if err := joinAndResume(job, cmd.Process.Pid); err != nil {
		windows.TerminateJobObject(job, 1)
		cmd.Process.Kill()
		cmd.Wait()
		return -1, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	timer := time.NewTimer(deadline)
	defer timer.Stop()
	hit := false
	select {
	case err = <-done:
	case <-timer.C:
		windows.TerminateJobObject(job, watchdogDeadline)
		hit = true
		err = <-done
	case <-ctx.Done():
		windows.TerminateJobObject(job, 1)
		err = <-done
		return -1, errors.Join(ctx.Err(), err)
	}
	return exitStatus(err, hit)
}

// newKillOnCloseJob creates a Job Object whose processes die when its
// last handle closes.
func newKillOnCloseJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, fmt.Errorf("reach: create the docker job: %w", err)
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE},
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return 0, fmt.Errorf("reach: limit the docker job: %w", err)
	}
	return job, nil
}

var ntResumeProcess = windows.NewLazySystemDLL("ntdll.dll").NewProc("NtResumeProcess")

// joinAndResume assigns the suspended process pid to job, then resumes
// it.
func joinAndResume(job windows.Handle, pid int) error {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_SUSPEND_RESUME|windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return fmt.Errorf("reach: open the docker process: %w", err)
	}
	defer windows.CloseHandle(h)
	if err := windows.AssignProcessToJobObject(job, h); err != nil {
		return fmt.Errorf("reach: put docker in its job: %w", err)
	}
	if status, _, _ := ntResumeProcess.Call(uintptr(h)); status != 0 {
		return fmt.Errorf("reach: resume docker: NTSTATUS 0x%x", status)
	}
	return nil
}
