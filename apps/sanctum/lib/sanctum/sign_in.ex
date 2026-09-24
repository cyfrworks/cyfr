# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  What happens once, at sign-in, after the door admitted an identity — and
  never per request.

  `admitted/2`: the person's `users` row is written or refreshed; an
  operator (verdict `:admin`) gets the platform-admin membership, and a
  person the env list no longer names loses it; every `invited` group row for the person's verified email becomes
  their active membership; and the person's own athanor is minted and
  provisioned (`Sanctum.Provisioning.after_sign_in/1`). Admission is
  personhood: nothing here waits on a registry.

  The platform grant or revoke answers to the identity facts this
  assertion carried, checked under the person's lock, and a grant or
  revoke that fails — or finds those facts overtaken by a later
  assertion (`{:error, :stale_identity}`) — refuses the sign-in before
  any session is created.

  `complete/3`: the one courtesy both sign-in paths (the browser callback
  and the CLI device flow) extend after the door — a budgeted probe of
  cyfr.run for the person's publisher namespace and push tokens. Whatever
  the registry answers, the person proceeds; the report says how it
  answered. A namespace is a publishing credential, claimed when the
  person first publishes (`/claim-namespace`), never a gate on signing in.

  `record_namespace/2`: the namespace lands on the `users` row the moment a
  probe or a claim yields it — before, and regardless of, the push tokens.
  That row is what every request reads (`Sanctum.Namespace`).

  Providers call `admitted/2` between `Sanctum.Door.admit/3` and building
  the context. `Sanctum.Caller.establish/2` — which runs per request —
  only ever reads what this wrote.
  """

  require Logger

  alias Sanctum.Slug
  alias Sanctum.Tenancy.{Members, Users}

  @typedoc """
  What a sign-in reports. The person always proceeds; `unsynced` names
  namespaces whose push tokens could not be cached (a later probe re-mints
  them) and `probe` says how the registry answered:

  - `:ok` — answered; a namespace it named is recorded.
  - `:skipped` — no IdP token to ask with, or no registry configured.
  - `:failed` — no usable answer (down, 5xx, past the budget).
  - `:invalid_token` — the IdP refused the token; the next sign-in asks again.
  - `:legal_required` — cyfr.run wants its policy accepted before it says
    more; publishing will ask.
  - `:namespace_conflict` — the registry names a slug another identity on
    this server holds; nothing was recorded, and someone must reconcile it.
  """
  @type probe ::
          :ok | :skipped | :failed | :invalid_token | :legal_required | :namespace_conflict
  @type report :: %{unsynced: [String.t()], probe: probe()}
  @type outcome :: {:proceed, Sanctum.Tenancy.Users.user(), report()}

  @doc """
  Record the admitted sign-in. `user_info` carries `id`, `provider`,
  `email`, `verified` (`true | false | :unknown`) and `name`.
  """
  @spec admitted(map(), :admin | :allowed) ::
          {:ok, Sanctum.Tenancy.Users.user()} | {:error, term()}
  def admitted(%{id: _identity} = user_info, verdict) when verdict in [:admin, :allowed] do
    with {:ok, user} <- identify(user_info, verdict) do
      user_id = user.id

      # Log invitation activation failures without refusing sign-in.
      # Pending invitations can activate on the next sign-in.
      case Members.activate_invited(user) do
        {:ok, _n} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Sanctum.SignIn] activate_invited failed for #{user_id}: #{inspect(reason)}"
          )
      end

      # Filling the athanor is a background job whose failure lands on the
      # row and is retried; it never refuses the sign-in. Failing to MINT
      # one does refuse it: the caps bound how fast strangers arrive and
      # how many estates the server holds, and a person admitted without an
      # athanor would hold a session with nowhere to work.
      case Sanctum.Provisioning.after_sign_in(user_id) do
        {:error, reason} -> {:error, reason}
        _ -> Users.get(user_id)
      end
    end
  end

  @doc false
  # The identity half of `admitted/2`, which runs it first: the person's
  # row written from this assertion, then the platform grant reconciled
  # against exactly the facts this assertion carried — before the rest of
  # the sign-in, and before any session. Public so the interleaving tests
  # can race it without the provisioning that follows.
  #
  # The facts are this assertion's, never another's: a concurrent first
  # sign-in that lost the race to mint the person is answered the winner's
  # row, and that row must not become what this sign-in expects. So the
  # upsert's answer is checked against them too, and the grant or revoke
  # checks them again under the person's lock. `{:error, :stale_identity}`
  # is this assertion having been overtaken; the person signs in again.
  @spec identify(map(), :admin | :allowed) ::
          {:ok, Sanctum.Tenancy.Users.user()} | {:error, term()}
  def identify(user_info, verdict) when verdict in [:admin, :allowed] do
    with {:ok, user} <- Users.upsert_from_provider(user_info) do
      expected = expected_identity(user_info, user)

      cond do
        user.email != expected.email or user.email_verified != expected.email_verified ->
          {:error, :stale_identity}

        true ->
          with :ok <- apply_platform(user.id, verdict, expected), do: {:ok, user}
      end
    end
  end

  @doc false
  # What one admitted assertion says about the person, as the `users` row
  # stores it: the supplied email lowercased — the row's own only when the
  # assertion carried none, since an absent claim leaves the stored one in
  # place — and the verification claim as `true`, `false`, or `nil` for
  # anything else.
  @spec expected_identity(map(), Sanctum.Tenancy.Users.user()) :: Arca.Members.identity()
  def expected_identity(user_info, %{id: _} = user) do
    email =
      case Map.get(user_info, :email) do
        email when is_binary(email) and email != "" -> String.downcase(email)
        _absent -> user.email
      end

    verified =
      case Map.get(user_info, :verified) do
        claim when is_boolean(claim) -> claim
        _unknown -> nil
      end

    %{email: email, email_verified: verified}
  end

  @doc """
  Record the person's cyfr.run namespace: the durable copy on `users.namespace`
  that every request reads. Their own athanor was minted at admission; this
  only reruns the provisioning hook so a namespace-holding person's groups
  retry. Refuses a slug another identity on this server already holds; a
  row that already carries a *different* slug keeps it (logged — the
  registry, not this server, would have to say which is right).
  """
  @spec record_namespace(String.t(), String.t()) ::
          {:ok, Sanctum.Tenancy.Users.user()}
          | {:error, :not_found | :invalid_slug | :namespace_owned_by_another_identity | term()}
  def record_namespace(user_id, slug) when is_binary(user_id) and is_binary(slug) do
    with true <- Prima.ComponentRef.valid_personal_slug?(slug) || {:error, :invalid_slug},
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
            {:ok, %{id: other}} when other != user_id ->
              {:error, :namespace_owned_by_another_identity}

            {:error, :database_error} = err ->
              err

            _ ->
              with {:ok, user} <- Users.set_namespace(user, slug) do
                # The athanor exists since admission; the hook retries any
                # provisioning that failed. It never undoes the identity.
                _ = Sanctum.Provisioning.after_sign_in(user_id)
                Users.get(user_id) |> or_user(user)
              end
          end
      end
    end
  end

  @doc """
  The slug to suggest when a person claims a publisher namespace: their
  screen name, else the address's local part, else a provider-flavoured
  placeholder.
  """
  @spec suggested_slug(Sanctum.Tenancy.Users.user(), String.t() | atom()) :: String.t() | nil
  def suggested_slug(%{display_name: name, email: email}, provider) do
    Slug.from_name(name) || Slug.from_email(email) || Slug.from_name("user-#{provider}")
  end

  # Push tokens are cached best-effort: a failed write costs a re-probe,
  # never the sign-in. `:skipped` (no token in the body) is not a failure —
  # the identity was recorded from the slug regardless.
  # What to put in the claim box. The provider's own screen name is the
  # closest thing to what the person calls themselves — an
  # `alice.smith+work@` address suggests `alice-smith-work` when the GitHub
  # login next to it is simply `alice`. The address is the fallback, and the
  # provider name the last resort.
  defp or_user({:ok, user}, _fallback), do: {:ok, user}
  defp or_user(_, fallback), do: {:ok, fallback}

  # An operator's first sign-in mints the platform row: the out-of-the-box
  # install is one admin with one athanor, their own. Removing an email from
  # CYFR_PLATFORM_ADMIN_EMAILS revokes the platform row on the next sign-in.
  # A grant that cannot be written refuses the sign-in: the person would
  # otherwise hold a session without the standing the door decided on.
  defp apply_platform(user_id, :admin, expected) do
    case Members.grant_platform(user_id, expected) do
      {:ok, :granted} ->
        emit_platform_bootstrap(user_id)
        # A freshly granted operator bit reaches this person's already
        # mounted views: their guard revalidates on membership_changed.
        Members.broadcast_change(user_id, nil, :platform_granted)
        :ok

      {:ok, :held} ->
        :ok

      {:error, reason} = refusal ->
        Logger.error(
          "[Sanctum.SignIn] platform admin grant refused for #{user_id}: #{inspect(reason)}"
        )

        refusal
    end
  end

  # An email dropped from CYFR_PLATFORM_ADMIN_EMAILS loses the operator bit
  # here: the revoke removes the row and the person's sessions together, so
  # no established context keeps the capability. A revoke that fails
  # leaves an operator who should not be one — never silent, and the
  # sign-in is refused rather than minting a session beside it.
  defp apply_platform(user_id, :allowed, expected) do
    case Members.revoke_platform(user_id, expected_identity: expected) do
      :ok ->
        :ok

      {:error, reason} = refusal ->
        Logger.error("[Sanctum.SignIn] platform revoke failed for #{user_id}: #{inspect(reason)}")

        :telemetry.execute([:cyfr, :sanctum, :door, :revoke_failed], %{count: 1}, %{
          user_id: user_id
        })

        refusal
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
