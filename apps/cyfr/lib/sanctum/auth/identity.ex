# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.Identity do
  @moduledoc """
  Who a person is to an identity provider, and what this server calls them.

  A person's id here is `"<provider>|<iss>|<subject>"` — deterministic for a
  given IdP identity, so the same human via the same IdP resolves to the same
  id on every deployment. The two built-in direct providers and their issuers
  are the `@builtin` table below; it is the only place either is written.

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
  Build the canonical user id `"<provider>|<iss>|<subject>"`.

  Used by every Context construction site (OAuth, DeviceFlow, the Ueberauth
  callback) so the id shape stays consistent.
  """
  @spec user_id(String.t() | atom(), String.t(), String.t()) :: String.t()
  def user_id(provider, iss, sub) when is_atom(provider),
    do: user_id(Atom.to_string(provider), iss, sub)

  def user_id(provider, iss, sub)
      when is_binary(provider) and is_binary(iss) and is_binary(sub) and
             provider != "" and iss != "" and sub != "" do
    "#{provider}|#{iss}|#{sub}"
  end

  # Reject empty components. An empty iss/sub produced a degenerate id like
  # "github||" that can collide across users and normalize unexpectedly — an
  # identity must have all three parts.
  def user_id(provider, iss, sub) do
    raise ArgumentError,
          "invalid identity components: " <>
            "provider=#{inspect(provider)} iss=#{inspect(iss)} sub=#{inspect(sub)}"
  end

  @doc """
  The id of a direct-provider login, whose issuer is not carried in a token.

      iex> Sanctum.Auth.Identity.builtin_user_id(:github, "12345")
      "github|https://github.com|12345"
  """
  @spec builtin_user_id(atom() | String.t(), String.t()) :: String.t()
  def builtin_user_id(provider, sub), do: user_id(provider, issuer(provider), sub)

  @doc """
  Canonical `iss` (RFC 7519 issuer) for a built-in provider.

  GitHub and Google have stable, well-known issuer URLs; OAuth and DeviceFlow
  do not receive an `iss` from their userinfo endpoints, so they use these to
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
