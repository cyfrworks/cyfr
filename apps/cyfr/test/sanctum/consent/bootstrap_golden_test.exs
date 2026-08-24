# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BootstrapGoldenTest do
  @moduledoc """
  What baseline consent grants, pinned: every athanor is minted from the
  tracked bundle, and each executable local component gets one consent
  whose blob (`resolved_policy`, already JCS) is a pure function of the
  bundle's manifests. This compares those blobs byte for byte against
  `test/support/fixtures/consent_golden.json` — a diff is a deliberate
  change to what strangers on a `*` server are granted, and is bumped by
  re-recording (`CYFR_GOLDEN_RECORD=1 mix test <this file>`).

  Only the blob is golden: the activation and its digests move with every
  wasm rebuild, so they are asserted present, not pinned.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap, Source}

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle Path.join(@repo_root, "components/_bundle")
  @golden Path.expand("../../support/fixtures/consent_golden.json", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_golden_#{:rand.uniform(1_000_000)}")
    bundle_dir = Path.join(test_dir, "bundle")
    copy_bundle!(bundle_dir)

    prev_base = Application.get_env(:cyfr, :base_path)
    prev_bundle = Application.get_env(:cyfr, :bundle_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :bundle_path, bundle_dir)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :bundle_path, prev_bundle)
      File.rm_rf!(test_dir)
    end)

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Golden",
        slug: "golden-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    :ok = Compendium.AthanorSeeder.seed(athanor)

    # The server's own mint: `granted_by` is the constant "system:bootstrap".
    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: athanor.id, scope: :athanor)
    {:ok, ctx: ctx}
  end

  test "the consent blob minted per bundle component is byte-stable", %{ctx: ctx} do
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert minted != []

    blobs =
      Map.new(minted, fn ref ->
        {:ok, [profile]} = Source.DB.profiles(ctx, ref)
        {:ok, row, _refs} = Arca.ConsentStorage.get_head(ctx.athanor_id, profile.id)
        assert row.granted_by == "system:bootstrap"
        {:ok, consent} = Source.DB.head_consent(ctx, profile.id)
        assert is_map(consent.activation) and consent.activation != %{}
        assert is_binary(consent.shape_digest) and consent.shape_digest != ""
        {ref, consent.resolved_policy}
      end)

    if System.get_env("CYFR_GOLDEN_RECORD") == "1" do
      File.write!(@golden, Jason.encode!(blobs, pretty: true) <> "\n")
      flunk("golden re-recorded at #{@golden}; run again without CYFR_GOLDEN_RECORD")
    end

    assert File.exists?(@golden), "no golden fixture; record one with CYFR_GOLDEN_RECORD=1"
    golden = @golden |> File.read!() |> Jason.decode!()

    assert Map.keys(blobs) |> Enum.sort() == Map.keys(golden) |> Enum.sort(),
           "the set of bundle components bootstrap mints for changed"

    for {ref, blob} <- blobs do
      assert blob == golden[ref],
             "baseline consent for #{ref} changed — if deliberate, re-record with CYFR_GOLDEN_RECORD=1"
    end
  end

  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      target = Path.join(dest, Path.relative_to(src, @bundle))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
