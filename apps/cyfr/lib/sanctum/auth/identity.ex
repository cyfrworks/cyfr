# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.Identity do
  @moduledoc """
  Who a person is to an identity provider.

  An identity's key is `"<provider>|<iss>|<subject>"` — deterministic for a
  given IdP identity, so the same human via the same IdP presents the same
  key on every deployment. It is what the door judges before any row
  exists and what an `Arca.Schemas.ExternalIdentity` row is keyed by; the
  person it names has an id of this server's (`Sanctum.Tenancy.Users`).
  The two built-in direct providers and their issuers are the `@builtin`
  table below; it is the only place either is written.

  That table answers three questions the sign-in path asks, and they must
  agree: what issuer to stamp on a direct-provider login (`issuer/1`), what
  host an issuer string really names (`issuer_host/1`), and whether a
  configured OIDC issuer is one a direct strategy already owns
  (`reserved_issuer?/1`).
  """

  @builtin %{
    "github" => "https://github.com",
    "google" => "https://accounts.google.com"
  }

  # Derived, not typed again: the hosts a generic-OIDC deployment may not use.
  @builtin_hosts @builtin |> Map.values() |> Enum.map(&URI.parse(&1).host) |> Enum.sort()

  @doc """
  Build the identity key `"<provider>|<iss>|<subject>"`.

  Used by every sign-in path (device flow, the OIDC callback) so the key
  shape stays consistent.
  """
  @spec key(String.t() | atom(), String.t(), String.t()) :: String.t()
  def key(provider, iss, sub) when is_atom(provider),
    do: key(Atom.to_string(provider), iss, sub)

  def key(provider, iss, sub)
      when is_binary(provider) and is_binary(iss) and is_binary(sub) and
             provider != "" and iss != "" and sub != "" do
    "#{provider}|#{iss}|#{sub}"
  end

  # Reject empty components. An empty iss/sub produced a degenerate key like
  # "github||" that can collide across people and normalize unexpectedly — an
  # identity must have all three parts.
  def key(provider, iss, sub) do
    raise ArgumentError,
          "invalid identity components: " <>
            "provider=#{inspect(provider)} iss=#{inspect(iss)} sub=#{inspect(sub)}"
  end

  @doc """
  The key of a direct-provider login, whose issuer is not carried in a token.

      iex> Sanctum.Auth.Identity.builtin_key(:github, "12345")
      "github|https://github.com|12345"
  """
  @spec builtin_key(atom() | String.t(), String.t()) :: String.t()
  def builtin_key(provider, sub), do: key(provider, issuer(provider), sub)

  @doc """
  The three parts of a key, or `{:error, :not_an_identity}` for a string
  that is not one. The one place a key is taken apart.

      iex> Sanctum.Auth.Identity.parse("github|https://github.com|12345")
      {:ok, %{provider: "github", issuer: "https://github.com", subject: "12345"}}
  """
  @spec parse(term()) ::
          {:ok, %{provider: String.t(), issuer: String.t(), subject: String.t()}}
          | {:error, :not_an_identity}
  def parse(key) when is_binary(key) do
    case String.split(key, "|", parts: 3) do
      [provider, iss, sub] when provider != "" and iss != "" and sub != "" ->
        {:ok, %{provider: provider, issuer: iss, subject: sub}}

      _ ->
        {:error, :not_an_identity}
    end
  end

  def parse(_), do: {:error, :not_an_identity}

  @doc "Whether `value` has the shape of an identity key."
  @spec key?(term()) :: boolean()
  def key?(value), do: match?({:ok, _}, parse(value))

  @doc """
  Canonical `iss` (RFC 7519 issuer) for a built-in provider.

  GitHub and Google have stable, well-known issuer URLs; device flow does
  not receive an `iss` from their userinfo endpoints, so it uses these to
  build ids in the same shape an OIDC-claim login produces.

  ## Examples

      iex> Sanctum.Auth.Identity.issuer(:github)
      "https://github.com"

      iex> Sanctum.Auth.Identity.issuer(:google)
      "https://accounts.google.com"

  """
  @spec issuer(atom() | String.t()) :: String.t()
  def issuer(provider) when is_atom(provider), do: issuer(Atom.to_string(provider))

  def issuer(provider) when is_binary(provider) do
    # Explicit failure (vs. a FunctionClauseError) if a third built-in
    # provider is ever added without a canonical issuer registered here.
    case Map.fetch(@builtin, provider) do
      {:ok, iss} -> iss
      :error -> raise ArgumentError, "no canonical issuer registered for provider #{provider}"
    end
  end

  def issuer(other) do
    raise ArgumentError, "no canonical issuer registered for provider #{inspect(other)}"
  end

  @doc """
  Lowercased host of an issuer string, tolerant of a missing scheme and a
  trailing slash or port. Returns `""` when no host can be determined.

      iex> Sanctum.Auth.Identity.issuer_host("https://GitHub.com/")
      "github.com"
  """
  @spec issuer_host(term()) :: String.t()
  def issuer_host(iss) when is_binary(iss) do
    trimmed = iss |> String.trim() |> String.trim_trailing("/")
    with_scheme = if String.contains?(trimmed, "://"), do: trimmed, else: "https://" <> trimmed

    case URI.parse(with_scheme) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> ""
    end
  end

  def issuer_host(_), do: ""

  @doc """
  Whether `iss` names a host a direct strategy already owns.

  Wiring `ueberauth_oidcc` at github.com or accounts.google.com would mint
  `"oidc|https://github.com|…"` where the direct strategy mints
  `"github|…"`, silently splitting one human into two ids across
  deployments. Compared on the normalized host, so a trailing slash, a port,
  a scheme variant or a look-alike (`https://evil-github.com/`) cannot slip
  past a substring check.

      iex> Sanctum.Auth.Identity.reserved_issuer?("https://github.com/")
      true

      iex> Sanctum.Auth.Identity.reserved_issuer?("https://evil-github.com/")
      false
  """
  @spec reserved_issuer?(term()) :: boolean()
  def reserved_issuer?(iss), do: issuer_host(iss) in @builtin_hosts

  @doc "The built-in providers, by name."
  @spec builtin_providers() :: [String.t()]
  def builtin_providers, do: @builtin |> Map.keys() |> Enum.sort()
end
