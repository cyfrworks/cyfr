# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.BearerToken do
  @moduledoc """
  The one read of `Authorization: Bearer` from a request.

  Reads the first Authorization header and returns a nonempty bearer token or nil.
  """

  @doc "The bearer token from the first authorization header, or `nil`."
  @spec read(Plug.Conn.t()) :: String.t() | nil
  def read(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> token
      _ -> nil
    end
  end

  @doc """
  The bearer provider the test harness installs (`Sanctum.Auth`'s
  `current_user/1`, `:sanctum, :bearer_provider`), or `nil`. A test seam
  only a test build reads (`Sanctum.seam/2`): every release answers `nil`,
  whatever the key says, so no bearer of a provider's is ever asked about.
  """
  @spec provider() :: module() | nil
  def provider, do: Sanctum.seam(nil, fn -> Application.get_env(:sanctum, :bearer_provider) end)
end
