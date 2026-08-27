# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.BootstrapTest do
  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Source

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_bootstrap_#{:rand.uniform(1_000_000)}")
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

  defp publish!(ctx, name, type) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: type,
        description: "bootstrap test"
      })

    component
  end

  test "mints a loadable consent whose blob mirrors effective policy", %{ctx: ctx} do
    publish!(ctx, "boot-plain", "reagent")

    assert {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "reagent:local.boot-plain" in minted

    # The minted rows load through the real DB source into an Authority.
    {:ok, [profile]} =
      Source.DB.profiles(ctx, "reagent:local.boot-plain")

    assert profile.kind == :owner
    assert profile.status == :active

    {:ok, consent} = Source.DB.head_consent(ctx, profile.id)
    assert consent.revision == 1
    assert consent.scope == :versionless

    # The blob round-trips the frozen grammar.
    assert {:ok, %Blob{}} = Blob.parse(consent.resolved_policy)

    {:ok, component} = Compendium.Registry.get_latest(ctx, "boot-plain", "local", "reagent")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

    assert {:ok, %Authority{} = auth, _stamp} =
             Loader.load_root(ctx, profile, source: Source.DB, live: {:ok, live})

    assert auth.cursor == {:bound, "reagent:local.boot-plain"}
  end

  test "a second run skips what the first minted", %{ctx: ctx} do
    publish!(ctx, "boot-idem", "reagent")

    assert {:ok, %{minted: first}} = Bootstrap.run(ctx)
    assert "reagent:local.boot-idem" in first

    assert {:ok, %{minted: second, skipped: skipped}} = Bootstrap.run(ctx)
    refute "reagent:local.boot-idem" in second
    assert {"reagent:local.boot-idem", :already_bootstrapped} in skipped
  end

  test "every local component is considered, past the default listing page", %{ctx: ctx} do
    # Minimal rows are enough: a component that fails to activate lands in
    # `skipped`, so the witness is that all 101 were even looked at — the
    # default 100-row listing page once silently dropped the tail.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for i <- 1..101 do
      {:ok, _} =
        Arca.ComponentStorage.put_component(ctx, %{
          id: Ecto.UUID.generate(),
          name: "bulk-#{i}",
          version: "1.0.0",
          component_type: "reagent",
          description: "bulk",
          tags: "[]",
          category: "test",
          license: "MIT",
          digest: "sha256:#{:crypto.hash(:sha256, "bulk-#{i}") |> Base.encode16(case: :lower)}",
          size: 1,
          exports: "[]",
          manifest: "{}",
          publisher: "local",
          publisher_id: nil,
          source: "test",
          signature_verified: false,
          signer_identity: nil,
          signer_issuer: nil,
          inserted_at: now,
          updated_at: now
        })
    end

    assert {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert length(minted) + length(skipped) == 101
  end

  test "consents are insert-only by export list" do
    exports = Arca.ConsentStorage.__info__(:functions) |> Keyword.keys()

    refute Enum.any?(exports, fn name ->
             name |> Atom.to_string() |> String.starts_with?("update")
           end)
  end

  test "the head pointer only advances by compare-and-swap", %{ctx: ctx} do
    publish!(ctx, "boot-cas", "reagent")
    {:ok, _} = Bootstrap.run(ctx)

    {:ok, [profile]} = Source.DB.profiles(ctx, "reagent:local.boot-cas")
    {:ok, consent} = Source.DB.head_consent(ctx, profile.id)

    # A stale expectation cannot advance the head.
    assert {:error, :head_moved} =
             Arca.ProfileStorage.advance_head(
               ctx.athanor_id,
               profile.id,
               "cons_stale",
               "cons_new"
             )

    # The true expectation can.
    assert :ok =
             Arca.ProfileStorage.advance_head(ctx.athanor_id, profile.id, consent.id, consent.id)
  end
end
