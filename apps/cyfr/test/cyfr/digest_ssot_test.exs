# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DigestSSOTTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins Cyfr.Digest as the only module that spells a content digest.

  A second producer is how the components table ended up holding two digest
  formats (bare hex for tinctures, prefixed for everything else) — this scan
  fails the build if the `"sha256:" <>` construction reappears outside
  Cyfr.Digest.
  """

  # apps/cyfr/test/cyfr -> umbrella root
  @umbrella_root Path.expand("../../../..", __DIR__)

  # Construction = concatenating the prefix onto a computed value. Pattern
  # matches (`"sha256:" <> hex` in a function head) and prose are consumers
  # of the spelling, not producers, and stay allowed.
  @construction ~r/"sha256:" <>\s*(\(|Base\.|:crypto)/

  test ~s(the "sha256:" spelling is constructed only in Cyfr.Digest) do
    offenders =
      Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path -> Regex.match?(@construction, File.read!(path)) end)
      |> Enum.map(&Path.relative_to(&1, @umbrella_root))
      |> Enum.reject(&(&1 == "apps/cyfr/lib/cyfr/digest.ex"))

    assert offenders == [],
           "digest spelling constructed outside Cyfr.Digest: #{inspect(offenders)}"
  end
end
