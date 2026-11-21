# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentPreviewTest do
  @moduledoc """
  The consent preview as data (`tests/fixtures/consent_preview.json`): the
  preview holding a row of every kind reads and writes back to itself; a
  row of an unknown kind, a sentence, a narrowed kind that cannot narrow
  and every other malformed row are refused, and so is a preview naming
  who may start the component, which no grant says. A
  credential row is one binding: its source, destination, disclosure,
  suggestion, choice, account, key and lifetime travel with it, and a row
  missing its source, its key or its lifetime is refused. A preview names
  the head's bindings it removes, each as the head's row holds it, an
  empty list when it removes none and a refusal when it says nothing.
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

  test "the kinds are these ten, in this order, and four of them narrow" do
    assert vectors()["kinds"] ==
             ~w(credential egress storage tools tool_servers limits frame streams system_actions
                controls)

    assert vectors()["narrowable_kinds"] == ~w(egress storage tools limits)
  end

  test "every kind decodes from its row, and only a narrowable one may be narrowed" do
    %{"kinds" => kinds, "narrowable_kinds" => narrowable, "preview" => %{"rows" => rows}} =
      vectors()

    row_of = fn name -> Enum.find(rows, &(&1["kind"] == name)) end

    for name <- kinds do
      assert {:ok, %Row{kind: kind}} = Row.decode(row_of.(name)), name
      assert Atom.to_string(kind) == name
    end

    for name <- kinds -- narrowable do
      assert {:error, {:not_narrowable, kind}} = Row.decode(%{row_of.(name) | "narrowed" => true})
      assert Atom.to_string(kind) == name
    end

    assert Row.decode(%{hd(rows) | "kind" => "sentence"}) ==
             {:error, {:unknown_kind, "sentence"}}
  end

  test "the preview holds a row of every kind and writes back to itself" do
    preview = vectors()["preview"]

    assert {:ok, %ConsentPreview{rows: rows} = decoded} =
             ConsentPreview.decode(preview)

    assert ConsentPreview.encode(decoded) == preview

    assert rows |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(ConsentPreview.kinds())

    for %Row{kind: kind, narrowed: true} <- rows,
        do: assert(kind in ConsentPreview.narrowable_kinds())

    assert ConsentPreview.new(rows, decoded.commit_digest, preview["removed"]) ==
             {:ok, decoded}
  end

  test "the preview names each binding of the head it removes, as the head's row holds it" do
    preview = vectors()["preview"]
    assert {:ok, decoded} = ConsentPreview.decode(preview)
    removed = ConsentPreview.encode(decoded)["removed"]
    assert [_ | _] = removed
    assert removed == preview["removed"]

    assert removed |> Enum.map(& &1["binding_key"]) ==
             Enum.sort(Enum.map(removed, & &1["binding_key"]))

    for item <- removed do
      assert item["binding_key"] ==
               Prima.Authority.Blob.binding_key(item["node"], item["edge"], item["connection"])

      assert Enum.count(~w(entry_id share_id via), &Map.has_key?(item, &1)) == 1
    end

    # A share is removed by its id, its name the owner's words, as its row names it.
    assert [%{"share_id" => "shr_old_market", "source" => "share", "name" => "Shared by Terry"}] =
             Enum.filter(removed, &Map.has_key?(&1, "share_id"))

    # A need that cannot be told is null, never absent; an entry that
    # cannot be read names neither its name nor its source.
    assert Enum.any?(removed, &(Map.has_key?(&1, "need") and is_nil(&1["need"])))
    assert [%{"via" => "old-maps"} = gone] = Enum.reject(removed, &Map.has_key?(&1, "source"))
    refute Map.has_key?(gone, "name")
    assert Enum.any?(removed, &(Map.has_key?(&1, "source") and not Map.has_key?(&1, "name")))
  end

  test "a preview that removes nothing names an empty list, and one that says nothing is refused" do
    preview = Map.put(vectors()["preview"], "removed", [])
    assert {:ok, decoded} = ConsentPreview.decode(preview)
    assert ConsentPreview.encode(decoded)["removed"] == []

    assert ConsentPreview.decode(Map.delete(preview, "removed")) ==
             {:error, {:missing_field, "removed"}}

    for refused <- [nil, %{}, [nil], ["x"]] do
      assert ConsentPreview.check_removed(refused) == {:error, {:invalid_field, "removed"}},
             inspect(refused)
    end
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

  test "a tool server row carries what its grant records of it, never a literal's value" do
    {:ok, %ConsentPreview{rows: rows} = preview} = ConsentPreview.decode(vectors()["preview"])

    assert [
             %Row{
               values: %{
                 "record" =>
                   %{
                     "address" => "https://forecasts.example/mcp",
                     "headers" => [
                       %{"name" => "authorization", "entry" => "forecasts-token"},
                       %{"name" => "x-region", "literal" => true} = literal
                     ]
                   } = http
               }
             },
             %Row{
               values: %{
                 "record" => %{
                   "address" => "npx -y @modelcontextprotocol/server-github",
                   "env" => [
                     %{"name" => "GITHUB_TOKEN", "entry" => "github-token"},
                     %{"name" => "NODE_ENV", "literal" => true}
                   ],
                   "folder" => "kept",
                   "hosts" => ["api.github.com", "github.com"],
                   "memory_bytes" => 268_435_456,
                   "home_max_bytes" => 1_073_741_824
                 }
               }
             }
           ] = Enum.filter(rows, &(&1.kind == :tool_servers))

    assert map_size(literal) == 2
    assert map_size(http) == 2
    assert ConsentPreview.decode(ConsentPreview.encode(preview)) == {:ok, preview}

    refusals = Map.new(vectors()["refusals"], &{&1["name"], &1["preview"]})

    assert ConsentPreview.decode(refusals["a tool server record carrying a literal's value"]) ==
             {:error, {:invalid_field, "record"}}

    assert ConsentPreview.decode(refusals["a tool server naming no record"]) ==
             {:error, {:missing_field, "record"}}
  end

  test "a program's record holds its settings, each absent when unset and never null" do
    refusals = Map.new(vectors()["refusals"], &{&1["name"], &1["preview"]})

    for name <- [
          "a program record naming its hosts as null",
          "a program record naming its hosts out of order",
          "a program record naming a host twice",
          "a program record naming an empty host",
          "a program record naming no folder",
          "a program record naming another kind of folder",
          "a program record naming its memory bound as null",
          "a program record naming a bound of no bytes",
          "a program record naming a bound that is no whole number",
          "a program record naming a setting no record holds",
          "an http record naming a program's folder"
        ] do
      assert ConsentPreview.decode(refusals[name]) == {:error, {:invalid_field, "record"}}, name
    end

    # Unset hosts and bounds are absent, and no host at all is a list of
    # its own: each reads back as it was written.
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])
    program = Enum.find(rows, &(&1.kind == :tool_servers and &1.values["name"] == "github"))
    record = program.values["record"]

    for settings <- [
          Map.take(record, ["address", "env", "folder"]),
          record
          |> Map.take(["address", "env"])
          |> Map.merge(%{"folder" => "scratch", "hosts" => []})
        ] do
      row = put_in(program.values["record"], settings)
      assert Row.decode(Row.encode(row)) == {:ok, row}
    end
  end

  test "every refusal is refused with its reason" do
    for %{"name" => name, "preview" => preview, "error" => error} <- vectors()["refusals"] do
      assert tag(ConsentPreview.decode(preview)) == error, name
    end

    assert ConsentPreview.decode("rows") == {:error, {:invalid_field, "preview"}}
  end

  test "a credential row's fields map each field the component reads to the entry field that answers it" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])
    credentials = for %Row{kind: :credential, values: values} <- rows, do: values

    for values <- credentials, do: assert(is_map(values["fields"]), inspect(values["fields"]))

    assert [%{"fields" => %{"api_key" => "API key"}}] =
             Enum.filter(credentials, &(&1["connection"] == "Geo account"))
  end

  test "a key another person shares is a credential of its own source, attached and never disclosed" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])

    assert [%{"name" => "Shared by Terry", "disclosed" => false}] =
             for(
               %Row{kind: :credential, values: %{"source" => "share"} = values} <- rows,
               do: values
             )

    assert "share" in Row.sources()
  end

  test "a credential whose fields are a list, or whose map names an empty field, is refused on its fields" do
    refusals = Map.new(vectors()["refusals"], &{&1["name"], &1["preview"]})

    for name <- [
          "a credential whose fields are a list",
          "a credential whose field map names an empty field"
        ] do
      assert %{^name => preview} = refusals
      assert ConsentPreview.decode(preview) == {:error, {:invalid_field, "fields"}}, name
    end
  end

  test "a credential row names its source, destination, lifetime and the rest" do
    {:ok, %ConsentPreview{rows: rows}} = ConsentPreview.decode(vectors()["preview"])
    credentials = for %Row{kind: :credential, values: values} <- rows, do: values

    assert Enum.map(credentials, & &1["source"]) |> Enum.sort() ==
             Enum.sort(ConsentPreview.Row.sources() ++ ["own", "own"])

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
