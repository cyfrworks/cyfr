# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.BearerToken do
  @moduledoc """
  The one read of `Authorization: Bearer` from a request.

  Reads the first Authorization header and returns a nonempty bearer token or nil.
  """

  @doc "The bearer token from the first authorization header, or `nil`."
  @spec read(term()) :: String.t() | nil
  def read(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> token
      _ -> nil
    end
  end

  def read(_), do: nil
end
