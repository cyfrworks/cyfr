# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Person do
  @moduledoc """
  A person's online keys at their home: the live key, which signs person
  assertions for doors and device certificates, and the operational key,
  which rotates it. Both are sealed to the person under the `:person_key`
  purpose on the person's own identity row, never in an athanor's vault,
  and every use of either private key is here or in `Sanctum.Recovery`.

  It holds no function yet: no key set is minted, and nothing is signed.
  """
end
