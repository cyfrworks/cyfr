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
          permissions: [atom()],
          org_id: String.t() | nil,
          project_id: String.t() | nil
        }

  defstruct [:id, :email, :provider, :org_id, :project_id, permissions: []]

  @doc """
  Create user from OIDC claims.

  The `id` is `"<provider>|<iss>|<subject>"` — pipe-delimited, scheme-prefixed
  issuer (RFC 7519 shape). This format is identical on Core and Arx so the
  same human via the same IdP resolves to the same id on both editions.
  The `provider` field stores the verbatim `iss` claim for audit context.

  ## Examples

      iex> claims = %{"sub" => "12345", "email" => "alice@example.com", "iss" => "https://github.com"}
      iex> user = Sanctum.User.from_oidc_claims(claims)
      iex> user.email
      "alice@example.com"
      iex> user.id
      "github|https://github.com|12345"

  """
  def from_oidc_claims(claims) do
    iss = claims["iss"]
    sub = claims["sub"]
    provider = claims["provider"] || derive_provider(iss)

    %__MODULE__{
      id: build_id(provider, iss, sub),
      email: claims["email"],
      provider: iss,
      permissions: []
    }
  end

  @doc """
  Build the canonical user id `"<provider>|<iss>|<subject>"`.

  Used by every `%User{}` construction site (OIDC claims, SimpleOAuth,
  DeviceFlow, Ueberauth callback) so the id shape stays consistent.
  """
  @spec build_id(String.t() | atom(), String.t(), String.t()) :: String.t()
  def build_id(provider, iss, sub) when is_atom(provider),
    do: build_id(Atom.to_string(provider), iss, sub)

  def build_id(provider, iss, sub)
      when is_binary(provider) and is_binary(iss) and is_binary(sub) do
    "#{provider}|#{iss}|#{sub}"
  end

  @doc """
  Hardcoded canonical `iss` (RFC 7519 issuer) for a provider atom.

  GitHub and Google have stable, well-known issuer URLs; SimpleOAuth and
  DeviceFlow don't receive an iss from their userinfo endpoints, so they
  use these constants to build user ids in the same format as OIDC-claim
  logins produce.

  ## Examples

      iex> Sanctum.User.provider_iss(:github)
      "https://github.com"

      iex> Sanctum.User.provider_iss(:google)
      "https://accounts.google.com"

  """
  @spec provider_iss(atom() | String.t()) :: String.t()
  def provider_iss(:github), do: "https://github.com"
  def provider_iss(:google), do: "https://accounts.google.com"
  def provider_iss("github"), do: "https://github.com"
  def provider_iss("google"), do: "https://accounts.google.com"

  # Fallback: when we only have an iss, reverse-map to the provider label
  # used in the id prefix. This is heuristic — explicit provider should be
  # preferred at call sites.
  defp derive_provider(iss) when is_binary(iss) do
    cond do
      String.contains?(iss, "github.com") -> "github"
      String.contains?(iss, "accounts.google.com") -> "google"
      true -> "oidc"
    end
  end

  defp derive_provider(_), do: "oidc"

  @doc """
  Normalize a free-text handle (email local-part, provider login) into a
  cyfr.run personal-slug candidate.

  Personal slugs must match `^[a-z0-9]+(-[a-z0-9]+)*$` (1–39 chars; GitHub-style).
  Email local-parts routinely contain `.`, `+`, uppercase, underscores — all of
  which the server rejects with 400 `INVALID_USERNAME`. This helper applies the
  same normalization the server expects so a pre-filled suggestion doesn't
  doom-submit.

  Returns `nil` when no non-empty valid slug can be derived (e.g. input is
  `nil`, empty, or all punctuation).

  ## Examples

      iex> Sanctum.User.suggest_slug("alice@example.com")
      "alice"

      iex> Sanctum.User.suggest_slug("alice.smith+tag@example.com")
      "alice-smith-tag"

      iex> Sanctum.User.suggest_slug("ALICE@example.com")
      "alice"

      iex> Sanctum.User.suggest_slug(nil)
      nil

      iex> Sanctum.User.suggest_slug("@@@")
      nil

  """
  @spec suggest_slug(String.t() | nil) :: String.t() | nil
  def suggest_slug(nil), do: nil

  def suggest_slug(raw) when is_binary(raw) do
    # If the input looks like an email, use the local-part — otherwise the
    # `@` + domain would all get turned into hyphens and produce garbage
    # like `"alice-example-com"` for `alice@example.com`.
    local =
      case String.split(raw, "@", parts: 2) do
        [local, _domain] -> local
        [local] -> local
      end

    slug =
      local
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 39)
      # Slice can land on a hyphen (e.g. a 40-char input ending in '-x' → first 39
      # chars end in '-'), which would fail the final regex. Re-trim to recover.
      |> String.trim_trailing("-")

    if Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, slug), do: slug, else: nil
  end

  def suggest_slug(_), do: nil

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
