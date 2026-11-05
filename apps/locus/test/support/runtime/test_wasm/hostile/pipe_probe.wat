;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst whose `run` drives its program pipe (`cyfr:process/pipe`) once
;; round: it opens the need `coder` under the key `chat_1` with the argument
;; `--flag`, sends one line, reads the lines past 0 waiting up to 1000 ms,
;; and closes the session. Its input is `{"line":"TEXT"}`, TEXT the line it
;; sends, with `\n`, `\"` and `\\` read as the characters they escape (so a
;; test can hand it a line holding a newline). It answers
;;
;;   {"status":200,"data":{"open":O,"session":S,"resumed":B,"send":O,
;;     "recv":O,"count":N,"dropped":D,"line":T,"running":B,"close":O}}
;;
;; where each O is `ok` or the call's err code, S the session, B a boolean,
;; N the lines the recv answered, D its dropped count and T the text of its
;; first line (absent when it answered none). An open that errs ends the
;; run there: no other pipe call is made, and the answer stops after `open`.
;; Strings are copied as they came, unescaped, so a test uses ones that
;; need no escaping in JSON.
;;
;; The canonical ABI lowers each call to its flattened arguments (a string
;; or a list as pointer and length, `after` as an i64, `max-wait-ms` as an
;; i32) and a return pointer, here 64. At it the host writes the result's
;; case (a byte, 0 for ok) and, 4 past it, an err's string pointer and
;; length; an ok `opened` is its session's pointer and length and, 12 past
;; it, `resumed`; an ok `recv-result` is its lines' pointer and count, 12
;; past it `dropped` and 16 past it `running`, each line 16 bytes, its text's
;; pointer and length at 8 and 12. The host allocates what it writes
;; through `cabi_realloc`, honouring the alignment it asks for. Built by
;; `build.sh` (README.md).
(module
  (import "cyfr:process/pipe@0.1.0" "open" (func $open (param i32 i32 i32 i32 i32 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "send" (func $send (param i32 i32 i32 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "recv" (func $recv (param i32 i32 i64 i32 i32)))
  (import "cyfr:process/pipe@0.1.0" "close" (func $close (param i32 i32 i32)))
  (memory $io (export "memory") 2)
  (data (i32.const 256) "coder")
  (data (i32.const 264) "chat_1")
  (data (i32.const 272) "--flag")
  ;; `argv`: one string, the 6 bytes at 272.
  (data (i32.const 288) "\10\01\00\00\06\00\00\00")
  ;; `lines` (296): one string, the decoded input line at 1024, written by `run`.
  (data (i32.const 512) "{\22status\22:200,\22data\22:{\22open\22:\22")
  (data (i32.const 542) "\22")
  (data (i32.const 543) "}}")
  (data (i32.const 545) "ok")
  (data (i32.const 547) ",\22session\22:\22")
  (data (i32.const 559) "\22,\22resumed\22:")
  (data (i32.const 571) "true")
  (data (i32.const 575) "false")
  (data (i32.const 580) ",\22send\22:\22")
  (data (i32.const 589) ",\22recv\22:\22")
  (data (i32.const 598) ",\22count\22:")
  (data (i32.const 607) ",\22dropped\22:")
  (data (i32.const 618) ",\22line\22:\22")
  (data (i32.const 627) ",\22running\22:")
  (data (i32.const 638) ",\22close\22:\22")
  ;; The session `open` answered.
  (global $session (mut i32) (i32.const 0))
  (global $session_len (mut i32) (i32.const 0))
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
    (local $digits i32)
    (local $at i32)
    ;; The digits are written backwards at 960..991, then appended.
    (local.set $at (i32.const 992))
    (loop $more
      (local.set $at (i32.sub (local.get $at) (i32.const 1)))
      (i32.store8 (local.get $at) (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
      (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
      (br_if $more (i32.ne (local.get $n) (i32.const 0))))
    (call $put (local.get $at) (i32.sub (i32.const 992) (local.get $at))))
  (func $put_bool (param $b i32)
    (if (local.get $b)
      (then (call $put (i32.const 571) (i32.const 4)))
      (else (call $put (i32.const 575) (i32.const 5)))))
  ;; Append the result written at 64: `ok`, or the err's string.
  (func $mark
    (if (i32.eqz (i32.load8_u (i32.const 64)))
      (then (call $put (i32.const 545) (i32.const 2)))
      (else (call $put (i32.load (i32.const 68)) (i32.load (i32.const 72))))))
  ;; Decode the input `{"line":"TEXT"}` into 1024, answering TEXT's length.
  (func $line (param $ptr i32) (param $len i32) (result i32)
    (local $at i32)
    (local $stop i32)
    (local $to i32)
    (local $byte i32)
    (local.set $at (i32.add (local.get $ptr) (i32.const 9)))
    (local.set $stop (i32.sub (i32.add (local.get $ptr) (local.get $len)) (i32.const 2)))
    (local.set $to (i32.const 1024))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $at) (local.get $stop)))
        (local.set $byte (i32.load8_u (local.get $at)))
        (if (i32.eq (local.get $byte) (i32.const 92))
          (then
            (local.set $at (i32.add (local.get $at) (i32.const 1)))
            (local.set $byte (i32.load8_u (local.get $at)))
            (if (i32.eq (local.get $byte) (i32.const 110))
              (then (local.set $byte (i32.const 10))))))
        (i32.store8 (local.get $to) (local.get $byte))
        (local.set $to (i32.add (local.get $to) (i32.const 1)))
        (local.set $at (i32.add (local.get $at) (i32.const 1)))
        (br $next)))
    (i32.sub (local.get $to) (i32.const 1024)))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 296) (i32.const 1024))
    (i32.store (i32.const 300) (call $line (local.get $ptr) (local.get $len)))
    (call $put (i32.const 512) (i32.const 30))
    (call $open (i32.const 256) (i32.const 5) (i32.const 264) (i32.const 6) (i32.const 288) (i32.const 1) (i32.const 64))
    (call $mark)
    (call $put (i32.const 542) (i32.const 1))
    (block $answered
      (br_if $answered (i32.load8_u (i32.const 64)))
      (global.set $session (i32.load (i32.const 68)))
      (global.set $session_len (i32.load (i32.const 72)))
      (call $put (i32.const 547) (i32.const 12))
      (call $put (global.get $session) (global.get $session_len))
      (call $put (i32.const 559) (i32.const 12))
      (call $put_bool (i32.load8_u (i32.const 76)))
      (call $put (i32.const 580) (i32.const 9))
      (call $send (global.get $session) (global.get $session_len) (i32.const 296) (i32.const 1) (i32.const 64))
      (call $mark)
      (call $put (i32.const 542) (i32.const 1))
      (call $put (i32.const 589) (i32.const 9))
      (call $recv (global.get $session) (global.get $session_len) (i64.const 0) (i32.const 1000) (i32.const 64))
      (call $mark)
      (call $put (i32.const 542) (i32.const 1))
      (if (i32.eqz (i32.load8_u (i32.const 64)))
        (then
          (call $put (i32.const 598) (i32.const 9))
          (call $put_u32 (i32.load (i32.const 72)))
          (call $put (i32.const 607) (i32.const 11))
          (call $put_u32 (i32.load (i32.const 76)))
          (if (i32.load (i32.const 72))
            (then
              (call $put (i32.const 618) (i32.const 9))
              (call $put
                (i32.load offset=8 (i32.load (i32.const 68)))
                (i32.load offset=12 (i32.load (i32.const 68))))
              (call $put (i32.const 542) (i32.const 1))))
          (call $put (i32.const 627) (i32.const 11))
          (call $put_bool (i32.load8_u (i32.const 80)))))
      (call $put (i32.const 638) (i32.const 10))
      (call $close (global.get $session) (global.get $session_len) (i32.const 64))
      (call $mark)
      (call $put (i32.const 542) (i32.const 1)))
    (call $put (i32.const 543) (i32.const 2))
    (i32.store (i32.const 8) (i32.const 16384))
    (i32.store (i32.const 12) (i32.sub (global.get $out) (i32.const 16384)))
    (i32.const 8)))
