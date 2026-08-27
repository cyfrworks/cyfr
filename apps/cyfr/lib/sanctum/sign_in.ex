# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  What happens once, at sign-in, after the door admitted an identity — and
  never per request.

  `admitted/2`: the person's `users` row is written or refreshed; an
  operator (verdict `:admin`) gets the platform-admin membership and a seat
  in Home, and a person the env list no longer names loses the platform
  row; every `invited` group row for the person's verified email becomes
  their active membership; and — once the cyfr.run namespace is known — the
  person's own athanor is minted and provisioned
  (`Sanctum.Provisioning.after_sign_in/1`).

  `complete/3`: the one decision both sign-in paths (the browser callback
  and the CLI device flow) take after the door — what the cyfr.run probe
  says about the person, and what follows. A person this server already
  knows (`users.namespace` recorded) proceeds whatever the registry
  answers; a first-time person needs the registry once, to find or claim
  the namespace that is their identity everywhere.

  `record_namespace/2`: the namespace lands on the `users` row the moment a
  probe or a claim yields it — before, and regardless of, the push tokens.
  That row is what every request reads (`Sanctum.Namespace`).

  Providers call `admitted/2` between `Sanctum.Door.admit/3` and building
  the context. `Sanctum.Tenancy.resolve_into/2` — which runs per request —
  only ever reads what this wrote.
  """

  require Logger

  alias Arca.Schemas.User
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Slug
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @typedoc """
  What a sign-in does next.

  - `{:proceed, user, report}` — sign in; `report.unsynced` names namespaces
    whose push tokens could not be cached (a later probe re-mints them) and
    `report.probe` says how the registry answered (`:ok`, `:skipped` — no
    token to ask with, `:failed`, `:invalid_token`).
  - `{:needs_legal, version}` — cyfr.run wants the current policy accepted
    before it will say more.
  - `{:needs_claim, suggested}` — no personal namespace yet: claim one.
  - `{:reauthenticate, :idp_expired}` — the IdP token was refused; a fresh
    sign-in is the only way to a usable one.
  - `{:unavailable, reason}` — a first-time person and no registry answer:
    nothing was set up, try again.
  """
  @type report :: %{unsynced: [String.t()], probe: :ok | :skipped | :failed | :invalid_token}
  @type outcome ::
          {:proceed, User.t(), report()}
          | {:needs_legal, String.t() | nil}
          | {:needs_claim, String.t() | nil}
          | {:reauthenticate, :idp_expired}
          | {:unavailable, :registry_unreachable | :no_access_token | :namespace_conflict}

  # A person this server knows is not held at the door by a black-holed
  # registry: their probe gets this long, then they proceed and the push
  # tokens are refreshed by the next probe. (Configurable for tests.)
  @returning_probe_ms 5_000

  @doc """
  Record the admitted sign-in. `user_info` carries `id`, `provider`,
  `email`, `verified` (`true | false | :unknown`) and `name`.
  """
  @spec admitted(map(), :admin | :allowed) :: {:ok, Arca.Schemas.User.t()} | {:error, term()}
  def admitted(%{id: user_id} = user_info, verdict) when verdict in [:admin, :allowed] do
    with {:ok, user} <- Users.upsert_from_provider(user_info) do
      apply_platform(user_id, verdict)

      # The invited seats activate on the next sign-in; refusing this one
      # over a store blip would lock the person out. Loud, never silent —
      # the assertive match this replaces could not fail (both arms were
      # {:ok, _}), so a failed activation was invisible.
      case Members.activate_invited(user) do
        {:ok, _n} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Sanctum.SignIn] activate_invited failed for #{user_id}: #{inspect(reason)}"
          )
      end
      # Provisioning failure is recorded on the athanor and retried on the
      # next sign-in; it never refuses the sign-in itself.
      _ = Sanctum.Provisioning.after_sign_in(user_id)
      Users.get(user_id)
    end
  end

  @doc """
  Decide what follows the door: probe cyfr.run with the IdP `access_token`
  and absorb the answer. See `t:outcome/0`.
  """
  @spec complete(User.t(), String.t() | atom(), String.t() | nil) :: outcome()
  def complete(%User{} = user, _provider, access_token)
      when not is_binary(access_token) or access_token == "" do
    if returning?(user) do
      Logger.warning(
        "[Sanctum.SignIn] no IdP access token for #{user.id} — signing in without a probe"
      )

      {:proceed, user, %{unsynced: [], probe: :skipped}}
    else
      {:unavailable, :no_access_token}
    end
  end

  def complete(%User{} = user, provider, access_token) do
    returning? = returning?(user)

    case probe(provider, access_token, returning?) do
      {:ok, body} ->
        absorb(user, body, provider, returning?)

      {:error, :invalid_access_token} when returning? ->
        {:proceed, user, %{unsynced: [], probe: :invalid_token}}

      {:error, :invalid_access_token} ->
        {:reauthenticate, :idp_expired}

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required} = err} ->
        {:needs_legal, Compendium.OCI.Errors.required_version(err)}

      {:error, reason} when returning? ->
        Logger.warning(
          "[Sanctum.SignIn] cyfr.run probe failed for #{user.id} (#{inspect(reason)}) — " <>
            "signing in on the recorded namespace"
        )

        {:proceed, user, %{unsynced: [], probe: :failed}}

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.SignIn] cyfr.run probe failed for first-time #{user.id} " <>
            "(#{inspect(reason)}) — nothing set up"
        )

        {:unavailable, :registry_unreachable}
    end
  end

  @doc """
  Record the person's cyfr.run namespace: the durable copy on `users.namespace`
  that every request reads. Mints their own athanor when the row did not
  carry a namespace before. Refuses a slug another identity on this server
  already holds; a row that already carries a *different* slug keeps it
  (logged — the registry, not this server, would have to say which is
  right).
  """
  @spec record_namespace(String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :not_found | :invalid_slug | :namespace_owned_by_another_identity | term()}
  def record_namespace(user_id, slug) when is_binary(user_id) and is_binary(slug) do
    with true <- Sanctum.ComponentRef.valid_personal_slug?(slug) || {:error, :invalid_slug},
         {:ok, user} <- Users.get(user_id) do
      cond do
        user.namespace == slug ->
          {:ok, user}

        is_binary(user.namespace) ->
          # The namespace is meant to be the same person everywhere. When the
          # registry names another one, this server keeps what it recorded —
          # its athanor slug, its paths and its push attribution are all built
          # on it — and says so loudly enough to be noticed, because the
          # divergence is permanent until someone reconciles it at cyfr.run.
          Logger.warning(
            "[Sanctum.SignIn] cyfr.run names #{user_id} #{inspect(slug)} but this server " <>
              "recorded #{inspect(user.namespace)} — keeping the recorded one; reconcile at " <>
              "cyfr.run if the registry is right"
          )

          :telemetry.execute(
            [:cyfr, :sanctum, :identity, :namespace_divergence],
            %{count: 1},
            %{user_id: user_id, recorded: user.namespace, registry: slug}
          )

          {:ok, user}

        true ->
          case Users.get_by_namespace(slug) do
            {:ok, %User{id: other}} when other != user_id ->
              {:error, :namespace_owned_by_another_identity}

            {:error, :database_error} = err ->
              err

            _ ->
              with {:ok, user} <- Users.set_namespace(user, slug) do
                # The namespace is the person's athanor slug: mint it now.
                # A failure is recorded on the athanor and retried later; it
                # never undoes the identity.
                _ = Sanctum.Provisioning.after_sign_in(user_id)
                Users.get(user_id) |> or_user(user)
              end
          end
      end
    end
  end

  @doc """
  Absorb a cyfr.run probe body for a signed-in person outside `complete/3`
  (a re-probe from the CLI or after legal acceptance): record the
  namespace, cache the push tokens. Returns the slugs whose tokens could
  not be cached.
  """
  @spec absorb_probe(String.t(), map()) :: [String.t()]
  def absorb_probe(user_id, %{} = body) when is_binary(user_id) do
    personal = body["personal_namespace"]

    case slug_of(personal) do
      slug when is_binary(slug) ->
        case record_namespace(user_id, slug) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Sanctum.SignIn] namespace not recorded: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    store_tokens(user_id, personal, body["memberships"] || [])
  end

  # A person is "returning" when this server has recorded their namespace:
  # the registry is then a courtesy (push tokens, a legal bump), not the door.
  defp returning?(%User{namespace: ns}), do: is_binary(ns)

  defp probe(provider, access_token, false),
    do: Compendium.Registry.Client.probe_identity(provider, access_token)

  defp probe(provider, access_token, true) do
    task =
      Task.Supervisor.async_nolink(Sanctum.ProvisioningSupervisor, fn ->
        Compendium.Registry.Client.probe_identity(provider, access_token)
      end)

    budget = Application.get_env(:cyfr, :returning_probe_ms, @returning_probe_ms)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:probe_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp absorb(user, body, provider, returning?) do
    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    case slug_of(personal) do
      slug when is_binary(slug) ->
        case record_namespace(user.id, slug) do
          {:ok, user} ->
            {:proceed, user, report(store_tokens(user.id, personal, memberships))}

          {:error, :namespace_owned_by_another_identity} ->
            Logger.error(
              "[Sanctum.SignIn] cyfr.run names #{user.id} #{inspect(slug)}, which another " <>
                "identity on this server holds — refusing to sign in on it"
            )

            {:unavailable, :namespace_conflict}

          {:error, reason} when returning? ->
            Logger.warning("[Sanctum.SignIn] namespace not re-recorded: #{inspect(reason)}")
            {:proceed, user, report(store_tokens(user.id, personal, memberships))}

          {:error, reason} ->
            Logger.error("[Sanctum.SignIn] namespace not recorded: #{inspect(reason)}")
            {:unavailable, :registry_unreachable}
        end

      _ when returning? ->
        Logger.warning(
          "[Sanctum.SignIn] cyfr.run reports no personal namespace for #{user.id}, " <>
            "which this server recorded as #{inspect(user.namespace)} — proceeding on it"
        )

        {:proceed, user, report(store_tokens(user.id, nil, memberships))}

      _ ->
        {:needs_claim, suggested_slug(user, provider)}
    end
  end

  defp report(unsynced), do: %{unsynced: unsynced, probe: :ok}

  # Push tokens are cached best-effort: a failed write costs a re-probe,
  # never the sign-in. `:skipped` (no token in the body) is not a failure —
  # the identity was recorded from the slug regardless.
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

  # What to put in the claim box. The provider's own screen name is the
  # closest thing to what the person calls themselves — an
  # `alice.smith+work@` address suggests `alice-smith-work` when the GitHub
  # login next to it is simply `alice`. The address is the fallback, and the
  # provider name the last resort.
  defp suggested_slug(%User{display_name: name, email: email}, provider) do
    Slug.from_name(name) || Slug.from_email(email) || Slug.from_name("user-#{provider}")
  end

  defp or_user({:ok, user}, _fallback), do: {:ok, user}
  defp or_user(_, fallback), do: {:ok, fallback}

  # An operator's first sign-in mints the platform row and a seat in Home:
  # the out-of-the-box install is one admin with two athanors, Home and
  # their own. Removing an email from CYFR_PLATFORM_ADMIN_EMAILS revokes the
  # platform row on the next sign-in; the Home seat is an ordinary membership
  # and stays.
  defp apply_platform(user_id, :admin) do
    already? = platform_admin?(user_id)

    case Members.ensure_platform(user_id) do
      {:ok, _} ->
        unless already? do
          emit_platform_bootstrap(user_id)
          # A freshly granted operator bit reaches this person's already
          # mounted views: LiveAuth re-establishes on membership_changed.
          Members.broadcast_change(user_id, nil, :platform_granted)
        end

        seat_in_home(user_id)

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] platform admin bootstrap failed for #{user_id}: #{inspect(reason)}"
        )
    end
  end

  # An email dropped from CYFR_PLATFORM_ADMIN_EMAILS loses the operator bit
  # here: the revoke removes the row and revokes the person's other
  # sessions, so no established context keeps the capability. A revoke
  # that fails leaves an operator who should not be one — never silent.
  defp apply_platform(user_id, :allowed) do
    case Members.revoke_platform(user_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Sanctum.SignIn] platform revoke failed for #{user_id}: #{inspect(reason)}")

        :telemetry.execute([:cyfr, :sanctum, :door, :revoke_failed], %{count: 1}, %{
          user_id: user_id
        })

        :ok
    end
  end

  # A sign-in must not 500 on a broken install: no Home means no seat, loudly.
  # When the last Home was retired by its final member leaving, the operator's
  # sign-in mints its successor — the server always has one to seat them in.
  defp seat_in_home(user_id) do
    with {:ok, home} <- Athanors.ensure_home(),
         {:ok, _} <-
           Members.ensure(user_id, scope: "athanor", athanor_id: home.id, added_by: "system") do
      # Home is provisioned at boot; an operator's sign-in retries a boot
      # that could not reach the registry, with their credential.
      Sanctum.Provisioning.retry_home_async(user_id)
    else
      {:error, reason} ->
        Logger.error("[Sanctum.SignIn] Home seat failed: #{inspect(reason)}")
        :ok
    end
  end

  defp platform_admin?(user_id) do
    case Members.list_by_user(user_id) do
      {:ok, rows} -> Enum.any?(rows, &(&1.scope == "platform"))
      {:error, _} -> false
    end
  end

  # The widest grant in the system, and its only input is an email address —
  # under a generic OIDC issuer `email_verified` may legitimately be absent,
  # so the address is asserted rather than proven. Minting it is audited.
  defp emit_platform_bootstrap(user_id) do
    Logger.warning(
      "[Sanctum.SignIn] minted platform-scope membership for #{user_id} " <>
        "(matched CYFR_PLATFORM_ADMIN_EMAILS)"
    )

    :telemetry.execute(
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      %{count: 1},
      %{user_id: user_id}
    )
  end
end
