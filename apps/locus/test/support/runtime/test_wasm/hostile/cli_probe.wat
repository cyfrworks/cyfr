;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A guest that tries what WASI's command-line interfaces hand a program:
;; it reads up to 1,024 bytes of its standard input, writes its input and
;; then a newline to its standard output and again to its standard error,
;; and reads its arguments and its environment. It answers
;; {"stdin":S,"stdout":W,"stderr":W,"args":A,"env":E}: S the number of
;; bytes read, or "closed" or "failed", the stream's error; each W the
;; outcome of the write of its input, "ok", "closed" or "failed"; A and E
;; the number of arguments and of environment variables. A run is given
;; WASI with no standard input or output, arguments or environment, so a
;; run answers {"stdin":"closed","stdout":"ok","stderr":"ok","args":0,
;; "env":0}: what it writes is taken and goes nowhere. It exports its one
;; function as a reagent's `compute` and a catalyst's and a formula's
;; `run`, so every type runs it.
;;
;; `$libc` holds the memory and a bump allocator, which the lowered
;; imports that hand back a list allocate through. Each stream call's
;; result is written at a return area: the result's case byte at +0 (0 for
;; ok), then for a read's ok its list's pointer and length at +4 and +8,
;; and for an error the stream error's case byte at +4 (0
;; last-operation-failed, 1 closed). A component text, built by `build.sh`
;; (README.md).
(component
  (import "wasi:io/error@0.2.0" (instance $error
    (export "error" (type (sub resource)))))
  (alias export $error "error" (type $error-type))
  (import "wasi:io/streams@0.2.0" (instance $streams
    (alias outer 1 $error-type (type $e))
    (export "error" (type $err (eq $e)))
    (export "input-stream" (type $in (sub resource)))
    (export "output-stream" (type $out (sub resource)))
    (type $stream-error (variant (case "last-operation-failed" (own $err)) (case "closed")))
    (export "stream-error" (type $se (eq $stream-error)))
    (export "[method]input-stream.blocking-read"
      (func (param "self" (borrow $in)) (param "len" u64) (result (result (list u8) (error $se)))))
    (export "[method]output-stream.blocking-write-and-flush"
      (func (param "self" (borrow $out)) (param "contents" (list u8)) (result (result (error $se)))))))
  (alias export $streams "input-stream" (type $input-stream))
  (alias export $streams "output-stream" (type $output-stream))
  (import "wasi:cli/stdin@0.2.0" (instance $stdin
    (alias outer 1 $input-stream (type $i))
    (export "input-stream" (type $is (eq $i)))
    (export "get-stdin" (func (result (own $is))))))
  (import "wasi:cli/stdout@0.2.0" (instance $stdout
    (alias outer 1 $output-stream (type $o))
    (export "output-stream" (type $os (eq $o)))
    (export "get-stdout" (func (result (own $os))))))
  (import "wasi:cli/stderr@0.2.0" (instance $stderr
    (alias outer 1 $output-stream (type $o))
    (export "output-stream" (type $os (eq $o)))
    (export "get-stderr" (func (result (own $os))))))
  (import "wasi:cli/environment@0.2.0" (instance $environment
    (export "get-environment" (func (result (list (tuple string string)))))
    (export "get-arguments" (func (result (list string))))))

  (core module $libc
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 4096))
    (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
      (local $ptr i32)
      (local.set $ptr
        (i32.and
          (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
          (i32.sub (i32.const 0) (local.get $align))))
      (global.set $heap (i32.add (local.get $ptr) (local.get $new_size)))
      (local.get $ptr)))
  (core instance $libc (instantiate $libc))
  (core func $get-stdin (canon lower (func $stdin "get-stdin")))
  (core func $get-stdout (canon lower (func $stdout "get-stdout")))
  (core func $get-stderr (canon lower (func $stderr "get-stderr")))
  (core func $read
    (canon lower (func $streams "[method]input-stream.blocking-read")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))
  (core func $write
    (canon lower (func $streams "[method]output-stream.blocking-write-and-flush")
      (memory (core memory $libc "memory"))))
  (core func $get-environment
    (canon lower (func $environment "get-environment")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))
  (core func $get-arguments
    (canon lower (func $environment "get-arguments")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))

  (core module $m
    (import "libc" "memory" (memory 1))
    (import "cli" "get-stdin" (func $get-stdin (result i32)))
    (import "cli" "get-stdout" (func $get-stdout (result i32)))
    (import "cli" "get-stderr" (func $get-stderr (result i32)))
    (import "cli" "read" (func $read (param i32 i64 i32)))
    (import "cli" "write" (func $write (param i32 i32 i32 i32)))
    (import "cli" "get-environment" (func $get-environment (param i32)))
    (import "cli" "get-arguments" (func $get-arguments (param i32)))
    ;; The answer's pieces; it is written from 1024 on, below the heap.
    (data (i32.const 256) "{\22stdin\22:")
    (data (i32.const 272) ",\22stdout\22:")
    (data (i32.const 288) ",\22stderr\22:")
    (data (i32.const 304) ",\22args\22:")
    (data (i32.const 320) ",\22env\22:")
    (data (i32.const 336) "}")
    (data (i32.const 352) "\22closed\22")
    (data (i32.const 368) "\22failed\22")
    (data (i32.const 384) "\22ok\22")
    (data (i32.const 400) "\0a")
    (global $out (mut i32) (i32.const 1024))
    (func $append (param $at i32) (param $len i32)
      (memory.copy (global.get $out) (local.get $at) (local.get $len))
      (global.set $out (i32.add (global.get $out) (local.get $len))))
    ;; `n` in decimal.
    (func $number (param $n i32)
      (local $digits i32)
      (local $rest i32)
      (local $at i32)
      (local.set $digits (i32.const 1))
      (local.set $rest (local.get $n))
      (block $counted
        (loop $count
          (br_if $counted (i32.lt_u (local.get $rest) (i32.const 10)))
          (local.set $rest (i32.div_u (local.get $rest) (i32.const 10)))
          (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
          (br $count)))
      (local.set $at (i32.add (global.get $out) (local.get $digits)))
      (global.set $out (local.get $at))
      (loop $write
        (local.set $at (i32.sub (local.get $at) (i32.const 1)))
        (i32.store8 (local.get $at)
          (i32.add (i32.const 0x30) (i32.rem_u (local.get $n) (i32.const 10))))
        (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
        (br_if $write (i32.ne (local.get $n) (i32.const 0)))))
    ;; The stream error at `area`'s +4.
    (func $stream-error (param $area i32)
      (if (i32.eqz (i32.load8_u offset=4 (local.get $area)))
        (then (call $append (i32.const 368) (i32.const 8)))
        (else (call $append (i32.const 352) (i32.const 8)))))
    ;; The outcome of the write whose result is at `area`.
    (func $written (param $area i32)
      (if (i32.eqz (i32.load8_u (local.get $area)))
        (then (call $append (i32.const 384) (i32.const 4)))
        (else (call $stream-error (local.get $area)))))
    (func (export "compute") (param $input i32) (param $length i32) (result i32)
      (local $stream i32)
      (call $append (i32.const 256) (i32.const 9))
      (call $read (call $get-stdin) (i64.const 1024) (i32.const 0))
      (if (i32.eqz (i32.load8_u (i32.const 0)))
        (then (call $number (i32.load (i32.const 8))))
        (else (call $stream-error (i32.const 0))))
      (local.set $stream (call $get-stdout))
      (call $write (local.get $stream) (local.get $input) (local.get $length) (i32.const 16))
      (call $write (local.get $stream) (i32.const 400) (i32.const 1) (i32.const 32))
      (call $append (i32.const 272) (i32.const 10))
      (call $written (i32.const 16))
      (local.set $stream (call $get-stderr))
      (call $write (local.get $stream) (local.get $input) (local.get $length) (i32.const 48))
      (call $write (local.get $stream) (i32.const 400) (i32.const 1) (i32.const 64))
      (call $append (i32.const 288) (i32.const 10))
      (call $written (i32.const 48))
      (call $get-arguments (i32.const 80))
      (call $append (i32.const 304) (i32.const 8))
      (call $number (i32.load (i32.const 84)))
      (call $get-environment (i32.const 88))
      (call $append (i32.const 320) (i32.const 7))
      (call $number (i32.load (i32.const 92)))
      (call $append (i32.const 336) (i32.const 1))
      (i32.store (i32.const 96) (i32.const 1024))
      (i32.store (i32.const 100) (i32.sub (global.get $out) (i32.const 1024)))
      (i32.const 96)))
  (core instance $i (instantiate $m
    (with "libc" (instance $libc))
    (with "cli" (instance
      (export "get-stdin" (func $get-stdin))
      (export "get-stdout" (func $get-stdout))
      (export "get-stderr" (func $get-stderr))
      (export "read" (func $read))
      (export "write" (func $write))
      (export "get-environment" (func $get-environment))
      (export "get-arguments" (func $get-arguments))))))
  (func $compute (param "input" string) (result string)
    (canon lift (core func $i "compute")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))
  ;; One function under each type's export, so every type runs it.
  (instance $compute-instance (export "compute" (func $compute)))
  (instance $run-instance (export "run" (func $compute)))
  (export "cyfr:reagent/compute@0.1.0" (instance $compute-instance))
  (export "cyfr:catalyst/run@0.1.0" (instance $run-instance))
  (export "cyfr:formula/run@0.1.0" (instance $run-instance)))
