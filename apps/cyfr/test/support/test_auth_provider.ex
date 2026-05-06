defmodule Emissary.TestAuthProvider do
  @moduledoc false
  @behaviour Sanctum.Auth

  @impl true
  def authenticate(_params), do: {:error, :not_implemented}

  @impl true
  def current_user(_conn) do
    Sanctum.Context.build(
      user_id: "test_user",
      email: "test@example.com",
      provider: "test",
      permissions: [:*],
      namespace: "testns",
      authenticated: true
    )
  end
end
