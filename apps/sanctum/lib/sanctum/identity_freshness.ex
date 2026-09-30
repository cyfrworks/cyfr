# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshness do
  @moduledoc """
  How fresh a remote person's identity head is at this home: the cached
  head against `identity_freshness_seconds` on the database's clock, a
  refresh from the person's directory when it is stale, the
  distinguishable `identity_stale` refusal when the directory cannot
  answer past the bound, and a live-key rotation submitted through the
  directory client. A local identity never consults a directory for
  freshness.

  It holds no function yet: no remote identity is admitted here.
  """
end
