# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.BulkArgumentLogTest do
  @moduledoc """
  An argument an operation declares as bulk content (`Prima.Arg`'s
  `bulk: true`) is what a log records as its size and digest, never its
  bytes, and the catalog's bulk positions are exactly the arguments that
  carry file content. The request log's own rows are
  `Sanctum.Gate.AttachmentBytesLogTest`'s.
  """

  use ExUnit.Case, async: true

  alias Prima.Arg

  defp measured(value) do
    bytes = if is_binary(value), do: value, else: :erlang.term_to_binary(value)

    %{
      "size" => byte_size(bytes),
      "digest" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end

  defp files do
    Arg.new(
      "files",
      {:array,
       Arg.new(
         nil,
         {:record,
          [
            Arg.new("filename", :string, required: true),
            Arg.new("data", :string, required: true, bulk: true)
          ]}
       )}
    )
  end

  describe "the log's projection of a call" do
    test "measures bulk content at any depth and keeps every other value" do
      input = %{
        "files" => [%{"filename" => "a.txt", "data" => "aaaa"}],
        "label" => "kept"
      }

      assert Arg.logged([files(), Arg.new("label", :string)], input) == %{
               "files" => [%{"filename" => "a.txt", "data" => measured("aaaa")}],
               "label" => "kept"
             }
    end

    test "measures whole a value whose shape does not match a declaration holding bulk content" do
      for malformed <- [%{"data" => "bbbb"}, "bbbb"] do
        assert Arg.logged([files()], %{"files" => malformed}) == %{"files" => measured(malformed)}
      end

      # An array of something other than the records it declares: each item
      # is measured whole.
      assert %{"files" => [%{"size" => _, "digest" => "sha256:" <> _}]} =
               logged = Arg.logged([files()], %{"files" => [["bbbb"]]})

      refute inspect(logged) =~ "bbbb"
    end

    test "keeps an absent or null value as it is" do
      assert Arg.logged([files()], %{}) == %{}
      assert Arg.logged([files()], %{"files" => nil}) == %{"files" => nil}
    end

    test "only a string argument carries bulk content" do
      assert_raise ArgumentError, fn -> Arg.new("n", :integer, bulk: true) end
    end
  end

  describe "the catalog's bulk positions" do
    test "are exactly the arguments that carry file content" do
      positions =
        for provider <- Sanctum.Catalog.available_providers(),
            tool <- provider.tools(),
            operation <- Map.get(tool, :operations, []),
            arg <- operation.args,
            path <- bulk_paths(arg, arg.name),
            do: "#{operation.tool}.#{operation.action} #{path}"

      assert Enum.sort(Enum.uniq(positions)) == [
               "aqua.create content",
               "aqua.skill_create content",
               "aqua.skill_update content",
               "aqua.update content",
               "build.validate wasm_base64",
               "canvas.write module",
               "file.write content",
               "notes.keep content",
               "notes.pin content",
               "source.edit edits[].content",
               "source.write content",
               "thread.attach files[].data"
             ]
    end
  end

  defp bulk_paths(%Arg{bulk: true}, path), do: [path]
  defp bulk_paths(%Arg{type: {:array, item}}, path), do: bulk_paths(item, path <> "[]")
  defp bulk_paths(%Arg{type: {:map, value}}, path), do: bulk_paths(value, path <> "{}")

  defp bulk_paths(%Arg{type: {:record, fields}}, path),
    do: Enum.flat_map(fields, &bulk_paths(&1, path <> "." <> &1.name))

  defp bulk_paths(%Arg{}, _path), do: []
end
