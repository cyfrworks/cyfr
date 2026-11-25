# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.EndpointDevicesTest do
  @moduledoc """
  The endpoint refuses the camera, the microphone and screen capture on
  its answers: a route of each API, tincture and file pipeline asked
  plainly, by a frame and for a type it has none of, the 406 of
  `:accepts` among them, and what it answers outside every pipeline.
  Prism's own pages override it (`CyfrWeb.Plugs.BrowserCSPTest`).
  """

  use PrismWeb.ConnCase, async: false

  @refused "camera=(), microphone=(), display-capture=()"

  # Each request, with its status asked plainly, by a frame and for a type
  # the route has none of.
  @requests [
    {:get, "/api/health", {200, 200, 406}},
    {:get, "/api/executions/exec_x/events", {401, 403, 406}},
    {:get, "/auth/oauth/callback", {400, 400, 406}},
    {:get, "/directory/v1/abc", {404, 404, 406}},
    {:post, "/hooks/none", {404, 404, 406}},
    {:delete, "/mcp", {405, 403, 406}},
    {:options, "/mcp", {404, 404, 404}},
    {:get, "/t/@test/local/none", {404, 404, 406}},
    {:get, "/t/@test/local/none/a.js", {404, 404, 404}},
    {:post, "/_f/v1/invoke", {400, 400, 406}},
    {:options, "/_f/v1/invoke", {204, 204, 406}},
    {:get, {:athanor, "/attachments/msg_1/a.png"}, {404, 403, 404}},
    {:get, {:athanor, "/files/download/data/a.png"}, {404, 403, 404}},
    {:get, {:athanor, "/scrolls/download/none"}, {404, 403, 404}},
    {:get, "/shared/sth_1/attachments/msg_1/a.png", {404, 403, 404}}
  ]

  test "each route's answers refuse them, asked plainly, by a frame and for a type it has none of" do
    conn = log_in_user(build_conn(), test_user())

    answers =
      for {verb, at, statuses} <- @requests,
          {{asked, headers}, status} <-
            Enum.zip(
              [
                {:plainly, []},
                {:by_a_frame, [{"sec-fetch-dest", "iframe"}]},
                {:for_another_type, [{"accept", "image/avif"}]}
              ],
              Tuple.to_list(statuses)
            ) do
        path = path(at)
        asking = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
        request = fn -> dispatch(asking, CyfrWeb.Endpoint, verb, path, nil) end

        {{verb, path, asked}, answer(status, request), {status, [@refused]}}
      end

    assert length(answers) == 45

    assert for({what, got, want} <- answers, got != want, do: {what, got}) == []
  end

  test "so do the answers given outside every pipeline" do
    json = put_req_header(build_conn(), "content-type", "application/json")
    multipart = put_req_header(build_conn(), "content-type", "multipart/form-data; boundary=b")

    answers = [
      {"a static file", answer(200, fn -> get(build_conn(), "/sw.js") end), 200},
      {"no route", answer(404, fn -> get(build_conn(), "/no/such/route") end), 404},
      {"metrics, off", answer(404, fn -> get(build_conn(), "/metrics") end), 404},
      {"multipart", answer(415, fn -> post(multipart, "/hooks/none", "--b--") end), 415},
      {"an unreadable body", answer(400, fn -> post(json, "/hooks/none", "{") end), 400},
      {"a socket refused before dispatch", answer(411, fn -> post(json, "/live/longpoll") end),
       411}
    ]

    assert for({what, got, status} <- answers, got != {status, [@refused]}, do: {what, got}) == []
  end

  defp path({:athanor, suffix}), do: athanor_path(suffix)
  defp path(path), do: path

  # A refusal Phoenix renders from a raise (a 406, an unreadable body) is
  # read as it was sent.
  defp answer(status, request) when status in [400, 406] do
    sent = request.()
    {sent.status, get_resp_header(sent, "permissions-policy")}
  rescue
    _raised in [Phoenix.NotAcceptableError, Plug.Parsers.ParseError] ->
      {sent_status, headers, _body} = assert_error_sent(status, request)
      {sent_status, for({"permissions-policy", value} <- headers, do: value)}
  end

  defp answer(_status, request) do
    sent = request.()
    {sent.status, get_resp_header(sent, "permissions-policy")}
  end
end
