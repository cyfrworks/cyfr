# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PublishedUnitConsumersTest do
  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base =
      Path.join(
        System.tmp_dir!(),
        "published_unit_consumers_#{System.unique_integer([:positive])}"
      )

    previous = Application.fetch_env!(:arca, :base_path)
    ctx = Sanctum.TestContext.local()
    actor = Sanctum.Context.actor(ctx)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, previous)
      Arca.Usage.invalidate(actor)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, base)
    Arca.Usage.invalidate(actor)
    unit = ["components", "reagents", "local", "review-sizes", "1.0.0"]

    assert {:ok, _} =
             Arca.Overlay.commit_unit(
               actor,
               unit,
               {:files,
                [
                  {["cyfr-manifest.json"], ~s({"type":"reagent","version":"1.0.0"})},
                  {["README.md"], "abc"}
                ]},
               cap: :exempt
             )

    {:ok, ctx: ctx, actor: actor, unit: unit}
  end

  test "Files lists the size of a published unit's file", %{actor: actor, unit: unit} do
    path = Enum.join(unit, "/")
    assert {:ok, %{content: "abc", size: 3}} = Arca.Files.read(actor, path <> "/README.md")
    assert {:ok, %{entries: entries}} = Arca.Files.list(actor, path)

    assert %{name: "README.md", kind: :file, size: 3} =
             Enum.find(entries, &(&1.name == "README.md"))
  end

  test "registry derivation refuses a published manifest that decodes to a non-object", %{
    ctx: ctx,
    actor: actor,
    unit: unit
  } do
    assert :ok = Arca.put(actor, unit ++ ["cyfr-manifest.json"], ~s(["not", "a", "manifest"]))
    assert {:error, {:invalid_manifest, _}} = Compendium.Registry.register_from_arca(ctx, unit)
  end

  test "a public guest can replace an existing unit file without charging its bytes again",
       %{ctx: ctx, actor: actor, unit: unit} do
    Arca.Usage.invalidate(actor)
    assert {:ok, %{bytes: held}} = Arca.Usage.scope_usage(actor, "components")

    scope = %{
      ctx: ctx,
      edge: %Prima.Authority.Blob.Edge{storage: %{paths: ["components/"], actions: ["write"]}},
      limits: Prima.Limits.defaults(:reagent),
      quota: %{max_bytes: held, max_files: 100},
      hold: fn %{io: io} ->
        case io.() do
          :ok -> {:ok, {:confirmed, :ok}}
          {:error, _} = refused -> {:ok, {:failed, refused}}
        end
      end
    }

    assert {:ok, %{"written" => true}} =
             Opus.GuestStorage.run(scope, :write, %{
               "path" => Enum.join(unit ++ ["README.md"], "/"),
               "content" => Base.encode64("xyz")
             })

    assert {:ok, "xyz"} = Arca.get(actor, unit ++ ["README.md"])
  end
end
