# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.TestAuthProvider do
  @moduledoc """
  The auth provider sync `CyfrWeb.ConnCase` tests run under.

  It authenticates only a request that carries the test bearer
  (`bearer/1`, put on a conn by `CyfrWeb.ConnCase.authenticate_as/2`); a
  request without it gets `nil`, so an untagged test reaches the plug as an
  anonymous caller rather than silently as a person. The credential rides
  the Authorization header because `Phoenix.ConnTest.recycle/1` keeps only
  that header between requests.
  """
  @behaviour Sanctum.Auth

  @prefix "cyfr-test-actor."

  @doc "The test bearer token for a person with `overrides` merged into the defaults."
  @spec bearer(keyword()) :: String.t()
  def bearer(overrides \\ []) when is_list(overrides),
    do: @prefix <> Base.url_encode64(:erlang.term_to_binary(overrides))

  @impl true
  def authenticate(_params), do: {:error, :not_implemented}

  @impl true
  def current_user(conn) do
    with @prefix <> encoded <- Sanctum.BearerToken.read(conn),
         {:ok, binary} <- Base.url_decode64(encoded),
         {:ok, overrides} <- decode(binary) do
      # The authenticated test user works in the same athanor as
      # `Sanctum.TestContext.local/0`, so fixtures written through one are
      # visible through the other. A person holds the explicit person
      # permissions, never the wildcard no sign-in path mints.
      [
        user_id: "test_user",
        email: "test@example.com",
        provider: "test",
        permissions: Sanctum.Context.person_permissions(),
        athanor_id: Sanctum.TestContext.athanor_id(),
        namespace: "testns",
        authenticated: true
      ]
      |> Keyword.merge(overrides)
      |> Sanctum.Context.build()
    else
      _ -> nil
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      overrides when is_list(overrides) -> {:ok, overrides}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
