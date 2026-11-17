# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ApiError do
  @moduledoc """
  Renders a rejection from a plain HTTP endpoint — one that is not speaking
  JSON-RPC.

  One of the two `CyfrWeb.ErrorRenderer` implementations; the other is
  `Emissary.Web.MCPError`, which answers in JSON-RPC.

  A rejection is a refusal (`Prima.Refusal`): the body is
  `{"code": <class>, "message": <sentence>}`, the sentence always the
  refusal's own, plus `data` for a consent signal, and a 401 carries the
  `www-authenticate` challenge. The class→HTTP table is
  `Prima.Refusal.http_status/1`.

  A rejection rendered here is the request's refused decision, recorded
  once (`CyfrWeb.Plugs.CallIdentity.refused/2`) when the pipeline
  minted a call id and nothing recorded it before.
  """

  @behaviour CyfrWeb.ErrorRenderer

  import Plug.Conn

  @doc """
  Render `reason` at `status`. The body's `code` is the reason's class
  and its `message` the refusal's own sentence, for every caller: the
  message argument, which `Emissary.Web.MCPError` reads, is not read
  here, so no route words a refusal apart from the table.
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, reason, _message) do
    refusal = Sanctum.Refusals.classify(reason)

    conn
    |> CyfrWeb.Plugs.CallIdentity.refused(refusal)
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(body(refusal))
  end

  @doc """
  Render an error and halt the pipeline. The plug form of `send/4`.
  """
  @impl true
  def halt(%Plug.Conn{} = conn, status, reason, message) do
    conn
    |> __MODULE__.send(status, reason, message)
    |> Plug.Conn.halt()
  end

  defp body(%Prima.Refusal{} = refusal) do
    %{"code" => Atom.to_string(refusal.class), "message" => refusal.message}
    |> with_data(refusal.reason)
  end

  defp with_data(body, reason) do
    if Prima.ConsentSignal.signal?(reason),
      do: Map.put(body, "data", Prima.ConsentSignal.data(reason)),
      else: body
  end

  # RFC 9110 §15.5.2: a 401 MUST carry at least one challenge.
  defp challenge(conn, 401), do: put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _status), do: conn
end
