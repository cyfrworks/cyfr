# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SemverTest do
  @moduledoc """
  The one version ordering: total, never raising, prerelease-aware —
  and the conservative supersession predicate beside it. Before this
  module existed there were five hand-rolled comparators with three
  different unparsable-input behaviours, one of which raised on a
  non-semver remote tag mid-render.
  """

  use ExUnit.Case, async: true

  doctest Compendium.Semver

  alias Compendium.Semver

  test "the ordering table — one total order for every caller" do
    # Semver rules where both parse.
    assert Semver.compare("1.10.0", "1.2.0") == :gt
    assert Semver.compare("1.0.0-rc1", "1.0.0") == :lt
    assert Semver.compare("2.0.0", "2.0.0") == :eq

    # The parsable side always wins; unparsable pairs order by string —
    # total either way, never a raise.
    assert Semver.compare("0.0.1", "latest") == :gt
    assert Semver.compare("latest", "0.0.1") == :lt
    assert Semver.compare("abc", "abd") == :lt
    assert Semver.compare("same", "same") == :eq

    assert Semver.sort_desc(["1.2.0", "latest", "1.10.0", "abc", "1.0.0-rc1", "1.0.0"]) ==
             ["1.10.0", "1.2.0", "1.0.0", "1.0.0-rc1", "latest", "abc"]
  end

  test "gt?/2 is nil-aware — a missing version never beats anything" do
    assert Semver.gt?("0.0.1", nil)
    refute Semver.gt?(nil, "0.0.1")
    refute Semver.gt?(nil, nil)
    assert Semver.gt?("1.1.0", "1.0.0")
    refute Semver.gt?("1.0.0", "1.0.0")
  end

  test "strictly_newer?/2 requires both sides to parse" do
    assert Semver.strictly_newer?("1.1.0", "1.0.0")
    refute Semver.strictly_newer?("1.0.0", "1.1.0")
    refute Semver.strictly_newer?("weird-dir-name", "1.0.0")
    refute Semver.strictly_newer?("2.0.0", "weird-dir-name")
  end
end
