# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SignInSync do
  @moduledoc """
  What cyfr.run says about a person who just signed in: the namespace it
  knows them by, and the push tokens their namespaces publish with.

  This is a courtesy and never the door. Every outcome proceeds; the
  registry cannot refuse a sign-in, delay one past its budget, or decide
  who a person is. `Sanctum.Door` decides admission and `Sanctum.SignIn`
  decides identity, both before anything here runs.

  It lives in Compendium rather than beside `Sanctum.SignIn` because
  everything it does is the component domain's: probing the registry,
  minting push tokens, reading the canonical host. Sanctum sits below
  Compendium and may not name any of them, so the probe runs here and
  reaches *down* into `Sanctum.SignIn.record_namespace/2` for the one
  piece that is identity — the durable copy of the person's namespace.

  ## Who calls it, and who does not

  The web callback holds the IdP access token the probe needs and is a
  surface above this domain, so it probes and passes the result on.

  **The CLI device flow does not.** `Sanctum.Auth.DeviceFlow` completes
  inside Sanctum, which cannot reach a registry, and handing the token up
  to reach one would put a credential on a path whose own invariant is
  that the IdP token never travels. So a CLI sign-in reports
  `probe: :skipped` and records no namespace and no push token. A person
  who wants them runs the `registry` tool, whose re-probe is
  `absorb_probe/2` — an explicit ask, with the same effect.
  """

  require Logger

  alias Compendium.Registry.CredentialStore
  alias Sanctum.SignIn

  # Nobody is held at the door by a black-holed registry: the probe gets
  # this long, then the person proceeds and the push tokens are refreshed
  # by the next probe. (Configurable for tests.)
  @returning_probe_ms 5_000

  @doc """
  Probe cyfr.run with the IdP `access_token` and absorb what it says.

  Always `{:proceed, user, report}`; see `t:Sanctum.SignIn.report/0` for
  what each `probe` value means.
  """
  @spec complete(Arca.Schemas.User.t(), String.t() | atom(), String.t() | nil) ::
          SignIn.outcome()
  def complete(user, _provider, access_token)
      when not is_binary(access_token) or access_token == "" do
    Logger.info("[Compendium.SignInSync] no IdP access token for #{user.id} — no probe")
    {:proceed, user, %{unsynced: [], probe: :skipped}}
  end

  def complete(user, provider, access_token) do
    if Compendium.RegistryHost.configured?() do
      case probe(provider, access_token) do
        {:ok, body} ->
          absorb(user, body)

        {:error, :invalid_access_token} ->
          {:proceed, user, %{unsynced: [], probe: :invalid_token}}

        {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required}} ->
          {:proceed, user, %{unsynced: [], probe: :legal_required}}

        {:error, reason} ->
          Logger.warning(
            "[Compendium.SignInSync] cyfr.run probe failed for #{user.id} " <>
              "(#{inspect(reason)}) — signing in without it"
          )

          {:proceed, user, %{unsynced: [], probe: :failed}}
      end
    else
      {:proceed, user, %{unsynced: [], probe: :skipped}}
    end
  end

  @doc """
  Absorb a probe body for a person who is already signed in — the
  `registry` tool's re-probe, or a retry after legal acceptance: record
  the namespace, cache the push tokens. Returns the slugs whose tokens
  could not be cached.
  """
  @spec absorb_probe(String.t(), map()) :: [String.t()]
  def absorb_probe(user_id, %{} = body) when is_binary(user_id) do
    personal = body["personal_namespace"]

    case slug_of(personal) do
      slug when is_binary(slug) ->
        case SignIn.record_namespace(user_id, slug) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Compendium.SignInSync] namespace not recorded: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    store_tokens(user_id, personal, body["memberships"] || [])
  end

  defp probe(provider, access_token) do
    logger_metadata = Cyfr.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(Compendium.ProvisioningSupervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)
        Compendium.Registry.Client.probe_identity(provider, access_token)
      end)

    budget = Application.get_env(:cyfr, :returning_probe_ms, @returning_probe_ms)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:probe_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp absorb(user, body) do
    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    case slug_of(personal) do
      slug when is_binary(slug) ->
        case SignIn.record_namespace(user.id, slug) do
          {:ok, user} ->
            {:proceed, user, report(store_tokens(user.id, personal, memberships))}

          {:error, :namespace_owned_by_another_identity} ->
            Logger.error(
              "[Compendium.SignInSync] cyfr.run names #{user.id} #{inspect(slug_of(personal))}, " <>
                "which another identity on this server holds — not recorded; " <>
                "reconcile it at cyfr.run"
            )

            {:proceed, user, %{unsynced: [], probe: :namespace_conflict}}

          {:error, reason} ->
            Logger.warning("[Compendium.SignInSync] namespace not recorded: #{inspect(reason)}")
            {:proceed, user, %{unsynced: [], probe: :failed}}
        end

      _ ->
        {:proceed, user, report(store_tokens(user.id, personal, memberships))}
    end
  end

  defp report(unsynced), do: %{unsynced: unsynced, probe: :ok}

  defp store_tokens(user_id, personal, memberships) do
    registry = Compendium.RegistryHost.canonical_host()

    entries =
      case personal do
        %{} = p -> [{slug_of(p), token_of(p), "personal"} | membership_entries(memberships)]
        _ -> membership_entries(memberships)
      end

    for {slug, token, role} <- entries,
        match?({:error, _}, CredentialStore.put_push_token(user_id, registry, slug, token, role)),
        do: slug
  end

  defp membership_entries(memberships) when is_list(memberships) do
    for m <- memberships, is_map(m), do: {slug_of(m), token_of(m), role_of(m)}
  end

  defp membership_entries(_), do: []

  defp slug_of(%{} = m), do: m["slug"] || m[:slug]
  defp slug_of(_), do: nil
  defp token_of(%{} = m), do: m["token"] || m[:token]
  defp role_of(%{} = m), do: m["role"] || m[:role] || "member"
end
