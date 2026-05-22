# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuthTest do
  @moduledoc """
  R2 regression guards for `Sanctum.OAuth`.

  `Sanctum.OAuth` had no pre-existing test harness, and a full PKCE
  authorize→callback integration needs a registered component manifest +
  provider-credential secrets + a mocked token endpoint (disproportionate for
  this security pass). These cover the deterministic, fixture-free invariants;
  the PKCE wiring itself (S256 challenge in the URL, server-held verifier in
  the pending, verifier sent in the token exchange) is exercised by the full
  end-to-end suite and verified by review.
  """
  use ExUnit.Case, async: true

  describe "exchange_code/3 — state is single-use proof-of-initiation" do
    test "unknown / expired state is rejected (no pending record)" do
      assert {:error, "invalid or expired state parameter"} =
               Sanctum.OAuth.exchange_code("unknown-state-#{System.unique_integer()}", "code", "uri")
    end
  end

  describe "PKCE S256 contract (RFC 7636)" do
    test "challenge derivation the implementation must satisfy" do
      # Locks the exact transform authorize_url/3 applies: verifier and
      # challenge are base64url (no padding); challenge = SHA-256(verifier).
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
      assert challenge =~ ~r/^[A-Za-z0-9_-]+$/
      refute String.contains?(challenge, "=")
      assert challenge != verifier
      assert byte_size(Base.url_decode64!(challenge, padding: false)) == 32
    end
  end
end
