# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.ComponentsStreamTest do
  @moduledoc """
  `components.changes`, the registry as a canvas reads it, riding the
  athanor's components topic: every installed version first, as the
  `list` action reads it, and then each version the registry installs,
  removes or pushes, by its versionless ref, type, name and version.
  Every refresh item and live payload is read as a canvas reads it:
  projected, passed through JSON and held to the declared shape.
  """
  use ExUnit.Case, async: false

  alias Compendium.Providers.Component
  alias Cyfr.Bus.Components
  alias Prima.Canvas.Shape
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_components_stream_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:arca, :base_path)
    on_exit(fn -> Application.put_env(:arca, :base_path, prev_base) end)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()
    actor = Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.components(actor))
    {:ok, ctx: ctx}
  end

  defp publish!(ctx, name, version) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: version,
        type: "reagent"
      })
  end

  test "is declared by the component domain on the components topic, shaped and refreshed" do
    assert {:ok, {Compendium.Provider, stream}} =
             Sanctum.Catalog.lookup_stream("components.changes")

    assert {stream.topic, stream.subject, stream.bind, stream.filter, stream.refresh} ==
             {:components, nil, nil, nil, {Component, :installed}}

    assert stream.projection ==
             ~w(kind ref type name icon version update_available grant_current)

    assert stream.shape["fields"]["kind"]["values"] ==
             Enum.map(Components.kinds(), &Atom.to_string/1)

    assert "stream:components.changes" in Enum.find(Cyfr.Bus.topics(), &(&1.key == :components)).consumers

    {:ok, %{streams: listed}} = Compendium.Canvas.catalog(Sanctum.TestContext.local())
    assert %{shape: shape, refresh: true} = Enum.find(listed, &(&1.name == "components.changes"))
    assert shape == stream.shape
  end

  test "the refresh is every installed version as the listing reads it", %{ctx: ctx} do
    publish!(ctx, "fetch", "1.0.0")

    assert {:ok, items} = Component.installed(ctx, nil)
    read = Enum.map(items, &read_as/1)

    assert %{
             "kind" => "installed",
             "ref" => "reagent:local.fetch",
             "type" => "reagent",
             "name" => "fetch",
             "version" => "1.0.0",
             "icon" => nil,
             "update_available" => false,
             "grant_current" => nil
           } in read

    assert {:error, :no_athanor} = Component.installed(%{ctx | athanor_id: nil}, nil)
  end

  test "a registry install and removal reach the stream by the version they name", %{ctx: ctx} do
    for action <- [:install, :remove] do
      :telemetry.execute([:cyfr, :compendium, :component, action], %{count: 1}, %{
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id,
        name: "later",
        version: "2.0.0",
        publisher: "local",
        component_type: "reagent",
        digest: "sha256:" <> String.duplicate("0", 64)
      })
    end

    for kind <- ["installed", "removed"] do
      assert_receive %Components{} = payload

      assert %{
               "kind" => ^kind,
               "ref" => "reagent:local.later",
               "type" => "reagent",
               "name" => "later",
               "version" => "2.0.0"
             } = read_as(payload)
    end
  end

  test "a bare change asks the reader to read again, and still fits the shape" do
    actor = Prima.Actor.in_athanor("ath_components_stream")
    data = read_as(Components.new(actor, :changed))
    assert data["kind"] == "changed"
    assert Enum.all?(Map.delete(data, "kind"), fn {_field, value} -> is_nil(value) end)
  end

  # A refresh item or a live payload as a canvas reads it.
  defp read_as(payload) do
    {:ok, {_provider, stream}} = Sanctum.Catalog.lookup_stream("components.changes")

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_components"
    }

    payload = if is_struct(payload), do: Map.from_struct(payload), else: payload
    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    data
  end
end
