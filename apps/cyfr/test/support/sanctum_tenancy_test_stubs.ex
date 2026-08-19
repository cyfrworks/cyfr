# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.FailingResolver do
  @moduledoc """
  Test double that always returns `{:error, :resolve_failed}` from `resolve/1`.
  Wired via `config :cyfr, :tenancy_resolver_override`. Used by tests that
  exercise the resolver-failure logging path (`Sanctum.Tenancy.resolve_into/1`
  graceful degradation: log, then return the unmodified context).
  """
  def resolve(_user_id), do: {:error, :resolve_failed}
end

defmodule Sanctum.Test.OtherAthanorResolver do
  @moduledoc """
  Test double that always resolves to a *different* athanor than any
  key/context carries. Wired via `config :cyfr, :tenancy_resolver_override`.
  Used to prove the API-key path does NOT consult the configured resolver: if
  it did, the resulting context would carry "ath_other" instead of the key's
  own athanor.
  """
  def resolve(_user_id), do: %{athanor_id: "ath_other"}
end

defmodule Sanctum.Test.AltAuthProvider do
  @moduledoc """
  Alternate auth provider test double used by tests that need a
  non-default `Sanctum.Auth` implementation (e.g. to verify behaviour
  when `:auth_provider` is set to a module other than the built-in
  `Sanctum.Auth.OAuth`). Delegates the Ueberauth→Context mapping to
  `Sanctum.Auth.OAuth` so controller/plug behaviour is exercised
  faithfully.
  """
  @behaviour Sanctum.Auth

  alias Sanctum.Context

  # Build an identity Context straight from the Ueberauth struct (no
  # built-in provider-env gate, does not pre-set `authenticated:` — the
  # controller creates the session). Other shapes fall back to the
  # built-in provider.
  @impl true
  def authenticate(%{__struct__: Ueberauth.Auth} = auth) do
    provider = auth.provider
    email = auth.info && Map.get(auth.info, :email)
    iss = Sanctum.Auth.Identity.issuer(provider)
    user_id = Sanctum.Auth.Identity.user_id(provider, iss, to_string(auth.uid))

    ctx =
      Context.build(
        user_id: user_id,
        email: email,
        provider: to_string(provider),
        namespace: Sanctum.Namespace.lookup(user_id),
        permissions: [:read, :write]
      )

    {:ok, ctx}
  end

  def authenticate(params), do: Sanctum.Auth.OAuth.authenticate(params)

  @impl true
  defdelegate current_user(conn), to: Sanctum.Auth.OAuth
end
