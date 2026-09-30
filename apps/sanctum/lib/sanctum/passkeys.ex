# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Passkeys do
  @moduledoc """
  A person's passkeys at this relying home: registration with user
  verification, sign-in by passkey as a door, and an assertion over a
  pending confirmation's digest as a fresh proof, each pinned to this
  home's RP ID and expected origin and stored through `Arca.Passkeys`.

  It holds no function yet: no passkey is registered or asserted.
  """
end
