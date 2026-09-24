# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ApiError do
  @moduledoc """
  Renders a rejection from a plain HTTP endpoint — one that is not speaking
  JSON-RPC.

  One of the two `EmissaryWeb.ErrorRenderer` implementations; the other is
  `EmissaryWeb.MCPError`, which answers in JSON-RPC.

  A rejection is a refusal (`Prima.Refusal`): the body is
  `{"code": <class>, "message": <sentence>}`, plus `data` for a consent
  signal, and a 401 carries the `www-authenticate` challenge. `status/1`
  is the class→HTTP table.
  """

  @behaviour EmissaryWeb.ErrorRenderer

  import Plug.Conn

  @statuses %{
    invalid_argument: 400,
    unauthenticated: 401,
    forbidden: 403,
    consent_required: 403,
    not_found: 404,
    conflict: 409,
    not_owner: 409,
    rate_limited: 429,
    setup_required: 503,
    unavailable: 503,
    timeout: 504,
    corrupt: 500,
    cancelled: 500,
    uncertain: 500,
    internal: 500
  }

  @doc "The HTTP status a refusal class answers with."
  @spec status(Prima.Refusal.class()) :: pos_integer()
  def status(class), do: Map.fetch!(@statuses, class)

  @doc """
  Render `reason` — a `%Prima.Refusal{}`, or a reason term classified here
  (`Grimoire.Error.classify/1`) — at the status its class answers with,
  with its own sentence.
  """
  @spec refuse(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refuse(%Plug.Conn{} = conn, reason) do
    refusal = Grimoire.Error.classify(reason)
    __MODULE__.send(conn, status(refusal.class), refusal, nil)
  end

  @doc """
  Render `reason` at `status`. The body's `code` is the reason's class;
  its `message` is `message` when the adapter words the refusal for its
  route, else the refusal's own sentence.
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, reason, message) do
    refusal = Grimoire.Error.classify(reason)

    conn
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(body(refusal, message))
  end

  @doc "Render a refusal and halt the pipeline. The plug form of `refuse/2`."
  @spec halt(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def halt(%Plug.Conn{} = conn, reason) do
    conn
    |> refuse(reason)
    |> Plug.Conn.halt()
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

  defp body(%Prima.Refusal{} = refusal, message) do
    %{
      "code" => Atom.to_string(refusal.class),
      "message" => if(is_binary(message), do: message, else: refusal.message)
    }
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
