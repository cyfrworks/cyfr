# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.FrameRequest do
  @moduledoc """
  A pipeline that reads a session refuses a request a frame made.

  The shell opens a tincture in a sandboxed frame, and a sandboxed frame
  may navigate itself to any address of this site. Some browsers attach
  the person's session cookie to that navigation, so a route that reads a
  session, or authenticates its caller, would answer the tincture as the
  person. The browser names the request's destination in
  `sec-fetch-dest`: a request whose destination is a frame (`iframe`,
  `frame`, `embed`, `object` or `fencedframe`, in any case, with any
  surrounding whitespace, in any of the header's values) is answered 403
  and halted.

  An absent header, or any other destination, passes through unchanged:
  browsers send the header only to secure origins, and other clients omit
  it. The tincture routes read no session and do not mount this plug.

  Mounted before the session is fetched and before the caller is
  authenticated, so the refusal reads no session, sets no cookie and
  redirects nowhere, whatever cookie the request carries.

  ## Options

  - `:errors` — the module that renders a rejection, defaulting to
    `CyfrWeb.ApiError`. A JSON-RPC route passes its own renderer.
  """

  @behaviour Plug

  import Plug.Conn

  @default_errors CyfrWeb.ApiError

  # The `sec-fetch-dest` values that name a frame as the request's destination.
  @frame_destinations ~w(iframe frame embed object fencedframe)

  @impl true
  def init(opts), do: Keyword.put_new(opts, :errors, @default_errors)

  @impl true
  def call(conn, opts) do
    if frame_request?(conn) do
      errors = Keyword.get(opts, :errors, @default_errors)
      errors.halt(conn, 403, :frame_request, nil)
    else
      conn
    end
  end

  @doc "Whether any `sec-fetch-dest` value of `conn` names a frame as its destination."
  @spec frame_request?(Plug.Conn.t()) :: boolean()
  def frame_request?(%Plug.Conn{} = conn) do
    conn
    |> get_req_header("sec-fetch-dest")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&((&1 |> String.trim() |> String.downcase()) in @frame_destinations))
  end

  @doc "The `sec-fetch-dest` values that are refused."
  @spec frame_destinations() :: [String.t()]
  def frame_destinations, do: @frame_destinations
end
