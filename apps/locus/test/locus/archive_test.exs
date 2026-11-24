# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ArchiveTest do
  @moduledoc """
  A build's sources travel in a tar archive and its outputs return in one.
  What comes back is the build's to write, and is read as it arrives, in
  whatever pieces it comes: only its regular files are read, under safe
  relative names, each named with its size before any of its bytes, no
  more of them than the bound, and an archive cut short is not whole.
  """

  use ExUnit.Case, async: true

  alias Locus.Archive

  # The archive read in pieces of `size` bytes: its regular files, the
  # names of the entries skipped, and whether it ended whole.
  defp read_all(archive, max_files, size) do
    archive
    |> pieces(size)
    |> Enum.reduce_while({:ok, Archive.reader(max_files), []}, fn piece, {:ok, reader, events} ->
      case Archive.read(reader, piece) do
        {:ok, more, reader} -> {:cont, {:ok, reader, events ++ more}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reader, events} -> {:ok, files(events), skipped(events), Archive.ended?(reader)}
      {:error, _} = error -> error
    end
  end

  defp pieces(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp pieces(bytes, size) do
    <<piece::binary-size(^size), rest::binary>> = bytes
    [piece | pieces(rest, size)]
  end

  # Each file's bytes, after a header naming its size; a file not ended is
  # none.
  defp files(events) do
    {files, _unended} =
      Enum.reduce(events, {%{}, nil}, fn
        {:file, name, size}, {files, nil} ->
          {files, {name, size, []}}

        {:data, bytes}, {files, {name, size, acc}} ->
          {files, {name, size, [acc, bytes]}}

        :file_end, {files, {name, size, acc}} ->
          bytes = IO.iodata_to_binary(acc)
          assert byte_size(bytes) == size, name
          {Map.put(files, name, bytes), nil}

        {:skipped, _name}, state ->
          state
      end)

    files
  end

  defp skipped(events), do: for({:skipped, name} <- events, do: name)

  test "packed sources read back to the same files, in pieces of any size" do
    files = %{
      "src/lib.rs" => "fn main() {}",
      "Cargo.toml" => "[package]\n",
      "deep/a/b/c.txt" => <<0, 1, 2>>,
      "empty" => "",
      "big.bin" => :crypto.strong_rand_bytes(70_000)
    }

    assert {:ok, archive} = Archive.pack(files)

    for size <- [1, 7, 511, 512, 513, 65_536, byte_size(archive)] do
      assert {:ok, ^files, [], true} = read_all(archive, 10, size), "pieces of #{size}"
    end
  end

  test "an empty output is an archive of no file, and bytes that are not a tar are refused" do
    assert {:ok, %{}, [], true} = read_all(<<>>, 10, 512)
    assert {:error, {:unreadable, _}} = read_all(:binary.copy("not a tar", 100), 10, 512)
  end

  test "an archive cut short is not whole" do
    {:ok, archive} = Archive.pack(%{"a.txt" => String.duplicate("a", 2_000)})
    cut = binary_part(archive, 0, 1_024)
    assert {:ok, _files, [], false} = read_all(cut, 10, 512)
  end

  test "more regular files than the bound are refused before the next one's bytes" do
    {:ok, archive} = Archive.pack(Map.new(1..5, &{"f#{&1}", "x"}))
    assert {:error, {:too_many_files, 4}} = read_all(archive, 4, 512)
  end

  test "a name that climbs out of the output is refused" do
    assert {:ok, archive} = Archive.pack(%{"dist/../../etc/passwd" => "root"})
    assert {:error, {:unsafe_path, _}} = read_all(archive, 10, 512)
  end

  test "a header whose checksum is not its own is refused" do
    {:ok, archive} = Archive.pack(%{"a.txt" => "a"})
    <<head::binary-size(10), byte, rest::binary>> = archive
    assert {:error, {:unreadable, :checksum}} = read_all(head <> <<byte + 1>> <> rest, 10, 512)
  end

  test "symbolic links are not read and are named among the skipped entries" do
    dir = Path.join(System.tmp_dir!(), "archive_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "index.html"), "<p>hi</p>")
    File.ln_s!("/etc/passwd", Path.join(dir, "link"))
    tar = Path.join(dir, "out.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [
        {~c"dist/index.html", String.to_charlist(Path.join(dir, "index.html"))},
        {~c"dist/link", String.to_charlist(Path.join(dir, "link"))}
      ])

    assert {:ok, %{"dist/index.html" => "<p>hi</p>"}, ["dist/link"], true} =
             read_all(File.read!(tar), 10, 512)
  end
end
