;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` asks its invocation for one further input
;; (`cyfr:model/inputs`) and, given one, reports it sent. Its input is
;; ignored. It answers
;;
;;   {"status":200,"data":{"next":O,"id":I,"content_bytes":N,"sent":S}}
;;
;; where O is `ok`, `none` or the call's err code, I the input's id, N the
;; bytes of its content's JSON and S `ok` or the report's err code; an
;; answer of none or an err ends the run there, and the answer stops after
;; `next`. The id is copied as it came, unescaped: an input's id needs no
;; escaping in JSON.
;;
;; The canonical ABI lowers `next` to a return pointer alone, here 64: the
;; host writes the result's case (a byte, 0 for ok) and, 4 past it, an
;; err's string pointer and length, or the option's case (a byte, 0 for
;; none) and, 8 past the result, the input's id and content, each a
;; string's pointer and length. `sent` takes the id's pointer and length
;; and a return pointer, here 128: the result's case, and 4 past it an
;; err's string. The host allocates what it writes through
;; `cabi_realloc`, honouring the alignment it asks for. Built by
;; `build.sh` (README.md).
(module
  (import "cyfr:model/inputs@0.1.0" "next" (func $next (param i32)))
  (import "cyfr:model/inputs@0.1.0" "sent" (func $sent (param i32 i32 i32)))
  (memory $io (export "memory") 2)
  (data (i32.const 512) "{\22status\22:200,\22data\22:{\22next\22:\22")
  (data (i32.const 542) "\22")
  (data (i32.const 543) "}}")
  (data (i32.const 545) "ok")
  (data (i32.const 547) "none")
  (data (i32.const 551) ",\22id\22:\22")
  (data (i32.const 558) ",\22content_bytes\22:")
  (data (i32.const 575) ",\22sent\22:\22")
  ;; Where the answer is written next, from 16384.
  (global $out (mut i32) (i32.const 16384))
  ;; The allocator's next free byte, from 32768.
  (global $heap (mut i32) (i32.const 32768))
  (func (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr
      (i32.and
        (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
        (i32.sub (i32.const 0) (local.get $align))))
    (global.set $heap (i32.add (local.get $ptr) (local.get $new_size)))
    (local.get $ptr))
  ;; Append `len` bytes at `src` to the answer.
  (func $put (param $src i32) (param $len i32)
    (memory.copy (global.get $out) (local.get $src) (local.get $len))
    (global.set $out (i32.add (global.get $out) (local.get $len))))
  ;; Append `n` in decimal.
  (func $put_u32 (param $n i32)
    (local $at i32)
    ;; The digits are written backwards at 960..991, then appended.
    (local.set $at (i32.const 992))
    (loop $more
      (local.set $at (i32.sub (local.get $at) (i32.const 1)))
      (i32.store8 (local.get $at) (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
      (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
      (br_if $more (i32.ne (local.get $n) (i32.const 0))))
    (call $put (local.get $at) (i32.sub (i32.const 992) (local.get $at))))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (call $put (i32.const 512) (i32.const 30))
    (call $next (i32.const 64))
    (block $answered
      (if (i32.load8_u (i32.const 64))
        (then
          (call $put (i32.load (i32.const 68)) (i32.load (i32.const 72)))
          (call $put (i32.const 542) (i32.const 1))
          (br $answered)))
      (if (i32.eqz (i32.load8_u (i32.const 68)))
        (then
          (call $put (i32.const 547) (i32.const 4))
          (call $put (i32.const 542) (i32.const 1))
          (br $answered)))
      (call $put (i32.const 545) (i32.const 2))
      (call $put (i32.const 542) (i32.const 1))
      (call $put (i32.const 551) (i32.const 7))
      (call $put (i32.load (i32.const 72)) (i32.load (i32.const 76)))
      (call $put (i32.const 542) (i32.const 1))
      (call $put (i32.const 558) (i32.const 17))
      (call $put_u32 (i32.load (i32.const 84)))
      (call $put (i32.const 575) (i32.const 9))
      (call $sent (i32.load (i32.const 72)) (i32.load (i32.const 76)) (i32.const 128))
      (if (i32.eqz (i32.load8_u (i32.const 128)))
        (then (call $put (i32.const 545) (i32.const 2)))
        (else (call $put (i32.load (i32.const 132)) (i32.load (i32.const 136)))))
      (call $put (i32.const 542) (i32.const 1)))
    (call $put (i32.const 543) (i32.const 2))
    (i32.store (i32.const 8) (i32.const 16384))
    (i32.store (i32.const 12) (i32.sub (global.get $out) (i32.const 16384)))
    (i32.const 8)))
