# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The local adapter, with every listing under threads/ answering a storage
# error while armed: a post's folder that cannot be read right now.
defmodule PrismWeb.ThreadPaneRemovedFileTest.UnreadableThreads do
  @moduledoc false
  use Arca.Storage.TestDouble

  @armed {__MODULE__, :armed}

  def armed, do: @armed

  def list_typed(actor, ["threads" | _] = path) do
    if :persistent_term.get(@armed, false),
      do: {:error, :eio},
      else: Arca.Adapters.Local.list_typed(actor, path)
  end

  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

defmodule PrismWeb.ThreadPaneRemovedFileTest do
  # A post whose file the person deleted from Files: the pane draws it as
  # removed, a picture and any other file alike, when the thread is next
  # read; a folder it cannot read right now draws nothing as removed; and
  # the attachment address answers not found as for any missing file.
  use PrismWeb.ConnCase, async: false

  alias Arca.ThreadStorage, as: Threads
  alias PrismWeb.ThreadPaneRemovedFileTest.UnreadableThreads
  alias Sanctum.Tenancy.Athanors

  # A whole 1x1 PNG.
  @png Base.decode16!(
         "89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C489" <>
           "0000000D49444154789C636068F8FF1F000482027FE7D85A6C0000000049454E44AE426082"
       )

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "pane_removed_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf(test_path) end)

    user = test_user()
    athanor = Sanctum.Test.People.athanor!(user.user_id)
    conn = log_in_user(conn, user, athanor_id: athanor.id)
    here = %{Sanctum.TestContext.local(:prism) | user_id: user.user_id, athanor_id: athanor.id}
    actor = Sanctum.Context.actor(here)

    {:ok, thread} = Arca.Test.Days.thread(actor)
    message_id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(here, thread.id, message_id, [
        %{"filename" => "shot.png", "media_type" => "image/png", "bytes" => @png},
        %{"filename" => "notes.txt", "media_type" => "text/plain", "bytes" => "notes"}
      ])

    {:ok, post} =
      Threads.append(actor, thread.id, %{
        id: message_id,
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "here it is",
        payload: %{"attachments" => refs}
      })

    [picture, other] = Enum.map(refs, & &1["stored_name"])

    {:ok,
     conn: conn,
     athanor: athanor,
     actor: actor,
     thread: thread,
     post: post,
     picture: picture,
     other: other}
  end

  defp open_pane(conn, athanor, thread) do
    {:ok, pane, _} =
      live_isolated(conn, PrismWeb.ThreadPaneLive,
        session: %{"athanor_id" => athanor.id, "thread_id" => thread.id}
      )

    pane
  end

  defp href(athanor, post, stored),
    do: PrismWeb.Focus.path(Athanors.route_slug(athanor), "/attachments/#{post.id}/#{stored}")

  test "a picture deleted from Files is drawn as removed at the next read, and its address " <>
         "answers not found",
       ctx do
    %{conn: conn, athanor: athanor, actor: actor, thread: thread, post: post} = ctx
    picture_href = href(athanor, post, ctx.picture)
    file_href = href(athanor, post, ctx.other)

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, ~s(img[src="#{picture_href}"]))
    assert has_element?(pane, ~s(a[href="#{file_href}"][download="notes.txt"]))
    refute has_element?(pane, "[data-removed]")

    {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{post.id}/#{ctx.picture}")

    # The post already on the screen says it at the next read of the thread.
    pane = open_pane(conn, athanor, thread)
    refute has_element?(pane, "img")
    refute has_element?(pane, ~s([role=dialog][aria-label="shot.png"]))
    assert has_element?(pane, "[data-removed]", "shot.png was removed")
    assert has_element?(pane, ~s(a[href="#{file_href}"][download="notes.txt"]))
    assert render(pane) =~ "here it is"

    assert get(conn, picture_href).status == 404
    assert get(conn, file_href).status == 200
  end

  test "a post's folder deleted from Files draws every file of it as removed", ctx do
    %{conn: conn, athanor: athanor, actor: actor, thread: thread, post: post} = ctx

    {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{post.id}")

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, "[data-removed]", "shot.png was removed")
    assert has_element?(pane, "[data-removed]", "notes.txt was removed")
    refute has_element?(pane, "img")
    refute has_element?(pane, "a[download]")
    assert get(conn, href(athanor, post, ctx.other)).status == 404
  end

  # Astra's probe (#4046): a post's first drawing, as it arrives.
  test "a post that arrives after its file was deleted from Files is drawn removed", ctx do
    %{conn: conn, athanor: athanor, actor: actor, thread: thread} = ctx
    pane = open_pane(conn, athanor, thread)
    here = %{Sanctum.TestContext.local(:prism) | athanor_id: athanor.id}
    id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(here, thread.id, id, [
        %{"filename" => "late.png", "media_type" => "image/png", "bytes" => @png}
      ])

    {:ok, post} =
      Threads.append(actor, thread.id, %{
        id: id,
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "new picture",
        payload: %{"attachments" => refs}
      })

    {:ok, _} = Arca.Files.delete(actor, "threads/#{thread.id}/#{id}")

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor.id,
      thread_id: thread.id,
      kind: :message,
      data: post
    })

    assert has_element?(pane, "[data-removed]", "late.png was removed")
    refute has_element?(pane, ~s(img[src="#{href(athanor, post, hd(refs)["stored_name"])}"]))
  end

  test "a post's folder that cannot be read right now draws nothing as removed", ctx do
    %{conn: conn, athanor: athanor, thread: thread, post: post} = ctx

    Prima.Test.Env.put_app_env(:arca, :storage_adapter, UnreadableThreads)
    Prima.Test.Env.put_persistent_term(UnreadableThreads.armed(), true)

    pane = open_pane(conn, athanor, thread)
    refute has_element?(pane, "[data-removed]")
    assert has_element?(pane, ~s(img[src="#{href(athanor, post, ctx.picture)}"]))
  end
end
