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
    # The restore is registered before the change, so a test killed at its
    # timeout leaves the setting as it found it.
    Prima.Test.Env.put_app_env(:arca, :base_path, base)
    on_exit(fn -> File.rm_rf(base) end)

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

  test "a session made at the private address is refused at the browser address", %{
    conn: conn,
    bob: bob,
    text: text
  } do
    Prima.Test.Env.put_app_env(:sanctum, :browser_address, "https://cyfr.example")
    conn = log_in_user(conn, bob)

    assert get(conn, text).status == 200

    at_browser = conn |> Sanctum.ClientIp.put_ingress(:proxy) |> get(text)
    assert redirected_to(at_browser) == PrismWeb.AuthHelpers.sign_in_path()
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

  test "a file and a refusal refuse the camera, the microphone and screen capture",
       %{conn: conn, bob: bob, text: text} do
    conn = log_in_user(conn, bob)

    for {path, status} <- [{text, 200}, {"/shared/sth_nowhere/attachments/msg_none/0-a.txt", 404}] do
      answer = get(conn, path)

      assert {path, answer.status, get_resp_header(answer, "permissions-policy")} ==
               {path, status, ["camera=(), microphone=(), display-capture=()"]}
    end
  end

  test "a visitor with no session is sent to sign in, whether the thread exists or not",
       %{text: text, message: message} do
    for path <- [text, "/shared/sth_nowhere/attachments/#{message.id}/0-plan.txt"] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == PrismWeb.AuthHelpers.sign_in_path(), path
    end
  end
end
