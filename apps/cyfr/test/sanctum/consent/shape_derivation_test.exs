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
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

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

  test "a new release with an unchanged shape allows and records (§2.6)", %{ctx: ctx} do
    publish!(ctx, "shape-roll", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)
    {profile, consent} = head!(ctx, "reagent:local.shape-roll")

    # A release whose security-relevant manifest changed: new release
    # digest, new activation — but the consent shape is untouched.
    publish!(ctx, "shape-roll", "1.0.1", %{
      manifest: Jason.encode!(%{"wasi" => %{"http" => true}})
    })

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

  test "without a live shape the same drift fails closed to consent_required", %{ctx: ctx} do
    publish!(ctx, "shape-dark", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)
    {profile, _consent} = head!(ctx, "shape-dark" |> then(&"reagent:local.#{&1}"))

    publish!(ctx, "shape-dark", "1.0.1", %{
      manifest: Jason.encode!(%{"wasi" => %{"http" => true}})
    })

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

    # The new release declares more: its setup.policy widens the tool
    # grants through the manifest auto-merge, so the live shape moves away
    # from what revision 1 was shown.
    publish!(ctx, "shape-chg", "1.0.1", %{
      manifest:
        Jason.encode!(%{
          "setup" => %{"policy" => %{"allowed_tools" => ["component.search"]}}
        })
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
end
