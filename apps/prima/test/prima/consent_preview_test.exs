# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConsentPreviewTest do
  @moduledoc """
  The consent preview as data (`tests/fixtures/consent_preview.json`): the
  preview holding a row of every kind reads and writes back to itself; a
  row of an unknown kind, a sentence, a narrowed kind that cannot narrow,
  an origin outside the enum and every other malformed row are refused.
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
