# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceCerts do
  @moduledoc """
  Device certificates as a backend checks them: the proof of possession
  on a connection, and on every paired request a strict expiry on this
  home's clock, clock tolerance at not-before alone, and the chain to the
  person's current live key, read from the certificate's own subject. No
  cached validation outlives a certificate.

  It holds no function yet: no device certificate is verified.
  """
end
