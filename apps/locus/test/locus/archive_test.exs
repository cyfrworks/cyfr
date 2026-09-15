# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ArchiveTest do
  @moduledoc """
  A build's sources travel in a tar archive and its outputs return in one.
  What comes back is the build's to write, so only its regular files are
  read, under safe relative names, and no more of them than the bound.
  """

  use ExUnit.Case, async: true

  alias Locus.Archive

  test "packed sources unpack to the same files" do
    files = %{
      "src/lib.rs" => "fn main() {}",
      "Cargo.toml" => "[package]\n",
      "deep/a/b/c.txt" => <<0, 1, 2>>
    }

    assert {:ok, archive} = Archive.pack(files)
    assert {:ok, ^files, []} = Archive.unpack(archive, 10)
  end

  test "an empty output is an empty archive, and bytes that are not a tar are refused" do
    assert {:ok, %{}, []} = Archive.unpack(<<>>, 10)
    assert {:error, {:unreadable, _}} = Archive.unpack(:binary.copy("not a tar", 100), 10)
  end

  test "more regular files than the bound are refused" do
    {:ok, archive} = Archive.pack(Map.new(1..5, &{"f#{&1}", "x"}))
    assert {:error, {:too_many_files, 4}} = Archive.unpack(archive, 4)
  end

  test "a name that climbs out of the output is refused" do
    assert {:ok, archive} = Archive.pack(%{"dist/../../etc/passwd" => "root"})
    assert {:error, {:unsafe_path, _}} = Archive.unpack(archive, 10)
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

    assert {:ok, %{"dist/index.html" => "<p>hi</p>"}, ["dist/link"]} =
             Archive.unpack(File.read!(tar), 10)
  end
end
