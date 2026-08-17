# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AttachmentsTest do
  use ExUnit.Case, async: false

  alias Prism.Attachments

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "attachments_#{:rand.uniform(1_000_000)}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    prev_caps = Application.get_env(:cyfr, :caps)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if prev,
        do: Application.put_env(:cyfr, :base_path, prev),
        else: Application.delete_env(:cyfr, :base_path)

      if prev_caps,
        do: Application.put_env(:cyfr, :caps, prev_caps),
        else: Application.delete_env(:cyfr, :caps)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "filenames become one safe segment; same names in one message stay distinct blobs",
       %{ctx: ctx} do
    assert Attachments.safe_filename("../../etc/passwd") == ".._.._etc_passwd"
    assert Attachments.safe_filename("a/b\\c.txt") == "a_b_c.txt"
    assert Attachments.safe_filename("") == "file"
    assert Attachments.safe_filename("..") == "file"
    assert Attachments.safe_filename("x" <> <<7>> <> "y") == "xy"
    assert byte_size(Attachments.safe_filename(String.duplicate("n", 300))) <= 120

    files = [
      %{"filename" => "report.pdf", "media_type" => "application/pdf", "bytes" => "one"},
      %{"filename" => "report.pdf", "media_type" => "application/pdf", "bytes" => "two"}
    ]

    assert {:ok, [a, b]} = Attachments.store(ctx, "conv_x", "msg_y", files)
    assert a["path"] != b["path"]
    assert a["path"] == ["conversations", "conv_x", "msg_y", "0-report.pdf"]
    assert {:ok, "one"} = Arca.get(ctx, a["path"])
    assert {:ok, "two"} = Arca.get(ctx, b["path"])
    assert [%{"data" => d1}, %{"data" => d2}] = Attachments.load(ctx, [a, b])
    assert Base.decode64!(d1) == "one" and Base.decode64!(d2) == "two"
  end

  test "bounds: too many files, a file too large, or a full athanor writes nothing", %{ctx: ctx} do
    many =
      for n <- 1..11, do: %{"filename" => "f#{n}", "media_type" => "text/plain", "bytes" => "x"}

    assert {:error, :too_many_attachments} = Attachments.store(ctx, "c", "m", many)

    big = [%{"filename" => "big", "media_type" => "x", "bytes" => :binary.copy("a", 20_000_001)}]
    assert {:error, :attachment_too_large} = Attachments.store(ctx, "c", "m", big)

    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 10)
    ok = [%{"filename" => "small", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:ok, _} = Attachments.store(ctx, "c", "m1", ok)
    over = [%{"filename" => "more", "media_type" => "text/plain", "bytes" => "1234567"}]
    assert {:error, :storage_full} = Attachments.store(ctx, "c", "m2", over)
    refute Arca.exists?(ctx, ["conversations", "c", "m2", "0-more"])
  end
end
