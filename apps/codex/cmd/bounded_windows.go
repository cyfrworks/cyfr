// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"fmt"
	"os/exec"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// createNewProcessGroup keeps a console's ^C, which reaches this cyfr,
// from reaching the child.
const createNewProcessGroup = 0x00000200

var ntResumeProcess = windows.NewLazySystemDLL("ntdll.dll").NewProc("NtResumeProcess")

// runWithin runs cmd to its end, or for at most within: a Job Object holds
// it and all it starts, created suspended and resumed only inside the job
// so nothing it starts escapes, and closed with this cyfr however it ends.
// At the bound the whole job is ended. A run the bound ended answers
// errOverran, never its own status.
func runWithin(within time.Duration, cmd *exec.Cmd) error {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE},
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		return err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup | windows.CREATE_SUSPENDED}
	cmd.WaitDelay = boundGrace
	if err := cmd.Start(); err != nil {
		return err
	}
	if err := joinAndResume(job, cmd.Process.Pid); err != nil {
		_ = windows.TerminateJobObject(job, 1)
		_ = cmd.Wait()
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	bound := time.NewTimer(within)
	defer bound.Stop()
	select {
	case err := <-done:
		return err
	case <-bound.C:
	}
	_ = windows.TerminateJobObject(job, 1)
	<-done
	return fmt.Errorf("%w %v", errOverran, within)
}

// joinAndResume assigns the suspended process pid to job, then resumes it.
func joinAndResume(job windows.Handle, pid int) error {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_SUSPEND_RESUME|windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	if err := windows.AssignProcessToJobObject(job, h); err != nil {
		return err
	}
	if status, _, _ := ntResumeProcess.Call(uintptr(h)); status != 0 {
		return fmt.Errorf("resume the process: NTSTATUS 0x%x", status)
	}
	return nil
}
