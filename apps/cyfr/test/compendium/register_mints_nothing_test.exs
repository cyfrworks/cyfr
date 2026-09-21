# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegisterMintsNothingTest do
  @moduledoc """
  `component.register` grants no consent, and cannot be reached in-chain.

  Registration scans the tenant components tree without minting consent.
  Only provisioning the operator's seed bundle may bootstrap consent;
  filesystem provenance alone does not establish trusted seed content.

  Both halves are pinned here because neither implies the other:
  `consent: :staging` refuses `Context.plane: :guest`, which stops a WASM
  formula but not AQUA, which runs host-side with the person's own
  external context.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Ops.Catalog

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "register_no_mint_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "the register action's reach" do
    test "is refused in-chain, so an approved AQUA proposal cannot run it" do
      assert Catalog.in_chain_refused?("component", "register"),
             """
             `component.register` is reachable in-chain again.

             An approved AQUA proposal executes inside the chain, so this
             re-opens the path where a catalyst stages bytes under
             `components/local/` and the agent is talked into indexing
             them. `consent: :staging` does NOT cover this: it refuses
             `Context.plane: :guest`, and AQUA is not a guest.
             """
    end

    test "still reachable from the external plane, so console and CLI keep working" do
      refute Catalog.in_chain_refused?("component", "list"),
             "sanity: a plainly in-chain action must not read as refused"

      {:ok, {_module, definition}} = Catalog.lookup("component")
      register = Map.fetch!(definition.annotations.actions, "register")

      assert :external in register.planes
      refute :in_chain in register.planes

      # `:staging` admits :oidc AND :api_key (`Sanctum.Consent.Authz`), so
      # scripted registration from `codex` survives; `:interactive` would
      # have taken it away.
      assert register.consent == :staging
    end
  end

  describe "registering a component" do
    test "mints no profile and no consent — it stays uninvocable until a walk", %{ctx: ctx} do
      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "no-mint-please",
          version: "1.0.0",
          type: "reagent",
          description: "register must not consent to this"
        })

      ref = "reagent:local.no-mint-please"

      # Nothing has consented yet — the component exists, and is inert.
      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)

      # Now run the action itself. This is the whole point: the scanner
      # sees a local component with no profile and must leave it that way.
      {:ok, result} = Compendium.MCP.handle("component", ctx, %{"action" => "register"})
      assert result.status == "scanned"

      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref),
             "component.register must not mint an owner profile"

      # The response must not advertise bootstrapped consent.
      refute Map.has_key?(result, :bootstrapped),
             "the register response still reports minted consents"
    end

    test "provisioning's seed mint is untouched — that path still consents", %{ctx: ctx} do
      # The counterpart: `Bootstrap.run/1` is what provisioning calls, and
      # it must still mint a unit the seed ships, or a fresh athanor
      # arrives with nothing usable. A published-but-unshipped unit is
      # not the seed.
      Cyfr.Test.SeedBundle.isolate!()

      {:ok, _component} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "reagent", "local", "seedish", "1.0.0",
          manifest: %{
            "name" => "seedish",
            "type" => "reagent",
            "version" => "1.0.0",
            "publisher" => "local",
            "description" => "stands in for a bundle component"
          },
          wasm: @wasm
        )

      assert {:ok, %{minted: minted}} = Sanctum.Consent.Bootstrap.run(ctx)
      assert "reagent:local.seedish" in minted
    end
  end

  describe "the attack this closes" do
    # The scenario the whole change exists for. A catalyst holding a
    # storage write grant over `components/` can put bytes on the athanor's
    # own overlay tree — `Compendium.Source`'s own doc says `"filesystem"`
    # means "bundled seed OR the athanor's own overlay", so the scanner
    # could not tell them from the operator's. With `register` minting,
    # writing bytes and calling it was a self-service owner consent over
    # caps the component's own manifest declared.
    #
    # Bytes are written here through `Arca.put` under the internal-writes
    # scope, which is what a storage grant reduces to at the seam.
    test "bytes written straight onto the overlay tree earn no consent", %{ctx: ctx} do
      unit = ["components", "reagents", "local", "self-served", "1.0.0"]

      manifest =
        Jason.encode!(%{
          "name" => "self-served",
          "version" => "1.0.0",
          "type" => "reagent",
          "caps" => %{"egress" => %{"domains" => ["*"]}}
        })

      {:ok, _} =
        Arca.Overlay.commit_unit(
          Sanctum.Context.actor(ctx),
          unit,
          {:files, [{["cyfr-manifest.json"], manifest}, {["reagent.wasm"], @wasm}]},
          cap: :exempt
        )

      ref = "reagent:local.self-served"
      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)

      # The scanner runs and indexes it — that is its job.
      {:ok, _} = Compendium.MCP.handle("component", ctx, %{"action" => "register"})

      # But it consents to nothing. An `egress.domains: ["*"]` a catalyst
      # wrote for itself is exactly what must not arrive pre-approved.
      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref),
             "bytes a catalyst could have written earned an owner consent"
    end
  end

  test "Bootstrap exposes no ref-targeted mint" do
    # `run_for/2` took caller-named refs and minted owner consent for them.
    # That is the shape the hole had; a new caller would reopen it.
    refute function_exported?(Sanctum.Consent.Bootstrap, :run_for, 2),
           "Sanctum.Consent.Bootstrap.run_for/2 is back — see this module's doc"
  end
end
