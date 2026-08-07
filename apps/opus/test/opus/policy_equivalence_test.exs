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

  Coverage spans every resolver source the legacy cascade knows — exact
  rows, name-level rows, type defaults, manifest setup.policy — and both
  consent-minting paths (bootstrap and the plan/preview/commit walk),
  because the drop deletes the whole cascade, not one branch of it.
  """

  use ExUnit.Case, async: false

  alias Opus.AuthorityShim
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.ShapeDerivation
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
    is_public: :moved_to_profile_kind,
    # A stored row with no rate_limit resolved to nil = unchecked in the
    # legacy path; blob node limits are total by frozen decision 4 (a nil
    # rate limit is unrepresentable — it could not be ceiling-clamped), so
    # the authority side carries the ceiling default instead of unlimited.
    rate_limit: :nil_unlimited_vs_ceiling
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

      # Policy rows are cached in ETS, which outlives the SQL sandbox.
      # Type-default keys are global (not test-unique like component
      # names), so a leaked entry poisons whichever test resolves that
      # type next.
      Arca.Cache.delete_match({:policy, :_, :_, :_})

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), test_path: test_path}
  end

  defp publish!(ctx, name, manifest \\ nil, attrs_over \\ %{}) do
    attrs = Map.merge(%{name: name, version: "1.0.0", type: "reagent"}, attrs_over)
    attrs = if manifest, do: Map.put(attrs, :manifest, Jason.encode!(manifest)), else: attrs

    {:ok, component} = Compendium.Registry.publish_bytes(ctx, @wasm, attrs)
    component
  end

  # A tincture enters through the directory-register ingress, the way real
  # ones do — publish_bytes is a wasm path and tinctures are asset trees.
  defp register_tincture!(ctx, name, base) do
    dir =
      Path.join([
        base,
        "src",
        "components",
        ctx.org_id,
        ctx.project_id,
        "tinctures",
        "local",
        name,
        "1.0.0"
      ])

    File.mkdir_p!(dir)

    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "equivalence fixture",
      "tincture" => %{"entry" => "index.html"},
      "schema" => %{"tables" => %{}, "queries" => %{}}
    }

    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html></html>")

    {:ok, _} = Compendium.Registry.register_from_directory(ctx, dir)
  end

  # The consent walk, exactly as the operator surfaces drive it.
  defp walk!(ctx, ref, decisions_over \\ %{}) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, decisions_over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    :ok
  end

  defp authority_load(ctx, name, type \\ "reagent") do
    source_ref = "#{type}:local.#{name}"
    {:ok, [profile]} = Source.DB.profiles(ctx, source_ref)
    {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", type)
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

    # Mirror Opus.Chain.load_authority: the live shape digest is what lets
    # a versionless consent survive an unchanged release and refuse a
    # changed one — loading without it would refuse both.
    live_shape =
      case ShapeDerivation.live_digest(ctx, source_ref) do
        {:ok, digest} -> digest
        {:error, _} -> nil
      end

    Loader.load_root(ctx, profile,
      source: Source.DB,
      live: {:ok, live},
      live_shape_digest: live_shape
    )
  end

  defp authority_policy!(ctx, name, type \\ "reagent") do
    case authority_load(ctx, name, type) do
      {:ok, authority, _stamp} ->
        AuthorityShim.policy_from_edge(authority)

      other ->
        flunk("authority load failed for #{type}:local.#{name}: #{inspect(other)}")
    end
  end

  defp legacy_policy!(ctx, name, type \\ "reagent") do
    {:ok, policy, _meta} = Sanctum.Policy.get_effective(ctx, "#{type}:local.#{name}")
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

  defp assert_only_intended(legacy, authority) do
    divergences = compare(legacy, authority)
    unexpected = Map.drop(divergences, Map.keys(@intended_dewidenings))

    assert unexpected == %{}, """
    The authority path diverged from the legacy resolver on fields that
    are NOT known intended de-widenings:

    #{inspect(unexpected, pretty: true)}

    Either this is a regression, or the divergence is intended — in
    which case name it in @intended_dewidenings with the reason.
    """

    divergences
  end

  describe "bootstrap-minted consents grant what the legacy resolver granted" do
    test "a plain component diverges only where intended", %{ctx: ctx} do
      publish!(ctx, "equiv-plain")
      {:ok, _} = Bootstrap.run(ctx)

      assert_only_intended(
        legacy_policy!(ctx, "equiv-plain"),
        authority_policy!(ctx, "equiv-plain")
      )
    end

    test "a component with real capabilities carries them across", %{ctx: ctx} do
      recommendation = %{
        "allowed_domains" => ["api.example", "cdn.example"],
        "allowed_methods" => ["GET", "POST"],
        "allowed_paths" => ["data/"],
        "allowed_actions" => ["read", "write"],
        "timeout" => "45s"
      }

      publish!(ctx, "equiv-caps", %{"setup" => %{"policy" => recommendation}})

      # A recommendation grants nothing until a setup flow stores it — the
      # legacy branch of the blob builder must mirror the STORED policy,
      # so apply it the way cyfr setup did. Without this both sides were
      # empty lists and the assertions below held vacuously.
      :ok =
        Sanctum.PolicyStore.put(
          ctx,
          "reagent:local.equiv-caps",
          Map.put(recommendation, "component_type", "reagent")
        )

      {:ok, _} = Bootstrap.run(ctx)
      assert legacy_policy!(ctx, "equiv-caps").allowed_domains != []

      legacy = legacy_policy!(ctx, "equiv-caps")
      authority = authority_policy!(ctx, "equiv-caps")

      # The capabilities that matter travel identically.
      assert Enum.sort(authority.allowed_domains) == Enum.sort(legacy.allowed_domains)
      assert Enum.sort(authority.allowed_methods) == Enum.sort(legacy.allowed_methods)
      assert Enum.sort(authority.allowed_paths) == Enum.sort(legacy.allowed_paths)
      assert Enum.sort(authority.allowed_actions) == Enum.sort(legacy.allowed_actions)
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
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

  describe "type defaults and name-level rows travel like exact rows" do
    test "a catalyst under an operator type default", %{ctx: ctx} do
      :ok =
        Sanctum.PolicyStore.put_type_default(ctx, :catalyst, %{
          component_type: "catalyst",
          allowed_domains: ["typedefault.example"],
          allowed_methods: ["GET"],
          timeout: "20s"
        })

      publish!(ctx, "equiv-cat-default", nil, %{type: "catalyst"})
      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-cat-default", "catalyst")
      authority = authority_policy!(ctx, "equiv-cat-default", "catalyst")

      # Non-vacuous: the type default actually resolved on both sides.
      assert legacy.allowed_domains == ["typedefault.example"]
      assert authority.allowed_domains == ["typedefault.example"]
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
    end

    test "a formula under an operator type default", %{ctx: ctx} do
      :ok =
        Sanctum.PolicyStore.put_type_default(ctx, :formula, %{
          component_type: "formula",
          allowed_tools: ["execution.run"],
          timeout: "40s"
        })

      publish!(ctx, "equiv-form-default", nil, %{type: "formula"})
      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-form-default", "formula")
      authority = authority_policy!(ctx, "equiv-form-default", "formula")

      # An exact action expands to itself, so even the whitelisted tools
      # field must agree here — asserted outside the whitelist on purpose.
      assert authority.allowed_tools == ["execution.run"]
      assert legacy.allowed_tools == ["execution.run"]
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
    end

    test "a name-level policy row", %{ctx: ctx} do
      # A capability field is name-level-configurable only when the
      # manifest's setup.policy declares it; the operator row then sets
      # the value. This is the realistic shape for a catalyst.
      publish!(
        ctx,
        "equiv-name",
        %{
          "setup" => %{
            "policy" => %{
              "allowed_domains" => ["manifest-default.example"],
              "allowed_methods" => ["GET"]
            }
          }
        },
        %{type: "catalyst"}
      )

      :ok =
        Sanctum.PolicyStore.put(ctx, "catalyst:local.equiv-name", %{
          component_type: "catalyst",
          allowed_domains: ["namelevel.example"],
          allowed_methods: ["POST"],
          timeout: "35s"
        })

      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-name", "catalyst")
      authority = authority_policy!(ctx, "equiv-name", "catalyst")

      assert legacy.allowed_domains == ["namelevel.example"]
      assert authority.allowed_domains == ["namelevel.example"]
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
    end
  end

  describe "walk-minted consents grant what the legacy resolver granted" do
    test "a plan/preview/commit revision matches the resolver", %{ctx: ctx} do
      publish!(ctx, "equiv-walk", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => ["walk.example"],
            "allowed_paths" => ["data/"],
            "allowed_actions" => ["read"],
            "timeout" => "50s"
          }
        }
      })

      :ok = walk!(ctx, "reagent:local.equiv-walk")

      legacy = legacy_policy!(ctx, "equiv-walk")
      authority = authority_policy!(ctx, "equiv-walk")

      assert Enum.sort(authority.allowed_domains) == Enum.sort(legacy.allowed_domains)
      assert Enum.sort(authority.allowed_paths) == Enum.sort(legacy.allowed_paths)
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
    end

    test "a tincture under a type default, minted through the walk", %{
      ctx: ctx,
      test_path: test_path
    } do
      :ok =
        Sanctum.PolicyStore.put_type_default(ctx, :tincture, %{
          component_type: "tincture",
          rate_limit: %{requests: 42, window: "1m"},
          timeout: "25s"
        })

      register_tincture!(ctx, "equiv-tin", test_path)
      :ok = walk!(ctx, "tincture:local.equiv-tin")

      legacy = legacy_policy!(ctx, "equiv-tin", "tincture")
      authority = authority_policy!(ctx, "equiv-tin", "tincture")

      assert legacy.rate_limit == %{requests: 42, window: "1m"}
      assert authority.rate_limit == legacy.rate_limit
      assert authority.timeout == legacy.timeout

      assert_only_intended(legacy, authority)
    end
  end

  describe "the manifest auto-merge path is a named de-widening, not a regression" do
    test "a setup.policy tool pattern lands in the allowed_tools bucket", %{ctx: ctx} do
      publish!(ctx, "equiv-merge", %{
        "setup" => %{"policy" => %{"allowed_tools" => ["component.*"]}}
      })

      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-merge")
      authority = authority_policy!(ctx, "equiv-merge")

      divergences = assert_only_intended(legacy, authority)

      # The divergence is present and has the documented shape: the legacy
      # side carries the raw pattern (re-merged at every read), the blob
      # side carries the consent-time expansion — concrete actions only.
      assert {legacy_tools, authority_tools} = divergences[:allowed_tools]
      assert "component.*" in legacy_tools
      refute "component.*" in authority_tools
      assert Enum.any?(authority_tools, &String.starts_with?(&1, "component."))
      assert Enum.all?(authority_tools, &(not String.contains?(&1, "*")))
    end

    test "an action added upstream after consent widens legacy but never the authority",
         %{ctx: ctx} do
      publish!(ctx, "equiv-widen", %{
        "setup" => %{"policy" => %{"allowed_tools" => ["execution.run"]}}
      })

      {:ok, _} = Bootstrap.run(ctx)
      assert %{} = authority_policy!(ctx, "equiv-widen")

      # A new release asks for more. The legacy resolver hands it over at
      # the next read; the frozen consent refuses to load until re-consent.
      publish!(
        ctx,
        "equiv-widen",
        %{"setup" => %{"policy" => %{"allowed_tools" => ["execution.run", "component.list"]}}},
        %{version: "1.1.0"}
      )

      legacy = legacy_policy!(ctx, "equiv-widen")
      assert "component.list" in legacy.allowed_tools

      assert {:error, {:consent_required, %{current_revision: 1}}} =
               authority_load(ctx, "equiv-widen")
    end
  end

  describe "caps-sourced blobs grant what the legacy resolver granted" do
    # Twin-block fixtures: setup.policy and caps declare identical content.
    # The legacy comparator is the component as it actually ran — with its
    # recommendation APPLIED to a stored policy row, which is what every
    # setup flow (cyfr setup, the Porta auto-grant, the Prism forms) did.
    # A recommendation that was never applied granted nothing legacy-side
    # except tools; comparing against that would call the caps grant a
    # widening when it is the setup step made explicit.
    test "a twin-block manifest with its recommendation applied diverges only where intended",
         %{ctx: ctx} do
      recommendation = %{
        "allowed_domains" => ["twin.example"],
        "allowed_methods" => ["GET", "POST"],
        "allowed_paths" => ["data/"],
        "allowed_actions" => ["read"],
        "timeout" => "45s"
      }

      publish!(ctx, "equiv-twin", %{
        "setup" => %{"policy" => recommendation},
        "caps" => %{
          "egress" => %{"domains" => ["twin.example"], "methods" => ["GET", "POST"]},
          "storage" => %{"paths" => ["data/"], "actions" => ["read"]},
          "limits" => %{"timeout" => "45s"}
        }
      })

      :ok =
        Sanctum.PolicyStore.put(
          ctx,
          "reagent:local.equiv-twin",
          Map.put(recommendation, "component_type", "reagent")
        )

      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-twin")
      authority = authority_policy!(ctx, "equiv-twin")

      # Non-vacuous on both sides: the stored row fed legacy, caps fed the blob.
      assert legacy.allowed_domains == ["twin.example"]
      assert Enum.sort(authority.allowed_domains) == Enum.sort(legacy.allowed_domains)
      assert Enum.sort(authority.allowed_paths) == Enum.sort(legacy.allowed_paths)
      assert authority.timeout == "45s"
      assert legacy.timeout == "45s"

      assert_only_intended(legacy, authority)
    end

    test "a caps-sourced tool ask expands like the legacy merge did", %{ctx: ctx} do
      publish!(ctx, "equiv-twin-tools", %{
        "setup" => %{"policy" => %{"allowed_tools" => ["component.*"]}},
        "caps" => %{"tools" => ["component.*"]}
      })

      {:ok, _} = Bootstrap.run(ctx)

      legacy = legacy_policy!(ctx, "equiv-twin-tools")
      authority = authority_policy!(ctx, "equiv-twin-tools")
      divergences = assert_only_intended(legacy, authority)

      # Same documented divergence shape as the setup.policy-only case:
      # raw pattern legacy-side, consent-time expansion blob-side.
      assert {legacy_tools, authority_tools} = divergences[:allowed_tools]
      assert "component.*" in legacy_tools
      refute "component.*" in authority_tools
      assert Enum.any?(authority_tools, &String.starts_with?(&1, "component."))
    end
  end

  describe "the whitelist itself" do
    test "every named de-widening still has a reason" do
      for {field, reason} <- @intended_dewidenings do
        assert field in @all_fields, "#{field} is not a policy field"
        assert is_atom(reason) and reason != nil
      end
    end

    test "it covers exactly the four known divergences" do
      # Growing this list is a decision: it means the redesign narrowed
      # something else, and the migration guide should say so. The fourth
      # entry (rate_limit) was that decision, made when widening this
      # oracle beyond reagents surfaced it: stored rows without a rate
      # limit were unlimited; blob limits are total, so they get the
      # ceiling. The upgrade guide's "intentionally narrows" list names it.
      assert map_size(@intended_dewidenings) == 4
    end
  end
end
