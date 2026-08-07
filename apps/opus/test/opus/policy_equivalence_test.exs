# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.PolicyEquivalenceTest do
  @moduledoc """
  The oracle that has to stay green for weeks before Phase 5 drops the
  `policies` table: for a bootstrap-minted consent, does the authority
  path grant what the legacy resolver granted?

  Differential over all 14 policy fields, with a NAMED whitelist of
  intended de-widenings. That whitelist is the point — some divergence
  is the redesign working (a grant that was implicit becomes explicit),
  and an oracle that cannot tell those apart from regressions is worth
  nothing. Anything not on the list is a regression.
  """

  use ExUnit.Case, async: false

  alias Opus.AuthorityShim
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Source

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  # Fields where the two paths may legitimately differ, and why. A
  # divergence outside this map fails the oracle.
  @intended_dewidenings %{
    # The blob stores tools EXPANDED at consent time; the legacy resolver
    # re-merges the manifest's setup.policy at every read, so an action
    # added upstream later silently widened the old path (§3.1).
    allowed_tools: :manifest_auto_merge_removed,
    # nil meant "unchecked" in the legacy struct; edges name schemes
    # explicitly (freeze amendment 19).
    allowed_schemes: :nil_unchecked_vs_explicit,
    # Public-ness moved from a policy field to profiles.kind (§3.1).
    is_public: :moved_to_profile_kind
  }

  @all_fields ~w(allowed_domains allowed_methods allowed_private_ips allowed_schemes
                 allowed_paths allowed_actions allowed_tools timeout max_memory_bytes
                 max_request_size max_response_size rate_limit max_concurrent_tasks
                 batch_timeout is_public)a

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "equivalence_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, manifest \\ nil) do
    attrs = %{name: name, version: "1.0.0", type: "reagent"}
    attrs = if manifest, do: Map.put(attrs, :manifest, Jason.encode!(manifest)), else: attrs

    {:ok, component} = Compendium.Registry.publish_bytes(ctx, @wasm, attrs)
    component
  end

  defp authority_policy!(ctx, name) do
    source_ref = "reagent:local.#{name}"
    {:ok, [profile]} = Source.DB.profiles(ctx, source_ref)
    {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", "reagent")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

    {:ok, authority, _stamp} =
      Loader.load_root(ctx, profile, source: Source.DB, live: {:ok, live})

    AuthorityShim.policy_from_edge(authority)
  end

  defp legacy_policy!(ctx, name) do
    {:ok, policy, _meta} = Sanctum.Policy.get_effective(ctx, "reagent:local.#{name}")
    policy
  end

  defp compare(legacy, authority) do
    Enum.reduce(@all_fields, %{}, fn field, acc ->
      old = Map.get(legacy, field)
      new = Map.get(authority, field)

      if equivalent?(field, old, new),
        do: acc,
        else: Map.put(acc, field, {old, new})
    end)
  end

  # Lists are grants: order carries no meaning, so compare as sets.
  defp equivalent?(_field, old, new) when is_list(old) and is_list(new),
    do: Enum.sort(old) == Enum.sort(new)

  defp equivalent?(_field, old, new), do: old == new

  describe "bootstrap-minted consents grant what the legacy resolver granted" do
    test "a plain component diverges only where intended", %{ctx: ctx} do
      publish!(ctx, "equiv-plain")
      {:ok, _} = Bootstrap.run(ctx)

      divergences =
        compare(legacy_policy!(ctx, "equiv-plain"), authority_policy!(ctx, "equiv-plain"))

      unexpected = Map.drop(divergences, Map.keys(@intended_dewidenings))

      assert unexpected == %{}, """
      The authority path diverged from the legacy resolver on fields that
      are NOT known intended de-widenings:

      #{inspect(unexpected, pretty: true)}

      Either this is a regression, or the divergence is intended — in
      which case name it in @intended_dewidenings with the reason.
      """
    end

    test "a component with real capabilities carries them across", %{ctx: ctx} do
      publish!(ctx, "equiv-caps", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => ["api.example", "cdn.example"],
            "allowed_methods" => ["GET", "POST"],
            "allowed_paths" => ["data/"],
            "allowed_actions" => ["read", "write"],
            "timeout" => "45s"
          }
        }
      })

      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-caps")
      authority = authority_policy!(ctx, "equiv-caps")

      # The capabilities that matter travel identically.
      assert Enum.sort(authority.allowed_domains) == Enum.sort(legacy.allowed_domains)
      assert Enum.sort(authority.allowed_methods) == Enum.sort(legacy.allowed_methods)
      assert Enum.sort(authority.allowed_paths) == Enum.sort(legacy.allowed_paths)
      assert Enum.sort(authority.allowed_actions) == Enum.sort(legacy.allowed_actions)
      assert authority.timeout == legacy.timeout

      unexpected =
        legacy |> compare(authority) |> Map.drop(Map.keys(@intended_dewidenings))

      assert unexpected == %{}, inspect(unexpected, pretty: true)
    end

    test "every numeric limit survives the round trip", %{ctx: ctx} do
      publish!(ctx, "equiv-limits")
      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-limits")
      authority = authority_policy!(ctx, "equiv-limits")

      for field <- ~w(max_memory_bytes max_request_size max_response_size
                      max_concurrent_tasks timeout batch_timeout)a do
        assert Map.get(authority, field) == Map.get(legacy, field),
               "#{field}: legacy #{inspect(Map.get(legacy, field))} vs " <>
                 "authority #{inspect(Map.get(authority, field))}"
      end
    end
  end

  describe "the whitelist itself" do
    test "every named de-widening still has a reason" do
      for {field, reason} <- @intended_dewidenings do
        assert field in @all_fields, "#{field} is not a policy field"
        assert is_atom(reason) and reason != nil
      end
    end

    test "it covers exactly the three known divergences" do
      # Growing this list is a decision: it means the redesign narrowed
      # something else, and the migration guide should say so.
      assert map_size(@intended_dewidenings) == 3
    end
  end
end
