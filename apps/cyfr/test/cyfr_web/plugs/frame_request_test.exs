# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.FrameRequestTest do
  use ExUnit.Case, async: true

  alias CyfrWeb.Plugs.FrameRequest

  defmodule Renderer do
    @moduledoc false
    @behaviour CyfrWeb.ErrorRenderer

    @impl true
    def send(conn, status, reason, _message),
      do: Plug.Conn.send_resp(conn, status, "rendered #{reason}")

    @impl true
    def halt(conn, status, reason, message),
      do: conn |> send(status, reason, message) |> Plug.Conn.halt()
  end

  defp call(values, opts \\ []) do
    conn =
      Enum.reduce(values, Plug.Test.conn(:get, "/a/home/settings"), fn value, conn ->
        %{conn | req_headers: conn.req_headers ++ [{"sec-fetch-dest", value}]}
      end)

    FrameRequest.call(conn, FrameRequest.init(opts))
  end

  defp assert_refused(conn) do
    assert conn.halted
    assert conn.status == 403
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    assert Plug.Conn.get_resp_header(conn, "location") == []
    conn
  end

  defp assert_passed(conn) do
    refute conn.halted
    assert conn.status == nil
    assert conn.state == :unset
  end

  test "every frame destination is refused with 403 and halted" do
    assert FrameRequest.frame_destinations() == ~w(iframe frame embed object fencedframe)

    for value <- FrameRequest.frame_destinations() do
      conn = assert_refused(call([value]))

      assert %{"code" => "forbidden", "message" => "A request made by a frame is refused"} =
               Jason.decode!(conn.resp_body)
    end
  end

  test "the value is read in any case and with surrounding whitespace" do
    for value <- ["IFrame", " iframe ", "\tFRAME", "Embed  ", " FencedFrame"] do
      assert_refused(call([value]))
    end
  end

  test "a list or a repeated header is refused when any value names a frame" do
    assert_refused(call(["document, iframe"]))
    assert_refused(call(["empty,frame"]))
    assert_refused(call(["document", "object"]))
    assert_passed(call(["document", "empty"]))
  end

  test "an absent header passes" do
    assert_passed(call([]))
  end

  test "every other destination passes" do
    for value <- ~w(document empty image script websocket style font worker iframes) do
      assert_passed(call([value]))
    end
  end

  test "the refusal is rendered by the :errors renderer" do
    conn = assert_refused(call(["iframe"], errors: Renderer))
    assert conn.resp_body == "rendered frame_request"
  end

  test "the refusal reads no session" do
    # No session was fetched: a read would raise, and none is made.
    conn = assert_refused(call(["iframe"]))
    refute Map.has_key?(conn.private, :plug_session)
  end
end
