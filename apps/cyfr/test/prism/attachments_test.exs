# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AttachmentsTest.FailingAdapter do
  @moduledoc false
  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate usage(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(ctx, path, conn, opts), to: Arca.Adapters.Local

  def put(_ctx, _path, "FAIL-THIS-WRITE"), do: {:error, :enospc}
  defdelegate put(ctx, path, content), to: Arca.Adapters.Local
end

defmodule Prism.AttachmentsTest.UnverifiableUsageAdapter do
  @moduledoc false
  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate put(ctx, path, content), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(ctx, path, conn, opts), to: Arca.Adapters.Local

  def usage(_ctx, _path), do: {:error, {:usage_walk, "unreachable", :eacces}}
end

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

    # No storage path in the persisted ref — the blob is named by its
    # stored name alone, and two same-named uploads stay distinct.
    refute Map.has_key?(a, "path")
    assert a["stored_name"] == "0-report.pdf"
    assert b["stored_name"] == "1-report.pdf"
    assert a["filename"] == "report.pdf" and b["filename"] == "report.pdf"

    assert {:ok, pa} = Attachments.blob_path("conv_x", "msg_y", a)
    assert {:ok, pb} = Attachments.blob_path("conv_x", "msg_y", b)
    assert pa == ["conversations", "conv_x", "msg_y", "0-report.pdf"]
    assert {:ok, "one"} = Arca.get(ctx, pa)
    assert {:ok, "two"} = Arca.get(ctx, pb)

    assert [%{"data" => d1}, %{"data" => d2}] =
             Attachments.load(ctx, "conv_x", [
               %{message_id: "msg_y", ref: a},
               %{message_id: "msg_y", ref: b}
             ])

    assert Base.decode64!(d1) == "one" and Base.decode64!(d2) == "two"

    # A ref without a stored name references no blob at all.
    assert Attachments.blob_path("conv_x", "msg_y", %{"filename" => "report.pdf"}) == :error
  end

  test "a filename spelled like Arca's reserved tmp shape still stores", %{ctx: ctx} do
    # `<name>.tmp.<n>` is the Local adapter's in-flight write marker —
    # Arca.put refuses it as :reserved_name. An upload so named must be
    # neutralized, not fail the whole batch.
    assert Attachments.safe_filename("report.tmp.1") == "report.tmp.1_"

    # Truncation must not re-mint the shape: this name only matches the
    # reserved pattern AFTER the byte cap cuts its trailing digits.
    long = String.duplicate("n", 112) <> ".tmp.345xyz"
    refute Arca.Storage.tmp_name?(long)
    refute Arca.Storage.tmp_name?(Attachments.safe_filename(long))

    files = [%{"filename" => "report.tmp.1", "media_type" => "text/plain", "bytes" => "x"}]
    assert {:ok, [ref]} = Attachments.store(ctx, "conv_t", "msg_t", files)
    assert {:ok, path} = Attachments.blob_path("conv_t", "msg_t", ref)
    assert {:ok, "x"} = Arca.get(ctx, path)
  end

  test "a multibyte filename is capped in bytes and stays valid UTF-8" do
    # 200 CJK graphemes are 600 bytes — past POSIX NAME_MAX. A grapheme cut
    # at 120 would still be 360 bytes and fail the write with :enametoolong.
    name = Attachments.safe_filename(String.duplicate("四", 200) <> ".txt")
    assert byte_size(name) <= 120
    assert String.valid?(name)

    # NFC normalization: a decomposed "é" (e + combining acute) collapses to
    # the composed codepoint, so one logical name is one stored name.
    decomposed = "cafe" <> <<0x65, 0xCC, 0x81>> <> ".txt"
    assert Attachments.safe_filename(decomposed) == "cafeé.txt"
  end

  test "a failed write mid-batch removes the earlier blobs and returns an error", %{ctx: ctx} do
    # The adapter seam is the designed swap point: fail the write whose
    # content says so, after earlier files already landed.
    original = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, Prism.AttachmentsTest.FailingAdapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :storage_adapter, original),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    files = [
      %{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "fine"},
      %{"filename" => "b.txt", "media_type" => "text/plain", "bytes" => "FAIL-THIS-WRITE"}
    ]

    assert {:error, :storage_error} = Attachments.store(ctx, "conv_r", "msg_r", files)

    # The first file was written, then rolled back — a message never
    # references a partial set, and no orphan blob remains.
    refute Arca.exists?(ctx, ["conversations", "conv_r", "msg_r", "0-a.txt"])
  end

  test "bounds: too many files, a file too large, or a full athanor writes nothing", %{ctx: ctx} do
    many =
      for n <- 1..11, do: %{"filename" => "f#{n}", "media_type" => "text/plain", "bytes" => "x"}

    assert {:error, :too_many_attachments} = Attachments.store(ctx, "c", "m", many)

    big = [%{"filename" => "big", "media_type" => "x", "bytes" => :binary.copy("a", 20_000_001)}]
    assert {:error, :attachment_too_large} = Attachments.store(ctx, "c", "m", big)

    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 10)
    # The usage cache is suite-shared per athanor and now survives writes
    # (bumped, not dropped) — start this cap check from a fresh walk.
    Arca.Usage.invalidate(ctx.athanor_id)
    ok = [%{"filename" => "small", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:ok, _} = Attachments.store(ctx, "c", "m1", ok)
    over = [%{"filename" => "more", "media_type" => "text/plain", "bytes" => "1234567"}]
    assert {:error, :storage_full} = Attachments.store(ctx, "c", "m2", over)
    refute Arca.exists?(ctx, ["conversations", "c", "m2", "0-more"])
  end

  test "an unverifiable usage walk surfaces as itself, not a generic error", %{ctx: ctx} do
    # With a cap configured and the walk unreadable, the cap layer fails
    # CLOSED with :storage_unverifiable — the member must see the honest,
    # transient message, not \"storing failed\".
    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 1_000_000)
    Arca.Usage.invalidate(ctx.athanor_id)

    prev = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, Prism.AttachmentsTest.UnverifiableUsageAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :storage_adapter, prev),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    files = [%{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:error, :storage_unverifiable} = Attachments.store(ctx, "c", "m", files)
  end
end
