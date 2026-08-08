# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.GetEffectiveCensusTest do
  use ExUnit.Case, async: true

  # The legacy resolver is down to its last readers: the consent plane's
  # source-priority fallback (for manifests with no needs/caps block) and
  # the resolver stack itself. Both die with the policies table — this
  # census makes sure no new caller sneaks in between now and the drop.
  @allowed_files [
    "apps/cyfr/lib/sanctum/policy.ex",
    "apps/cyfr/lib/sanctum/policy/resolver.ex",
    "apps/cyfr/lib/sanctum/consent/shape_derivation.ex",
    "apps/cyfr/lib/sanctum/consent/blob_builder.ex",
    "apps/cyfr/lib/sanctum/consent/bootstrap.ex"
  ]

  test "get_effective is referenced only by the resolver stack and the consent fallback" do
    root = Path.expand("../../../../..", __DIR__)

    referencing =
      Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "get_effective"))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert referencing == Enum.sort(@allowed_files),
           "get_effective gained or lost a caller — the drop plan owns this list"
  end
end
