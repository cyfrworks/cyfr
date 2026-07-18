# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AuthExchange do
  @moduledoc """
  Short-lived signed exchange codes for session establishment.

  Wraps a session token in a Phoenix.Token with 30-second TTL,
  preventing raw tokens from appearing in URLs, browser history,
  server logs, or HTTP Referer headers.
  """

  @max_age_seconds 30
  @salt "prism_auth_exchange"

  @doc """
  Create a short-lived exchange code wrapping the given session token.
  """
  def create(token) when is_binary(token) do
    Phoenix.Token.sign(PrismWeb.Endpoint, @salt, token)
  end

  @doc """
  Redeem an exchange code, returning the original session token.

  Returns `{:ok, token}` if the code is valid and not expired,
  or `:error` otherwise.
  """
  def redeem(code) when is_binary(code) do
    case Phoenix.Token.verify(PrismWeb.Endpoint, @salt, code, max_age: @max_age_seconds) do
      {:ok, token} -> {:ok, token}
      {:error, _} -> :error
    end
  end
end
