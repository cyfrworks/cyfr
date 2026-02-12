defmodule Sanctum.User do
  @moduledoc """
  Represents an authenticated user identity.

  Users are typically created from OIDC claims after authentication.
  Sanctum uses `local/0` which returns a user with full permissions.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t() | nil,
          provider: String.t(),
          permissions: [atom()]
        }

  defstruct [:id, :email, :provider, permissions: []]

  @doc """
  Create user from OIDC claims.

  ## Examples

      iex> claims = %{"sub" => "12345", "email" => "alice@example.com", "iss" => "https://github.com"}
      iex> user = Sanctum.User.from_oidc_claims(claims)
      iex> user.email
      "alice@example.com"

  """
  def from_oidc_claims(claims) do
    %__MODULE__{
      id: claims["sub"],
      email: claims["email"],
      provider: claims["iss"],
      permissions: []
    }
  end

  @doc """
  Local user for Sanctum.

  Returns a user with full permissions (`:*` wildcard).

  ## Examples

      iex> user = Sanctum.User.local()
      iex> user.id
      "local_user"
      iex> :* in user.permissions
      true

  """
  def local do
    %__MODULE__{
      id: "local_user",
      email: nil,
      provider: "local",
      permissions: [:*]
    }
  end
end
