# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.RootSelectTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority.RootSelect

  @owner %{
    id: "prof-owner",
    kind: :owner,
    source_ref: "tincture:local.dashboard",
    label: "default",
    status: :active
  }
  @public %{@owner | id: "prof-public", kind: :public, label: "public"}

  defp profile(overrides), do: Map.merge(@owner, overrides)

  # ============================================================================
  # select/2 — explicit selector
  # ============================================================================

  describe "select/2 with a selector" do
    test "matches by id or label" do
      candidates = [@owner, @public]

      assert {:ok, @owner} = RootSelect.select(candidates, "prof-owner")
      assert {:ok, @public} = RootSelect.select(candidates, "public")
    end

    test "unknown selector fails" do
      assert {:error, {:not_found, "nope"}} = RootSelect.select([@owner], "nope")
    end

    test "an inactive match is unavailable, never skipped for another profile" do
      revoked = profile(%{status: :revoked})
      other = profile(%{id: "prof-2", label: "work"})

      assert {:error, {:profile_unavailable, :revoked}} =
               RootSelect.select([revoked, other], "prof-owner")

      needs = profile(%{status: :needs_consent})

      assert {:error, {:profile_unavailable, :needs_consent}} =
               RootSelect.select([needs], "default")
    end

    test "several matches are ambiguous" do
      # An owner and a public profile may share a label.
      same_label = [profile(%{}), profile(%{id: "prof-b", kind: :public})]

      assert {:error, {:ambiguous, ["prof-owner", "prof-b"]}} =
               RootSelect.select(same_label, "default")
    end
  end

  # ============================================================================
  # select/2 — no selector: single active owner or fail
  # ============================================================================

  describe "select/2 without a selector" do
    test "a single active owner profile is the default" do
      assert {:ok, @owner} = RootSelect.select([@owner, @public], nil)
    end

    test "zero owner profiles fails" do
      assert {:error, :no_profile} = RootSelect.select([], nil)
      assert {:error, :no_profile} = RootSelect.select([@public], nil)
    end

    test "several active owner profiles fail rather than guess" do
      two = [@owner, profile(%{id: "prof-work", label: "work"})]
      assert {:error, {:ambiguous, ["prof-owner", "prof-work"]}} = RootSelect.select(two, nil)
    end

    test "a single inactive owner profile reports its status" do
      assert {:error, {:profile_unavailable, :needs_consent}} =
               RootSelect.select([profile(%{status: :needs_consent})], nil)
    end

    test "several owners with none active fails" do
      stale = [
        profile(%{status: :revoked}),
        profile(%{id: "prof-2", label: "work", status: :needs_consent})
      ]

      assert {:error, :no_profile} = RootSelect.select(stale, nil)
    end
  end

  # ============================================================================
  # select_for_route/3 — public is resolved first
  # ============================================================================

  describe "select_for_route/3" do
    test "a public route selects the public profile regardless of authentication" do
      candidates = [@owner, @public]

      # §6 "Public routing" (pure half): a valid owner cookie on a public
      # route still selects the public profile.
      assert {:ok, @public} = RootSelect.select_for_route(candidates, :public, true)
      assert {:ok, @public} = RootSelect.select_for_route(candidates, :public, false)
    end

    test "a public route without a public profile fails even when authenticated" do
      assert {:error, :no_public_profile} =
               RootSelect.select_for_route([@owner], :public, true)
    end

    test "an inactive public profile is unavailable" do
      revoked = profile(%{id: "prof-public", kind: :public, status: :revoked})

      assert {:error, {:profile_unavailable, :revoked}} =
               RootSelect.select_for_route([@owner, revoked], :public, true)
    end

    test "a protected route requires authentication, then owner selection" do
      candidates = [@owner, @public]

      assert {:ok, @owner} = RootSelect.select_for_route(candidates, :protected, true)
      assert {:error, :unauthenticated} = RootSelect.select_for_route(candidates, :protected, false)
    end
  end
end
