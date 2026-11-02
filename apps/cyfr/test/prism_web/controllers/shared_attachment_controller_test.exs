# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SharedAttachmentControllerTest do
  @moduledoc """
  `/shared/:thread/attachments/:message_id/:filename` serves a file said in
  a shared thread to a person seated in it, and to nobody else: a visitor
  with no session is sent to sign in, and a signed-in person without a
  seat, a former member included, gets the 404 a missing file gets.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.SharedThreads

  setup do
    base = Path.join(System.tmp_dir!(), "shared_download_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      File.rm_rf(base)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    alice = test_user()
    bob = test_user()
    {:ok, thread} = SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = SharedThreads.add(alice.user_id, thread.id, user_id: bob.user_id)

    {:ok, message} =
      SharedThreads.post(alice.user_id, thread.id, "the plan", [
        %{filename: "plan.txt", media_type: "text/plain", bytes: "step one"},
        %{filename: "page.html", media_type: "text/html", bytes: "<script></script>"}
      ])

    [text, html] = message.attachments

    path = fn ref ->
      "/shared/#{thread.id}/attachments/#{message.id}/#{ref["stored_name"]}"
    end

    {:ok,
     alice: alice,
     bob: bob,
     thread: thread,
     message: message,
     text: path.(text),
     html: path.(html)}
  end

  test "another person in the thread gets the file, as a download that is never sniffed or kept",
       %{conn: conn, bob: bob, text: text, html: html} do
    # Bob's session names his own athanor; the thread is none of its.
    conn = log_in_user(conn, bob)

    served = get(conn, text)
    assert served.status == 200
    assert served.resp_body == "step one"
    assert get_resp_header(served, "content-type") |> hd() =~ "text/plain"
    assert get_resp_header(served, "content-disposition") == [~s(attachment; filename="plan.txt")]
    assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(served, "cache-control") == ["private, no-store"]

    # A type that runs script is served as opaque bytes.
    served = get(conn, html)
    assert served.status == 200
    assert get_resp_header(served, "content-type") |> hd() =~ "application/octet-stream"
  end

  test "a person without a seat gets the 404 a missing file gets, a former member included",
       %{conn: conn, alice: alice, bob: bob, thread: thread, message: message, text: text} do
    stranger = log_in_user(conn, test_user())
    assert get(stranger, text).status == 404

    missing = "/shared/#{thread.id}/attachments/#{message.id}/9-nothing.txt"
    member = log_in_user(build_conn(), alice)
    assert get(member, missing).status == 404
    assert get(member, "/shared/sth_nowhere/attachments/#{message.id}/0-plan.txt").status == 404

    :ok = SharedThreads.remove(alice.user_id, thread.id, user_id: bob.user_id)
    former = log_in_user(build_conn(), bob)
    assert get(former, text).status == 404
  end

  test "a visitor with no session is sent to sign in, whether the thread exists or not",
       %{text: text, message: message} do
    for path <- [text, "/shared/sth_nowhere/attachments/#{message.id}/0-plan.txt"] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == PrismWeb.AuthHelpers.sign_in_path(), path
    end
  end
end
