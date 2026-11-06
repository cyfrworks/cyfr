# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.HandleController do
  @moduledoc """
  The handle registry's HTTP endpoints, served beside this CYFR's
  directory (`Sanctum.Directory.Handles`, which decides every request;
  this adapter reads the request and writes the answer). No session is
  read: a handle's answer is public, and a claim is a signed request
  verified against its account's log.

  ## Routes

    * `GET /v1/handles/:handle` — the account holding one exact handle:
      `cyfr-handle/v1`'s answer bytes (`Prima.HandleAnswer.encode/1`).
    * `POST /v1/namespaces/personal/claim` — a signed `handle.claim`
      request, `cyfr-registry-request/v2`: `201` with `{"handle",
      "identifier"}` for a handle it made the account's, `200` for one
      that already was. The request is the body's JSON object, read in its
      JCS form, the form its signature covers; a body past 16 KiB is
      refused `413` before it is decoded (`CyfrWeb.Plugs.RawBodyReader`).

  ## Refusals

  A request's refusal is the registry's: its code and status from
  `Prima.RegistryRequest.refusals/0`, in the error envelope
  `{"errors": [{"code", "message"}]}`, and `retry-after` beside
  `RATE_LIMITED`. A node that serves no directory answers `404`
  `{"error": "not_served"}`, and a mirror answers a claim `405`
  `{"error": "read_only"}`, as the directory's routes do. Each refusal is
  the request's refused decision, recorded once under its status's class.
  """

  use Emissary.Web, :controller

  alias Prima.{HandleAnswer, RegistryRequest}
  alias Sanctum.Directory.Handles

  @doc "`GET /v1/handles/:handle`."
  def resolve(conn, %{"handle" => handle}) do
    case Handles.resolve(%{handle: handle, source: source(conn)}) do
      {:ok, answer} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, HandleAnswer.encode(answer))

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  @doc "`POST /v1/namespaces/personal/claim`."
  def claim(conn, _params) do
    case Handles.claim(%{request: request(conn), source: source(conn)}) do
      {:ok, %{handle: handle, identifier: identifier, created: created}} ->
        conn
        |> put_status(if(created, do: 201, else: 200))
        |> json(%{"handle" => handle, "identifier" => identifier})

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  # The body's JSON object in its JCS form; a body the parsers passed
  # over, or one that is no object, is no request.
  defp request(%Plug.Conn{body_params: %{} = params}) when not is_struct(params) do
    case Prima.Identity.Encoding.jcs(params) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> ""
    end
  end

  defp request(_conn), do: ""

  defp source(conn), do: Sanctum.ClientIp.resolve(conn)

  defp refuse(conn, :not_served), do: node_refusal(conn, 404, "not_served", [])
  defp refuse(conn, :read_only), do: node_refusal(conn, 405, "read_only", [{"allow", "GET"}])

  defp refuse(conn, {:rate_limited, seconds}),
    do: envelope(conn, :rate_limited, [{"retry-after", Integer.to_string(seconds)}])

  defp refuse(conn, reason) when is_atom(reason), do: envelope(conn, reason, [])

  defp envelope(conn, reason, headers) do
    {code, status} = Keyword.fetch!(RegistryRequest.refusals(), reason)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> CyfrWeb.Plugs.CallIdentity.refused(status, code)
    |> put_status(status)
    |> json(%{"errors" => [%{"code" => code, "message" => "refused"}]})
  end

  defp node_refusal(conn, status, code, headers) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> CyfrWeb.Plugs.CallIdentity.refused(status, code)
    |> put_status(status)
    |> json(%{"error" => code})
  end
end
