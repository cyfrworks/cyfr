;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` calls each function of its program pipe
;; (`cyfr:process/pipe`) once, in order (open, send, recv, close), and
;; answers `{"status": 200, "data": {"pipe": P}}`, where P holds one letter
;; per call: `O` for an ok, `N` for an err whose string is `not_built`,
;; `E` for any other err.
;;
;; The canonical ABI lowers each call to its flattened arguments (a string
;; or a list as pointer and length, `after` as an i64, `max-wait-ms` as an
;; i32) and a return pointer; the host writes the result's case at it (a
;; byte, 0 for ok) and an err's string pointer and length at 4 and 8 past
;; it, allocating the string through `cabi_realloc`. Built by `build.sh`
;; (README.md).
(module
  (import "cyfr:process/pipe@0.1.0" "open" (func $open (param i32 i32 i32 i32 i32 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "send" (func $send (param i32 i32 i32 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "recv" (func $recv (param i32 i32 i64 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "close" (func $close (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (data (i32.const 256) "not_built")
  (data (i32.const 272) "coder")
  (data (i32.const 280) "chat_1")
  (data (i32.const 288) "--flag")
  (data (i32.const 296) "hello")
  (data (i32.const 304) "pipe_1")
  ;; `argv`: one string, the 6 bytes at 288.
  (data (i32.const 320) "\20\01\00\00\06\00\00\00")
  ;; `lines`: one string, the 5 bytes at 296.
  (data (i32.const 336) "\28\01\00\00\05\00\00\00")
  (data (i32.const 512) "{\22status\22:200,\22data\22:{\22pipe\22:\22????\22}}")
  (global $heap (mut i32) (i32.const 4096))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap))
    (global.set $heap (i32.add (global.get $heap) (i32.add (local.get $new_size) (i32.const 8))))
    (local.get $ptr))
  ;; Mark at `at` the result written at 64.
  (func $mark (param $at i32)
    (local $err i32)
    (local.set $err (i32.load (i32.const 68)))
    (i32.store8 (local.get $at)
      (if (result i32) (i32.eqz (i32.load8_u (i32.const 64)))
        (then (i32.const 79))
        (else
          (select (i32.const 78) (i32.const 69)
            (i32.and
              (i32.eq (i32.load (i32.const 72)) (i32.const 9))
              (i32.and
                (i64.eq (i64.load (local.get $err)) (i64.load (i32.const 256)))
                (i32.eq (i32.load8_u offset=8 (local.get $err)) (i32.load8_u (i32.const 264))))))))))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (call $open (i32.const 272) (i32.const 5) (i32.const 280) (i32.const 6) (i32.const 320) (i32.const 1) (i32.const 64))
    (call $mark (i32.const 542))
    (call $send (i32.const 304) (i32.const 6) (i32.const 336) (i32.const 1) (i32.const 64))
    (call $mark (i32.const 543))
    (call $recv (i32.const 304) (i32.const 6) (i64.const 0) (i32.const 1000) (i32.const 64))
    (call $mark (i32.const 544))
    (call $close (i32.const 304) (i32.const 6) (i32.const 64))
    (call $mark (i32.const 545))
    (i32.store (i32.const 8) (i32.const 512))
    (i32.store (i32.const 12) (i32.const 37))
    (i32.const 8)))
