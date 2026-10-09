;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 CYFR Works Inc.
;;
;; A catalyst that tries to see the credential CYFR attaches for it. Its
;; `run` hands its whole input string to `cyfr:http/fetch`'s `request` as
;; the request JSON (the input names the connection, and an upstream that
;; reflects the request's headers and body answers it), asks its vault
;; (`cyfr:vault/read`) for `CANARY_KEY`, the field the connection
;; attaches, and writes everything it saw, once as one event through
;; `cyfr:emit/events` and again as its output:
;;
;;   event   {"type":"canary.seen","fetched":F,"read":{"ok":B,"value":"V"}}
;;   output  {"status":200,"data":<the event>}
;;
;; F is the fetch's answer as the host gave it (a JSON object, written as
;; it came), B whether the vault answered a value, and V the value or the
;; refusal, escaped as a JSON string. Whatever reached it is in both.
;;
;; The canonical ABI lowers each import to (pointer, length, return
;; pointer): `request` and `emit` write a string's pointer and length at
;; the return pointer; `get` writes a case byte (0 for ok) and the string's
;; pointer and length after it. The host allocates every string through
;; `cabi_realloc`, a bump allocator that grows the memory as a string needs
;; it. `run` answers the return area at 32, which holds the output's
;; pointer and length. Built by `build.sh` (README.md).
(module
  (import "cyfr:http/fetch@0.1.0" "request" (func $request (param i32 i32 i32)))
  (import "cyfr:vault/read@0.1.0" "get" (func $get (param i32 i32 i32)))
  (import "cyfr:emit/events@0.1.0" "emit" (func $emit (param i32 i32 i32)))
  (memory $io (export "memory") 1)
  (data (i32.const 240) "0123456789abcdef")
  (data (i32.const 256) "CANARY_KEY")
  (data (i32.const 288) "{\22type\22:\22canary.seen\22,\22fetched\22:")
  (data (i32.const 352) ",\22read\22:{\22ok\22:")
  (data (i32.const 384) "true")
  (data (i32.const 392) "false")
  (data (i32.const 400) ",\22value\22:\22")
  (data (i32.const 416) "\22}}")
  (data (i32.const 432) "{\22status\22:200,\22data\22:")
  (data (i32.const 464) "}")
  (global $heap (mut i32) (i32.const 4096))
  (func $realloc (export "cabi_realloc") (param $old i32) (param $old_size i32) (param $align i32) (param $new_size i32) (result i32)
    (local $ptr i32)
    (local $end i32)
    ;; The next address aligned to `align`, a power of two.
    (local.set $ptr
      (i32.and
        (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
        (i32.sub (i32.const 0) (local.get $align))))
    (local.set $end (i32.add (local.get $ptr) (local.get $new_size)))
    (block $fits
      (loop $grow
        (br_if $fits (i32.le_u (local.get $end) (i32.mul (memory.size) (i32.const 65536))))
        (if (i32.eq (memory.grow (i32.const 1)) (i32.const -1)) (then unreachable))
        (br $grow)))
    (global.set $heap (local.get $end))
    (local.get $ptr))
  ;; Copy `len` bytes from `src` to `dst`, and answer the address after them.
  (func $put (param $dst i32) (param $src i32) (param $len i32) (result i32)
    (memory.copy (local.get $dst) (local.get $src) (local.get $len))
    (i32.add (local.get $dst) (local.get $len)))
  ;; Write the `len` bytes at `src` to `dst` as the inside of a JSON string
  ;; (a quote and a backslash escaped, a control byte as \u00XX), and
  ;; answer the address after them. `dst` has room for six bytes per byte.
  (func $escape (param $src i32) (param $len i32) (param $dst i32) (result i32)
    (local $i i32)
    (local $b i32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $b (i32.load8_u (i32.add (local.get $src) (local.get $i))))
        (if (i32.or (i32.eq (local.get $b) (i32.const 34)) (i32.eq (local.get $b) (i32.const 92)))
          (then
            (i32.store8 (local.get $dst) (i32.const 92))
            (i32.store8 offset=1 (local.get $dst) (local.get $b))
            (local.set $dst (i32.add (local.get $dst) (i32.const 2))))
          (else
            (if (i32.lt_u (local.get $b) (i32.const 32))
              (then
                (i32.store8 (local.get $dst) (i32.const 92))
                (i32.store8 offset=1 (local.get $dst) (i32.const 117))
                (i32.store8 offset=2 (local.get $dst) (i32.const 48))
                (i32.store8 offset=3 (local.get $dst) (i32.const 48))
                (i32.store8 offset=4 (local.get $dst)
                  (i32.load8_u offset=240 (i32.shr_u (local.get $b) (i32.const 4))))
                (i32.store8 offset=5 (local.get $dst)
                  (i32.load8_u offset=240 (i32.and (local.get $b) (i32.const 15))))
                (local.set $dst (i32.add (local.get $dst) (i32.const 6))))
              (else
                (i32.store8 (local.get $dst) (local.get $b))
                (local.set $dst (i32.add (local.get $dst) (i32.const 1)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))
    (local.get $dst))
  (func (export "cyfr:catalyst/run@0.1.0#run") (param $ptr i32) (param $len i32) (result i32)
    (local $answer i32)
    (local $answer_len i32)
    (local $value i32)
    (local $value_len i32)
    (local $seen i32)
    (local $seen_len i32)
    (local $out i32)
    (local $at i32)
    ;; The request its input names, and the answer the host gave it.
    (call $request (local.get $ptr) (local.get $len) (i32.const 16))
    (local.set $answer (i32.load (i32.const 16)))
    (local.set $answer_len (i32.load (i32.const 20)))
    ;; The field the connection attaches, or the vault's refusal.
    (call $get (i32.const 256) (i32.const 10) (i32.const 64))
    (local.set $value (i32.load (i32.const 68)))
    (local.set $value_len (i32.load (i32.const 72)))
    ;; Everything it saw, as one event.
    (local.set $seen
      (call $realloc (i32.const 0) (i32.const 0) (i32.const 1)
        (i32.add (i32.add (local.get $answer_len) (i32.mul (local.get $value_len) (i32.const 6)))
          (i32.const 128))))
    (local.set $at (call $put (local.get $seen) (i32.const 288) (i32.const 32)))
    (local.set $at (call $put (local.get $at) (local.get $answer) (local.get $answer_len)))
    (local.set $at (call $put (local.get $at) (i32.const 352) (i32.const 14)))
    (local.set $at
      (if (result i32) (i32.eqz (i32.load8_u (i32.const 64)))
        (then (call $put (local.get $at) (i32.const 384) (i32.const 4)))
        (else (call $put (local.get $at) (i32.const 392) (i32.const 5)))))
    (local.set $at (call $put (local.get $at) (i32.const 400) (i32.const 10)))
    (local.set $at (call $escape (local.get $value) (local.get $value_len) (local.get $at)))
    (local.set $at (call $put (local.get $at) (i32.const 416) (i32.const 3)))
    (local.set $seen_len (i32.sub (local.get $at) (local.get $seen)))
    (call $emit (local.get $seen) (local.get $seen_len) (i32.const 80))
    ;; And again as its output.
    (local.set $out
      (call $realloc (i32.const 0) (i32.const 0) (i32.const 1)
        (i32.add (local.get $seen_len) (i32.const 32))))
    (local.set $at (call $put (local.get $out) (i32.const 432) (i32.const 21)))
    (local.set $at (call $put (local.get $at) (local.get $seen) (local.get $seen_len)))
    (local.set $at (call $put (local.get $at) (i32.const 464) (i32.const 1)))
    (i32.store (i32.const 32) (local.get $out))
    (i32.store (i32.const 36) (i32.sub (local.get $at) (local.get $out)))
    (i32.const 32)))
