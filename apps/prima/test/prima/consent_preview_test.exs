# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentPreviewTest do
  @moduledoc """
  The consent preview as data (`tests/fixtures/consent_preview.json`): the
  preview holding a row of every kind reads and writes back to itself; a
  row of an unknown kind, a sentence, a narrowed kind that cannot narrow,
  an origin outside the enum and every other malformed row are refused. A
  credential row is one binding: its source, destination, disclosure,
  suggestion, choice, account, key and lifetime travel with it, and a row
  missing its source, its key or its lifetime is refused.
  """

  use ExUnit.Case, async: true

  alias Prima.ConsentPreview
  alias Prima.ConsentPreview.Row

  @vectors Path.expand("../../../../tests/fixtures/consent_preview.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  test "the version, kinds and narrowable kinds are the fixture's" do
    v = vectors()
    assert v["version"] == ConsentPreview.version()
    assert v["kinds"] == Enum.map(ConsentPreview.kinds(), &Atom.to_string/1)
    assert v["narrowable_kinds"] == Enum.map(ConsentPreview.narrowable_kinds(), &Atom.to_string/1)
  end

  test "the preview holds a row of every kind and writes back to itself" do
    preview = vectors()["preview"]

    assert {:ok, %ConsentPreview{rows: rows, origins: origins} = decoded} =
             ConsentPreview.decode(preview)

    assert ConsentPreview.encode(decoded) == preview

    assert rows |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(ConsentPreview.kinds())

    assert origins == [:interactive, :programmatic]

    for %Row{kind: kind, narrowed: true} <- rows,
        do: assert(kind in ConsentPreview.narrowable_kinds())

    assert ConsentPreview.new(rows, origins, decoded.commit_digest) == {:ok, decoded}
  end

  test "a credential is one row per binding, and a stream one per subject" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])

    weather =
      for %Row{kind: :credential, values: %{"name" => "weather-api"} = values} = row <- rows,
          do: {Row.identity(row), values["edge"]}

    assert [
             {{:credential, "reagent:local.weather", "reagent:local.weather|@ingress|default"},
              "@ingress"},
             {{:credential, "reagent:local.weather",
               "reagent:local.weather|reagent:local.geo|name:Geo account"}, "reagent:local.geo"}
           ] = weather

    deltas =
      for %Row{kind: :streams, values: %{"name" => "executions.deltas"}} = row <- rows,
          do: Row.identity(row)

    assert [{:streams, _, _, "*"}, {:streams, _, _, "exe_1"}] = deltas

    # A stream that names no subject is its own row too.
    assert Enum.any?(rows, &(&1.kind == :streams and Row.identity(&1) |> elem(3) |> is_nil()))
  end

  test "a wildcard tools row names every tool alone and is never narrowed" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])

    assert [%Row{node: "reagent:local.geo", narrowed: false}] =
             Enum.filter(rows, &(&1.kind == :tools and &1.values["tools"] == Row.wildcard()))

    tools = Enum.find(rows, &(&1.kind == :tools))

    for spelled <- [["file.read", "*"], ["*", "*"]] do
      assert Row.decode(Row.encode(%{tools | values: %{"tools" => spelled}})) ==
               {:error, {:invalid_field, "tools"}}
    end
  end

  test "origins are answered in the enum's order" do
    preview = Map.put(vectors()["preview"], "origins", ["webhook", "interactive"])

    assert {:ok, %ConsentPreview{origins: [:interactive, :webhook]} = decoded} =
             ConsentPreview.decode(preview)

    assert ConsentPreview.encode(decoded)["origins"] == ["interactive", "webhook"]
  end

  test "every origin spelling is admitted, and every other refused" do
    v = vectors()
    preview = v["preview"]

    for spelling <- v["origins"]["spellings"] do
      assert {:ok, _preview} = ConsentPreview.decode(Map.put(preview, "origins", [spelling])),
             spelling
    end

    for spelling <- v["origins"]["invalid"] do
      assert {:error, {:unknown_origin, ^spelling}} =
               ConsentPreview.decode(Map.put(preview, "origins", [spelling]))
    end
  end

  test "every refusal is refused with its reason" do
    for %{"name" => name, "preview" => preview, "error" => error} <- vectors()["refusals"] do
      assert tag(ConsentPreview.decode(preview)) == error, name
    end

    assert ConsentPreview.decode("rows") == {:error, {:invalid_field, "preview"}}
  end

  test "a credential row names its source, destination, lifetime and the rest" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])
    credentials = for %Row{kind: :credential, values: values} <- rows, do: values

    assert Enum.map(credentials, & &1["source"]) |> Enum.sort() ==
             Enum.sort(ConsentPreview.Row.sources() ++ ["own"])

    assert Enum.map(credentials, & &1["lifetime"]["kind"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(ConsentPreview.Row.lifetimes())

    for values <- credentials do
      assert {:ok, destination} = Prima.Destination.from_map(values["destination"])
      assert Prima.Destination.to_map(destination) == values["destination"]
      assert is_boolean(values["disclosed"]) and is_boolean(values["suggested"])
      assert is_boolean(values["choice_required"])
    end

    # The provider is absent where the entry names none; the account only on a named binding.
    assert Enum.any?(credentials, &(not Map.has_key?(&1, "provider")))

    assert [%{"connection" => "Geo account"}] =
             Enum.filter(credentials, &Map.has_key?(&1, "connection"))
  end

  test "a credential row missing its source, binding key or lifetime is refused" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])
    [credential | _] = for %Row{kind: :credential} = row <- rows, do: row

    for field <- ["source", "binding_key", "lifetime", "destination", "disclosed"] do
      row = Row.encode(credential) |> update_in(["values"], &Map.delete(&1, field))
      assert Row.decode(row) == {:error, {:missing_field, field}}, field
    end
  end

  test "no kind carries a sentence field" do
    for %{"kind" => kind} = row <- vectors()["preview"]["rows"] do
      for field <- ["summary", "sentence", "description"] do
        assert {:error, {:unknown_field, ^field}} =
                 Row.decode(put_in(row, ["values", field], "x")),
               kind
      end
    end
  end
end
