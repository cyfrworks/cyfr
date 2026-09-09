# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.RootSelectTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority.RootSelect

  # Real-shaped ids: `Cyfr.UUID7.generate_id("prof")` emits `prof_<uuid>`,
  # and `decode/1` discriminates on exactly that prefix.
  @owner %{
    id: "prof_owner",
    kind: :owner,
    source_ref: "tincture:local.dashboard",
    label: "default",
    status: :active
  }
  @public %{@owner | id: "prof_public", kind: :public, label: "public"}

  defp profile(overrides), do: Map.merge(@owner, overrides)

  # ============================================================================
  # The selector vocabulary
  # ============================================================================

  describe "decode/1" do
    test "an id-shaped string is an id, anything else is a label" do
      assert {:id, "prof_owner"} = RootSelect.decode("prof_owner")
      assert {:label, "work"} = RootSelect.decode("work")
      # A hyphen is not the separator `generate_id/1` uses.
      assert {:label, "prof-owner"} = RootSelect.decode("prof-owner")
    end

    test "blank and non-binary decode to the default" do
      assert :default = RootSelect.decode("")
      assert :default = RootSelect.decode("   ")
      assert :default = RootSelect.decode(nil)
      assert :default = RootSelect.decode(%{})
    end

    test "surrounding whitespace is not part of the selector" do
      assert {:label, "work"} = RootSelect.decode("  work  ")
    end
  end

  describe "valid_label?/1" do
    test "refuses what would make decode/1 a guess" do
      refute RootSelect.valid_label?("prof_sneaky")
      refute RootSelect.valid_label?("")
      refute RootSelect.valid_label?(nil)
    end

    test "admits ordinary labels" do
      assert RootSelect.valid_label?("default")
      assert RootSelect.valid_label?("work")
      assert RootSelect.valid_label?("prof-hyphen")
    end
  end

  # ============================================================================
  # select/2 — explicit selector
  # ============================================================================

  describe "select/2 with a selector" do
    test "id and label match their own field only" do
      candidates = [@owner, @public]

      assert {:ok, @owner} = RootSelect.select(candidates, {:id, "prof_owner"})
      assert {:ok, @public} = RootSelect.select(candidates, {:label, "public"})
    end

    test "a label is not matched against ids, nor an id against labels" do
      candidates = [@owner, @public]

      assert {:error, {:not_found, "prof_owner"}} =
               RootSelect.select(candidates, {:label, "prof_owner"})

      assert {:error, {:not_found, "public"}} = RootSelect.select(candidates, {:id, "public"})
    end

    test "unknown selector fails" do
      assert {:error, {:not_found, "nope"}} = RootSelect.select([@owner], {:label, "nope"})
    end

    test "an inactive match is unavailable, never skipped for another profile" do
      revoked = profile(%{status: :revoked})
      other = profile(%{id: "prof_2", label: "work"})

      assert {:error, {:profile_unavailable, :revoked}} =
               RootSelect.select([revoked, other], {:id, "prof_owner"})

      needs = profile(%{status: :needs_consent})

      assert {:error, {:profile_unavailable, :needs_consent}} =
               RootSelect.select([needs], {:label, "default"})
    end

    test "several matches are ambiguous" do
      # An owner and a public profile may share a label.
      same_label = [profile(%{}), profile(%{id: "prof_b", kind: :public})]

      assert {:error, {:ambiguous, ["prof_owner", "prof_b"]}} =
               RootSelect.select(same_label, {:label, "default"})
    end
  end

  # ============================================================================
  # select/2 — :default: single active owner or fail
  # ============================================================================

  describe "select/2 with :default" do
    test "a single active owner profile is the default" do
      assert {:ok, @owner} = RootSelect.select([@owner, @public], :default)
    end

    test "zero owner profiles fails" do
      assert {:error, :no_profile} = RootSelect.select([], :default)
      assert {:error, :no_profile} = RootSelect.select([@public], :default)
    end

    test "several active owner profiles fail rather than guess" do
      two = [@owner, profile(%{id: "prof_work", label: "work"})]

      assert {:error, {:ambiguous, ["prof_owner", "prof_work"]}} =
               RootSelect.select(two, :default)
    end

    test "a single inactive owner profile reports its status" do
      assert {:error, {:profile_unavailable, :needs_consent}} =
               RootSelect.select([profile(%{status: :needs_consent})], :default)
    end

    test "several owners with none active fails" do
      stale = [
        profile(%{status: :revoked}),
        profile(%{id: "prof_2", label: "work", status: :needs_consent})
      ]

      assert {:error, :no_profile} = RootSelect.select(stale, :default)
    end
  end

  # ============================================================================
  # select_for_route/3 — public is resolved first
  # ============================================================================

  describe "select_for_route/3" do
    test "a public route selects the public profile regardless of authentication" do
      candidates = [@owner, @public]

      # A public route selects the public profile even with a valid owner cookie.
      assert {:ok, @public} = RootSelect.select_for_route(candidates, :public, true)
      assert {:ok, @public} = RootSelect.select_for_route(candidates, :public, false)
    end

    test "a public route without a public profile fails even when authenticated" do
      assert {:error, :no_public_profile} =
               RootSelect.select_for_route([@owner], :public, true)
    end

    test "an inactive public profile is unavailable" do
      revoked = profile(%{id: "prof_public", kind: :public, status: :revoked})

      assert {:error, {:profile_unavailable, :revoked}} =
               RootSelect.select_for_route([@owner, revoked], :public, true)
    end

    test "a protected route requires authentication, then owner selection" do
      candidates = [@owner, @public]

      assert {:ok, @owner} = RootSelect.select_for_route(candidates, :protected, true)

      assert {:error, :unauthenticated} =
               RootSelect.select_for_route(candidates, :protected, false)
    end

    test "a protected route inherits :default's refusal to guess" do
      two = [@owner, profile(%{id: "prof_work", label: "work"})]

      assert {:error, {:ambiguous, _}} =
               RootSelect.select_for_route(two, :protected, true)
    end
  end
end
