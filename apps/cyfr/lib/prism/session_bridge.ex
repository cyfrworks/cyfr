# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.SessionBridge do
  @moduledoc """
  Bridges Prism browser sessions to CLI.

  When authenticated in browser, generate a one-time code that the CLI
  can redeem for a session token. Uses `Prism.AuthExchange` (Phoenix.Token
  with 30s TTL) for the exchange code.

  ## Flow

  1. Browser user calls `bridge-code` session action via MCP
  2. Server generates exchange code from their session token
  3. User provides code to CLI
  4. CLI redeems code via `bridge-redeem` action to get session token

  ## Security

  - Exchange codes expire after 30 seconds (Prism.AuthExchange TTL)
  - Each code wraps the session token, not user credentials
  - One-time use: once redeemed, the session token is active on both browser and CLI
  """

  alias Prism.AuthExchange

  @doc """
  Generate a one-time exchange code from a session token.

  Returns `{:ok, code}` where `code` is a short-lived Phoenix.Token.
  """
  @spec generate_code(String.t()) :: {:ok, String.t()}
  def generate_code(session_token) when is_binary(session_token) do
    code = AuthExchange.create(session_token)
    {:ok, code}
  end

  @doc """
  Redeem an exchange code to get the original session token.

  Returns `{:ok, session_token}` or `:error` if the code is invalid or expired.
  """
  @spec redeem_code(String.t()) :: {:ok, String.t()} | :error
  def redeem_code(code) when is_binary(code) do
    AuthExchange.redeem(code)
  end
end