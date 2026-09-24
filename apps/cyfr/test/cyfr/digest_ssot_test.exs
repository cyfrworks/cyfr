# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DigestSSOTTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins Prima.Digest as the only module that spells a content digest.

  A second producer is how the components table ended up holding two digest
  formats (bare hex for tinctures, prefixed for everything else) — this scan
  fails the build if the `"sha256:" <>` construction reappears outside
  Prima.Digest.
  """

  # apps/cyfr/test/cyfr -> umbrella root
  @umbrella_root Path.expand("../../../..", __DIR__)

  # Construction = concatenating the prefix onto a computed value. Pattern
  # matches (`"sha256:" <> hex` in a function head) and prose are consumers
  # of the spelling, not producers, and stay allowed.
  @construction ~r/"sha256:" <>\s*(\(|Base\.|:crypto)/

  # The bare-hex spelling (no "sha256:" prefix): hashing into lowercase hex
  # is `Prima.Digest.sha256_hex/1`'s job. Hashes that stay raw binaries
  # (session/api-key token columns) or use another encoding (PKCE's
  # base64url) are different conventions and don't match.
  @bare_hex ~r/:crypto\.hash\(:sha256.*(\n.*)?\|>\s*Base\.encode16|Base\.encode16\(\s*:crypto\.hash\(:sha256/

  defp scanned do
    Prima.Test.SourceTree.files!(Path.join(@umbrella_root, "apps/*/lib/**/*.ex")) ++
      Prima.Test.SourceTree.files!(
        Path.join(@umbrella_root, "apps/arca/priv/repo/migrations/*.exs")
      )
  end

  test ~s(the "sha256:" spelling is constructed only in Prima.Digest) do
    offenders =
      scanned()
      |> Enum.filter(fn path -> Regex.match?(@construction, Prima.Test.SourceTree.read(path)) end)
      |> Enum.map(&Path.relative_to(&1, @umbrella_root))
      |> Enum.reject(&(&1 == "apps/prima/lib/prima/digest.ex"))

    assert offenders == [],
           "digest spelling constructed outside Prima.Digest: #{inspect(offenders)}"
  end

  test "the bare-hex spelling is constructed only in Prima.Digest" do
    offenders =
      scanned()
      |> Enum.filter(fn path -> Regex.match?(@bare_hex, Prima.Test.SourceTree.read(path)) end)
      |> Enum.map(&Path.relative_to(&1, @umbrella_root))
      |> Enum.reject(&(&1 == "apps/prima/lib/prima/digest.ex"))

    assert offenders == [],
           "bare-hex digest spelling constructed outside Prima.Digest: #{inspect(offenders)}"
  end
end
