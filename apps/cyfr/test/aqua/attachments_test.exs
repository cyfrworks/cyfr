# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AttachmentsTest.FailingAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  def put(_ctx, _path, "FAIL-THIS-WRITE"), do: {:error, :enospc}

  def put(actor, path, content),
    do: Arca.Adapters.Local.put(actor, path, content)
end

defmodule Aqua.AttachmentsTest.UnverifiableUsageAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  def usage(_ctx, _path), do: {:error, {:usage_walk, "unreachable", :eacces}}
end

defmodule Aqua.AttachmentsTest.PlantedCaps do
  @moduledoc false
  # A cap implementation that reports each storage question to the asking
  # process and refuses it, so a test sees that the port was asked.
  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, _count), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{} = actor, incoming) do
    send(self(), {:check_storage, actor, incoming})
    {:error, {:limit_reached, :athanor_storage_bytes, 0}}
  end
end

defmodule Aqua.AttachmentsTest do
  use ExUnit.Case, async: false

  alias Aqua.Attachments

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "attachments_#{:rand.uniform(1_000_000)}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if prev,
        do: Application.put_env(:arca, :base_path, prev),
        else: Application.delete_env(:arca, :base_path)
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

    assert {:ok, [a, b]} = Attachments.store(ctx, "thread_x", "msg_y", files)

    # No storage path in the persisted ref — the blob is named by its
    # stored name alone, and two same-named uploads stay distinct.
    refute Map.has_key?(a, "path")
    assert a["stored_name"] == "0-report.pdf"
    assert b["stored_name"] == "1-report.pdf"
    assert a["filename"] == "report.pdf" and b["filename"] == "report.pdf"

    assert {:ok, pa} = Attachments.blob_path("thread_x", "msg_y", a)
    assert {:ok, pb} = Attachments.blob_path("thread_x", "msg_y", b)
    assert pa == ["threads", "thread_x", "msg_y", "0-report.pdf"]
    assert {:ok, "one"} = Arca.get(Sanctum.Context.actor(ctx), pa)
    assert {:ok, "two"} = Arca.get(Sanctum.Context.actor(ctx), pb)

    assert [%{"data" => d1}, %{"data" => d2}] =
             Attachments.load(ctx, "thread_x", [
               %{message_id: "msg_y", ref: a},
               %{message_id: "msg_y", ref: b}
             ])

    assert Base.decode64!(d1) == "one" and Base.decode64!(d2) == "two"

    # A ref without a stored name references no blob at all.
    assert Attachments.blob_path("thread_x", "msg_y", %{"filename" => "report.pdf"}) == :error
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
    assert {:ok, [ref]} = Attachments.store(ctx, "thread_t", "msg_t", files)
    assert {:ok, path} = Attachments.blob_path("thread_t", "msg_t", ref)
    assert {:ok, "x"} = Arca.get(Sanctum.Context.actor(ctx), path)
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
    original = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Aqua.AttachmentsTest.FailingAdapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arca, :storage_adapter, original),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    files = [
      %{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "fine"},
      %{"filename" => "b.txt", "media_type" => "text/plain", "bytes" => "FAIL-THIS-WRITE"}
    ]

    assert {:error, :storage_error} = Attachments.store(ctx, "thread_r", "msg_r", files)

    # The first file was written, then rolled back — a message never
    # references a partial set, and no orphan blob remains.
    refute Arca.exists?(Sanctum.Context.actor(ctx), ["threads", "thread_r", "msg_r", "0-a.txt"])
  end

  test "bounds: too many files, a file too large, or a full athanor writes nothing", %{ctx: ctx} do
    many =
      for n <- 1..11, do: %{"filename" => "f#{n}", "media_type" => "text/plain", "bytes" => "x"}

    assert {:error, :too_many_attachments} = Attachments.store(ctx, "c", "m", many)

    big = [%{"filename" => "big", "media_type" => "x", "bytes" => :binary.copy("a", 20_000_001)}]
    assert {:error, :attachment_too_large} = Attachments.store(ctx, "c", "m", big)

    Cyfr.Test.Settings.put("athanor_storage_bytes", 10)
    # The usage cache is suite-shared per athanor and now survives writes
    # (bumped, not dropped) — start this cap check from a fresh walk.
    Arca.Usage.invalidate(Sanctum.Context.actor(ctx))
    ok = [%{"filename" => "small", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:ok, _} = Attachments.store(ctx, "c", "m1", ok)
    over = [%{"filename" => "more", "media_type" => "text/plain", "bytes" => "1234567"}]
    assert {:error, :storage_full} = Attachments.store(ctx, "c", "m2", over)
    refute Arca.exists?(Sanctum.Context.actor(ctx), ["threads", "c", "m2", "0-more"])
  end

  test "the storage cap is the port's decision", %{ctx: ctx} do
    installed = Prima.Caps.impl!()
    Prima.Caps.install!(Aqua.AttachmentsTest.PlantedCaps)
    on_exit(fn -> Prima.Caps.install!(installed) end)

    files = [%{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:error, :storage_full} = Attachments.store(ctx, "c", "m", files)

    actor = Sanctum.Context.actor(ctx)
    assert_received {:check_storage, ^actor, 5}
    refute Arca.exists?(actor, ["threads", "c", "m", "0-a.txt"])
  end

  test "an unverifiable usage walk surfaces as itself, not a generic error", %{ctx: ctx} do
    # With a cap configured and the walk unreadable, the cap layer fails
    # CLOSED with :storage_unverifiable — the member must see the honest,
    # transient message, not \"storing failed\".
    Cyfr.Test.Settings.put("athanor_storage_bytes", 1_000_000)
    Arca.Usage.invalidate(Sanctum.Context.actor(ctx))

    prev = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Aqua.AttachmentsTest.UnverifiableUsageAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arca, :storage_adapter, prev),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    files = [%{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "12345"}]
    assert {:error, :storage_unverifiable} = Attachments.store(ctx, "c", "m", files)
  end

  describe "copies" do
    setup %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      {:ok, thread} = Arca.Test.Days.thread(actor)
      {:ok, other} = Arca.Test.Days.thread(actor)
      {:ok, thread: thread, other: other}
    end

    defp posted!(ctx, thread, files) do
      id = Prima.UUID7.generate_id("msg")
      {:ok, refs} = Attachments.store(ctx, thread.id, id, files)

      {:ok, _} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread.id, %{
          message: %{
            id: id,
            author: ctx.user_id,
            sent_by: "person",
            content: "with files",
            payload: %{"attachments" => refs}
          }
        })

      {id, refs}
    end

    test "a file of a post is carried into another row's own blobs, and read back there",
         %{ctx: ctx, thread: thread, other: other} do
      {post, [ref]} =
        posted!(ctx, thread, [
          %{"filename" => "a.png", "media_type" => "image/png", "bytes" => "A"}
        ])

      assert {:ok, [file]} =
               Attachments.carried(ctx, thread.id, [
                 %{"message_id" => post, "stored_name" => ref["stored_name"]}
               ])

      target = Prima.UUID7.generate_id("msg")
      assert {:ok, [copied]} = Attachments.copy(ctx, other.id, target, [file])
      assert {:ok, path} = Attachments.blob_path(other.id, target, copied)
      assert {:ok, "A"} = Arca.get(Sanctum.Context.actor(ctx), path)

      # Discarded before its row is written, nothing of it stays.
      assert :ok = Attachments.discard(ctx, other.id, target)
      assert {:error, :not_found} = Arca.get(Sanctum.Context.actor(ctx), path)

      # A row that was written keeps its files.
      assert {:error, :message_sent} = Attachments.discard(ctx, thread.id, post)
    end

    test "only a file of a post of the named thread is carried",
         %{ctx: ctx, thread: thread, other: other} do
      {post, [ref]} =
        posted!(ctx, thread, [
          %{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "A"}
        ])

      named = %{"message_id" => post, "stored_name" => ref["stored_name"]}
      assert {:error, :not_a_post} = Attachments.carried(ctx, other.id, [named])

      assert {:error, :not_a_post} =
               Attachments.carried(ctx, thread.id, [%{named | "stored_name" => "9-nope"}])

      assert {:error, :not_a_post} = Attachments.carried(ctx, thread.id, [%{"path" => "notes/x"}])

      assert {:error, :too_many_attachments} =
               Attachments.carried(ctx, thread.id, List.duplicate(named, 11))

      {:ok, path} = Attachments.blob_path(thread.id, post, ref)
      :ok = Arca.delete(Sanctum.Context.actor(ctx), path)
      assert {:error, :attachment_missing} = Attachments.carried(ctx, thread.id, [named])
    end

    test "a file deleted from Files before a carry refuses it whole; one deleted after it was " <>
           "read lands in the copy; a copy made stays when its source goes",
         %{ctx: ctx, thread: thread, other: other} do
      actor = Sanctum.Context.actor(ctx)

      files = [
        %{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "A"},
        %{"filename" => "b.txt", "media_type" => "text/plain", "bytes" => "B"}
      ]

      {post, [a, b]} = posted!(ctx, thread, files)
      named = for ref <- [a, b], do: %{"message_id" => post, "stored_name" => ref["stored_name"]}

      # Before the carry reads it: the carry refuses, and nothing is copied.
      {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{post}/#{b["stored_name"]}")
      assert {:error, :attachment_missing} = Attachments.carried(ctx, thread.id, named)
      assert {:ok, []} = Arca.list(actor, ["threads", other.id])

      # After the carry read the bytes, before the copy: the copy holds them.
      {post, [a, _b]} = posted!(ctx, thread, files)
      named = for ref <- [a], do: %{"message_id" => post, "stored_name" => ref["stored_name"]}
      assert {:ok, [file]} = Attachments.carried(ctx, thread.id, named)
      {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{post}")

      target = Prima.UUID7.generate_id("msg")
      assert {:ok, [copied]} = Attachments.copy(ctx, other.id, target, [file])
      {:ok, path} = Attachments.blob_path(other.id, target, copied)
      assert {:ok, "A"} = Arca.get(actor, path)

      # After the copy: the source thread's whole folder goes, the copy stays.
      {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}")
      assert {:ok, "A"} = Arca.get(actor, path)
    end

    test "a message's folder deleted from Files before its files are stored, or after, " <>
           "leaves an upload whole or its post with refs whose bytes are gone",
         %{ctx: ctx, thread: thread} do
      actor = Sanctum.Context.actor(ctx)
      id = Prima.UUID7.generate_id("msg")
      file = [%{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "A"}]

      # Before: the folder is gone and the upload lays it again.
      assert {:error, {:not_found, _, _}} = Arca.Files.delete(actor, "threads/#{thread.id}/#{id}")
      assert {:ok, [ref]} = Attachments.store(ctx, thread.id, id, file)
      {:ok, path} = Attachments.blob_path(thread.id, id, ref)
      assert {:ok, "A"} = Arca.get(actor, path)

      # After the bytes landed, before the post: the post keeps its ref and
      # no bytes, which is what the pane draws as removed.
      {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{id}")

      {:ok, _} =
        Arca.TurnStorage.accept_message(actor, thread.id, %{
          message: %{
            id: id,
            author: ctx.user_id,
            sent_by: "person",
            content: "with a file",
            payload: %{"attachments" => [ref]}
          }
        })

      {:ok, row} = Arca.ThreadStorage.get_message(actor, id)
      assert [%{"stored_name" => stored}] = Attachments.refs_of(row)
      assert stored == ref["stored_name"]
      refute Arca.exists?(actor, path)
    end

    test "a copy is held to the storage cap before its first byte", %{ctx: ctx, other: other} do
      installed = Prima.Caps.impl!()
      Prima.Caps.install!(Aqua.AttachmentsTest.PlantedCaps)
      on_exit(fn -> Prima.Caps.install!(installed) end)

      target = Prima.UUID7.generate_id("msg")

      assert {:error, :storage_full} =
               Attachments.copy(ctx, other.id, target, [
                 %{"filename" => "a.txt", "media_type" => "text/plain", "bytes" => "AB"}
               ])

      assert_received {:check_storage, _actor, 2}
      assert {:ok, []} = Arca.list(Sanctum.Context.actor(ctx), ["threads", other.id])
    end
  end
end
