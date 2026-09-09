# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDerivationTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.Source

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "shape_derivation_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, version, attrs \\ %{}) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(
        ctx,
        @wasm,
        Map.merge(%{name: name, version: version, type: "reagent"}, attrs)
      )

    component
  end

  defp head!(ctx, source_ref) do
    {:ok, [profile]} = Source.DB.profiles(ctx, source_ref)
    {:ok, consent} = Source.DB.head_consent(ctx, profile.id)
    {profile, consent}
  end

  # A needs manifest whose only between-version delta is the (prose) need
  # reason: the release digest moves, the shape does not.
  defp roll_manifest(reason) do
    %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => reason,
          "fields" => ["EXAMPLE_API_KEY"]
        }
      }
    }
  end

  defp live!(ctx, name) do
    {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", "reagent")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)
    live
  end

  test "consent-time and live derivation agree by construction", %{ctx: ctx} do
    publish!(ctx, "shape-pin", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)

    {_profile, consent} = head!(ctx, "reagent:local.shape-pin")

    assert ShapeDerivation.live_digest(ctx, "reagent:local.shape-pin") ==
             {:ok, consent.shape_digest}
  end

  test "a new release with an unchanged shape allows and records", %{ctx: ctx} do
    publish!(ctx, "shape-roll", "1.0.0", %{manifest: Jason.encode!(roll_manifest("original"))})
    {:ok, _} = Bootstrap.run(ctx)
    {profile, consent} = head!(ctx, "reagent:local.shape-roll")

    # A release whose security-relevant manifest changed: the reworded need
    # reason moves the release digest (needs is digest-covered) and with it
    # the activation — but reason is prose, so the consent shape is
    # untouched.
    publish!(ctx, "shape-roll", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

    live = live!(ctx, "shape-roll")
    refute live.graph == consent.activation

    {:ok, digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-roll")

    assert {:ok, _authority, stamp} =
             Loader.load_root(ctx, profile,
               source: Source.DB,
               live: {:ok, live},
               live_shape_digest: digest
             )

    # The NEW activation is what gets recorded on the run.
    assert stamp.activation_graph == live.graph
  end

  describe "the activation closure is part of the shape" do
    # The two halves of the same rule, and neither implies the other:
    # re-releasing the SOURCE must still ride an existing versionless
    # consent (that is what versionless means), while re-releasing a
    # DEPENDENCY must not (that is new code under an old grant).
    # The dep ref carries NO version. `Activation.resolve_dependency/2`
    # pins an explicit one and follows `latest_row/4` only for a
    # versionless ref — so a pinned dep cannot drift at all, and it is the
    # versionless one this rule is about.
    defp with_dep!(ctx, root_name, dep_name, dep_version, dep_reason) do
      publish!(ctx, dep_name, dep_version, %{
        manifest: Jason.encode!(roll_manifest(dep_reason))
      })

      publish!(ctx, root_name, "1.0.0", %{
        type: "formula",
        manifest:
          Jason.encode!(%{
            "dependencies" => %{
              "static" => [%{"ref" => "reagent:local.#{dep_name}"}]
            }
          })
      })
    end

    defp formula_head!(ctx, source_ref) do
      {:ok, [profile]} = Source.DB.profiles(ctx, source_ref)
      {:ok, consent} = Source.DB.head_consent(ctx, profile.id)
      {profile, consent}
    end

    test "a dependency re-released with different code demands fresh consent", %{ctx: ctx} do
      with_dep!(ctx, "dep-root", "dep-leaf", "1.0.0", "original")
      {:ok, _} = Bootstrap.run(ctx)
      {profile, _consent} = formula_head!(ctx, "formula:local.dep-root")

      # The dependency's release digest moves; the ROOT's manifest is
      # untouched. Before the closure entered the shape this was
      # indistinguishable from a source re-release: the live shape came
      # from the root's registry row alone, so `Decision.compare/6`
      # answered `{:allow_record, …}` and ran the new leaf under the blob
      # frozen at consent time.
      publish!(ctx, "dep-leaf", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

      {:ok, root} = Compendium.Registry.get_latest(ctx, "dep-root", "local", "formula")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, root)
      {:ok, digest} = ShapeDerivation.live_digest(ctx, "formula:local.dep-root")

      assert {:error, {:consent_required, payload}} =
               Loader.load_root(ctx, profile,
                 source: Source.DB,
                 live: {:ok, live},
                 live_shape_digest: digest
               )

      assert payload.profile_id == profile.id
    end

    test "re-releasing the source itself still rides the consent", %{ctx: ctx} do
      with_dep!(ctx, "src-root", "src-leaf", "1.0.0", "original")
      {:ok, _} = Bootstrap.run(ctx)
      {profile, _consent} = formula_head!(ctx, "formula:local.src-root")

      # Same dependency, new root release. The activation digest moves and
      # the shape does not, so this is the `{:allow_record, …}` arm — the
      # one the closure change must NOT break, or every versionless
      # consent would re-prompt on every publish.
      publish!(ctx, "src-root", "1.0.1", %{
        type: "formula",
        manifest:
          Jason.encode!(%{
            "description" => "reworded",
            "dependencies" => %{
              "static" => [%{"ref" => "reagent:local.src-leaf"}]
            }
          })
      })

      {:ok, root} = Compendium.Registry.get_latest(ctx, "src-root", "local", "formula")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, root)
      {:ok, digest} = ShapeDerivation.live_digest(ctx, "formula:local.src-root")

      assert {:ok, _authority, stamp} =
               Loader.load_root(ctx, profile,
                 source: Source.DB,
                 live: {:ok, live},
                 live_shape_digest: digest
               )

      assert stamp.activation_graph == live.graph
    end
  end

  test "without a live shape the same drift fails closed to consent_required", %{ctx: ctx} do
    publish!(ctx, "shape-dark", "1.0.0", %{manifest: Jason.encode!(roll_manifest("original"))})
    {:ok, _} = Bootstrap.run(ctx)
    {profile, _consent} = head!(ctx, "shape-dark" |> then(&"reagent:local.#{&1}"))

    publish!(ctx, "shape-dark", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

    assert {:error, {:consent_required, payload}} =
             Loader.load_root(ctx, profile,
               source: Source.DB,
               live: {:ok, live!(ctx, "shape-dark")}
             )

    assert payload.profile_id == profile.id
  end

  test "a changed shape under the same drift requires re-consent", %{ctx: ctx} do
    publish!(ctx, "shape-chg", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)
    {profile, consent} = head!(ctx, "reagent:local.shape-chg")

    # The new release declares more: its caps block asks for a tool the
    # empty-ask revision never carried, so the live shape moves away from
    # what revision 1 was shown.
    publish!(ctx, "shape-chg", "1.0.1", %{
      manifest: Jason.encode!(%{"caps" => %{"tools" => ["component.search"]}})
    })

    {:ok, live_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-chg")
    refute live_digest == consent.shape_digest

    assert {:error, {:consent_required, %{current_revision: 1}}} =
             Loader.load_root(ctx, profile,
               source: Source.DB,
               live: {:ok, live!(ctx, "shape-chg")},
               live_shape_digest: live_digest
             )
  end

  test "expand_tools is the bootstrap expansion, verbatim", %{ctx: ctx} do
    _ = ctx
    catalog = ShapeDerivation.all_tool_actions()

    assert ShapeDerivation.expand_tools(["*"]) == Enum.sort(Enum.uniq(catalog))

    assert ShapeDerivation.expand_tools(["component.*"]) ==
             Enum.sort(Enum.filter(catalog, &String.starts_with?(&1, "component.")))
  end

  describe "manifest-sourced shapes" do
    @needs_caps_manifest %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:anthropic.com",
          "reason" => "to call the API with your key",
          "fields" => ["ANTHROPIC_API_KEY"]
        }
      },
      "caps" => %{
        "egress" => %{"domains" => ["api.anthropic.com"]},
        "tools" => ["execution.run"],
        "limits" => %{"timeout" => "2m"}
      }
    }

    @tag :requires_opus_modules
    test "a needs/caps manifest sources the shape from its declarations", %{ctx: ctx} do
      publish!(ctx, "shape-caps", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})

      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-caps")

      assert input.slots == ["api_key"]
      assert [%{name: "api_key", type: "api_key:anthropic.com"}] = input.needs
      assert input.tool_actions == ["execution.run"]
      assert input.caps["egress.domains"] == ["api.anthropic.com"]
      assert input.caps["limits.timeout"] == "2m"
      # Empty asks are omitted — declaring nothing and asking for nothing
      # are the same shape.
      refute Map.has_key?(input.caps, "egress.methods")
    end

    test "a manifest with neither block derives the empty ask", %{ctx: ctx} do
      publish!(ctx, "shape-empty", "1.0.0")

      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-empty")

      assert input.needs == []
      assert input.caps == %{}
      assert input.slots == []
      assert input.tool_actions == []

      # Absent blocks and explicitly empty blocks are the same shape.
      publish!(ctx, "shape-empty-blocks", "1.0.0", %{
        manifest: Jason.encode!(%{"needs" => %{}, "caps" => %{}})
      })

      {:ok, explicit} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-empty-blocks")
      assert Map.delete(input, :source_ref) == Map.delete(explicit, :source_ref)
    end

    test "the reason text is not shape — editing it keeps the digest", %{ctx: ctx} do
      publish!(ctx, "shape-prose", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, before_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-prose")

      reworded =
        put_in(@needs_caps_manifest, ["needs", "api_key", "reason"], "reworded entirely")

      publish!(ctx, "shape-prose", "1.1.0", %{manifest: Jason.encode!(reworded)})
      {:ok, after_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-prose")

      assert before_digest == after_digest
    end

    test "a caps edit moves the digest; bootstrap and live agree", %{ctx: ctx} do
      publish!(ctx, "shape-caps-drift", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, _} = Bootstrap.run(ctx)

      {_profile, consent} = head!(ctx, "reagent:local.shape-caps-drift")
      {:ok, live_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-drift")
      assert consent.shape_digest == live_digest

      widened =
        put_in(
          @needs_caps_manifest,
          ["caps", "egress", "domains"],
          ["api.anthropic.com", "extra.example"]
        )

      publish!(ctx, "shape-caps-drift", "1.1.0", %{manifest: Jason.encode!(widened)})
      {:ok, drifted} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-drift")
      assert drifted != live_digest
    end

    @tag :requires_opus_modules
    test "a bootstrapped caps manifest loads through the production source", %{ctx: ctx} do
      publish!(ctx, "shape-caps-load", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, _} = Bootstrap.run(ctx)

      {profile, _consent} = head!(ctx, "reagent:local.shape-caps-load")

      {:ok, live_shape} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-load")

      assert {:ok, authority, _stamp} =
               Loader.load_root(ctx, profile,
                 source: Source.DB,
                 live: {:ok, live!(ctx, "shape-caps-load")},
                 live_shape_digest: live_shape
               )

      # The blob's ingress edge carries the caps ask, not a policy read.
      assert authority.resources.egress.domains == ["api.anthropic.com"]
      assert authority.resources.egress.schemes == ["https"]
      assert authority.resources.tools == ["execution.run"]

      # And no vault pointer was minted — a needs manifest has no legacy
      # grants, so the entry appears only when the operator binds one.
      assert authority.resources.vault == nil
    end
  end
end
