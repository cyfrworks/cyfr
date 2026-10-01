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

  A first admitted sign-in mints the person with their live and
  operational key set (`Sanctum.Person.mint_keys/1`) in the one
  transaction that writes the person row and the door that admitted them,
  after the installation guard (`Arca.InstallationClaims`) admitted a
  first person at all. A key set that cannot be minted refuses the
  sign-in, and so does an installation reserved for a restore, whatever
  the door's verdict: nothing is written, and no session follows.

  A person the `cyfr` door admits (`Sanctum.Auth.CyfrDoor`) holds their
  keys at another home: their first sign-in, carrying `remote:` (their
  identifier, directory and heads), mints the person row with a `remote`
  identity row and no key, and no personal athanor is minted for them,
  then or later: they hold here only what an invitation or a membership
  gives them. Provenance is written once. A person keeps it whichever door
  they later sign in through, a passkey registered here or a door linked
  here included, and only a newly created local person is minted keys.

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

  ## Linking a door

  A sign-in can also prove control of a new door for a person already
  signed in, instead of signing anyone in. `link_ticket/2` is minted by the
  surface that completed that sign-in (the OpenID Connect callback in link
  mode, or `Sanctum.Auth.DeviceFlow.poll_for_link/4`), only after the door
  admits the identity and only for a standing, non-guest session: 32
  random bytes, held in `Arca.Cache` under their SHA-256 for ten minutes
  on the node that minted them, bound to the person, their session's
  token hash, the identity (provider, issuer and subject) and the email
  claim the door judged. The ticket travels in the browser's cookie
  session or to the page that polled, never in a URL.

  `link_door/3` (`person.link_door`) reads the ticket without taking it:
  the person, the session and the provider must be the ticket's, or one
  sentence refuses it, whichever was wrong. It then decides
  `sign_in_methods` (`Sanctum.Consent.Authz.check/3`), whose preview names
  the door by provider and subject with the issuer and email as details;
  asking for a confirmation leaves the ticket in place. On the repeat it
  takes the ticket and links the identity (`Arca.Users.link_identity/4`)
  with the confirmation consumed in the same transaction; a failed write
  spends the ticket. An identity already the person's answers linked with
  no write; one another person holds is a conflict. Linking writes no
  email: a matching email never links anyone. Only `github`, `google` and
  `oidcc` doors are linked this way; an email address and a passkey are
  not doors to link.

  `unlink_door/2` (`person.unlink_door`) removes one of the person's own
  identities under the same confirmation, consumed inside the delete, and
  refuses to remove the last one unless the person holds an active
  passkey here and the door admits them without it: by their own id, an
  email entry for their verified email, or `*`
  (`Sanctum.Door.admit_person/1`). Either missing would leave no way to
  sign in. The check runs again under the person's lock, where revoking a
  passkey takes the same lock (`Sanctum.Passkeys.revoke/2`).
  """

  require Logger

  alias Prima.Identity.Encoding
  alias Sanctum.Auth.Identity
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Slug
  alias Sanctum.Tenancy.{Members, Users}

  @linkable ~w(github google oidcc)
  @link_ticket_ms 600_000
  @link_refused "This sign-in link is not yours, has expired or was already used; sign in " <>
                  "with that door again"

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
  `email`, `verified` (`true | false | :unknown`) and `name`, and, for a
  person the `cyfr` door admits, `remote`: their `identifier`,
  `directory_url`, `genesis_hash` and `head_hash` (the module doc).
  """
  @spec admitted(map(), :admin | :allowed) ::
          {:ok, Sanctum.Tenancy.Users.user()} | {:error, term()}
  def admitted(%{id: _identity} = user_info, verdict) when verdict in [:admin, :allowed] do
    with {:ok, user} <- identify(user_info, verdict),
         {:ok, provenance} <- provenance(user.id) do
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

      provisioned(user_id, provenance)
    end
  end

  # Filling the athanor is a background job whose failure lands on the
  # row and is retried; it never refuses the sign-in. Failing to MINT one
  # does refuse it: the caps bound how fast strangers arrive and how many
  # athanors the server holds, and a person admitted without an athanor
  # would hold a session with nowhere to work. A remote person is minted
  # none: their own athanor is at their own home, and here they hold what
  # a membership gives them, or nothing.
  defp provisioned(user_id, "remote"), do: Users.get(user_id)

  defp provisioned(user_id, _local) do
    case Sanctum.Provisioning.after_sign_in(user_id) do
      {:error, reason} -> {:error, reason}
      _ -> Users.get(user_id)
    end
  end

  # The person's provenance, as their identity row records it: `remote`,
  # `local`, or `nil` for a person with no identity row (a local person,
  # who holds no key here yet). A store that cannot answer refuses.
  defp provenance(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: provenance}} -> {:ok, provenance}
      {:error, :not_found} -> {:ok, nil}
      {:error, _unanswered} -> {:error, :unavailable}
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
    {remote, user_info} = Map.pop(user_info, :remote)

    with {:ok, user} <- Users.upsert_from_provider(user_info, remote: remote) do
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

  # ---------------------------------------------------------------------------
  # Linking a door
  # ---------------------------------------------------------------------------

  @typedoc """
  An identity a completed sign-in proved, to link to the person signed in:
  its key (`Sanctum.Auth.Identity.key/3`), provider, and the email and
  verification the provider asserted.
  """
  @type link_identity :: %{
          required(:key) => String.t(),
          required(:provider) => String.t() | atom(),
          optional(:email) => String.t() | nil,
          optional(:verified) => boolean() | :unknown
        }

  @doc """
  Mint a link ticket (the module doc) for `identity`, the identity a
  sign-in just completed, bound to the person and session of `ctx`, a
  session context the surface established. The session must still stand
  (`Sanctum.Caller.revalidate_session/1`) and be no guest's, the provider
  linkable, and the door must admit the identity
  (`Sanctum.Door.admit_identity/2`, which records a refusal the operator
  can act on).

  Refusals: `:unauthenticated` (no standing session), `:not_linkable`,
  `{:door, reason}`, `:unavailable`.
  """
  @spec link_ticket(Context.t(), link_identity()) :: {:ok, String.t()} | {:error, term()}
  def link_ticket(%Context{} = ctx, %{key: key, provider: provider} = identity)
      when is_binary(key) do
    provider = to_string(provider)

    with {:ok, standing} <- linking_session(ctx),
         {:ok, parts} <- linkable_key(key, provider),
         {:ok, _verdict} <-
           Sanctum.Door.admit_identity(key, %{
             email: identity[:email],
             verified: Map.get(identity, :verified, :unknown)
           }) do
      ticket = Encoding.b64(:crypto.strong_rand_bytes(32))

      Arca.Cache.put(
        ticket_key(ticket),
        %{
          user_id: standing.user_id,
          session: standing.session_token_hash,
          key: key,
          provider: parts.provider,
          issuer: parts.issuer,
          subject: parts.subject,
          email: identity[:email],
          verified: Map.get(identity, :verified, :unknown)
        },
        @link_ticket_ms
      )

      {:ok, ticket}
    end
  end

  @doc """
  Link the door `provider` the ticket `ticket` proves to the person of
  `ctx` (`person.link_door`, the module doc). Answers `%{linked: true |
  false, door: %{key, provider, issuer, subject}}`, `linked: false` for an
  identity already the person's.

  Refusals: `{:invalid_argument, _}` (a ticket missing, expired, spent,
  another person's or another session's, or naming another provider; a
  door that is not linkable), the consent signal `{:confirmation_required,
  _}` and the confirmation's other refusals (`Sanctum.Consent.Authz`),
  `{:conflict, _}` (another person's identity), `{:door, reason}` (the door
  no longer admits it), `:not_standing`, `:unavailable`.
  """
  @spec link_door(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def link_door(%Context{} = ctx, provider, ticket)
      when is_binary(provider) and is_binary(ticket) do
    with :ok <- linkable(provider),
         {:ok, held} <- held_ticket(ctx, provider, ticket) do
      door = Map.take(held, [:key, :provider, :issuer, :subject])

      case Users.get_by_identity(held.key) do
        {:ok, %{id: user_id}} when user_id == ctx.user_id ->
          _spent = Arca.Cache.take(ticket_key(ticket))
          {:ok, %{linked: false, door: door}}

        {:ok, _another} ->
          _spent = Arca.Cache.take(ticket_key(ticket))
          {:error, {:conflict, "That sign-in already belongs to another person here"}}

        {:error, :not_found} ->
          link_confirmed(ctx, provider, ticket, held, door)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  def link_door(%Context{}, _provider, _ticket), do: {:error, {:invalid_argument, @link_refused}}

  defp link_confirmed(ctx, provider, ticket, held, door) do
    change = link_change(provider, ticket, held)

    with :ok <- Authz.check(ctx, :sign_in_methods, change),
         {:ok, held} <- taken_ticket(ctx, provider, ticket),
         {:ok, _verdict} <- door_admits(held) do
      case Arca.Users.link_identity(
             Prima.Actor.system(),
             ctx.user_id,
             door,
             also: fn _linked -> Authz.consume(ctx, {:sign_in_methods, change}) end
           ) do
        {:ok, %{linked: linked}} ->
          if linked, do: Authz.consumed(ctx)
          {:ok, %{linked: linked, door: door}}

        {:error, :conflict} ->
          {:error, {:conflict, "That sign-in already belongs to another person here"}}

        {:error, reason} when reason in [:not_active, :not_found] ->
          {:error, :not_standing}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # What confirming a link approves: this door, by provider and subject,
  # proven by this ticket.
  defp link_change(provider, ticket, held) do
    details =
      %{"issuer" => held.issuer, "subject" => held.subject}
      |> Prima.MapUtil.put_present("email", held.email)

    %{
      operation: "person.link_door",
      arguments: %{"provider" => provider, "ticket" => ticket},
      resource: provider <> " sign-in " <> held.subject,
      details: details
    }
  end

  @doc """
  Unlink the person's own door `key` (`person.unlink_door`, the module
  doc). Answers `%{unlinked: %{key, provider, issuer, subject}}`.

  Refusals: `{:not_found, "door", key}` (no identity of the person's),
  `{:conflict, _}` (their last door while they hold no active passkey
  here, or while this server admits them only through that door), the
  consent signal and the confirmation's other refusals, `:not_standing`,
  `:unavailable`.
  """
  @spec unlink_door(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def unlink_door(%Context{user_id: user_id} = ctx, key) when is_binary(key) do
    with {:ok, _person} <- signed_in_person(ctx),
         {:ok, identities} <- own_identities(user_id),
         %{} = identity <-
           Enum.find(identities, &(&1.key == key)) || {:error, {:not_found, "door", key}},
         :ok <- keeps_a_door(ctx, length(identities) - 1) do
      door = Map.take(identity, [:key, :provider, :issuer, :subject])

      change = %{
        operation: "person.unlink_door",
        arguments: %{"door" => key},
        resource: identity.provider <> " sign-in " <> identity.subject,
        details: %{"issuer" => identity.issuer, "subject" => identity.subject}
      }

      with :ok <- Authz.check(ctx, :sign_in_methods, change) do
        also = fn %{remaining: remaining} ->
          with :ok <- keeps_a_door(ctx, remaining),
               do: Authz.consume(ctx, {:sign_in_methods, change})
        end

        case Arca.Users.unlink_identity(Prima.Actor.system(), user_id, key, also: also) do
          {:ok, _unlinked} ->
            Authz.consumed(ctx)
            {:ok, %{unlinked: door}}

          {:error, :not_found} ->
            {:error, {:not_found, "door", key}}

          {:error, :not_active} ->
            {:error, :not_standing}

          {:error, :database_error} ->
            {:error, :unavailable}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def unlink_door(%Context{}, _key),
    do: {:error, {:invalid_argument, "The door to unlink is named by its identity key"}}

  # The last door goes only while the person keeps a way in without it: an
  # active passkey here, and a door that admits them as a person with no
  # linked door (`Sanctum.Door.admit_person/1`), which is what the passkey
  # door asks of them once it is gone. An entry naming only this door's
  # identity admits no one after it.
  defp keeps_a_door(_ctx, remaining) when remaining > 0, do: :ok

  defp keeps_a_door(%Context{user_id: user_id} = ctx, _none_left) do
    with :ok <- holds_a_passkey(ctx, user_id), do: admitted_without_doors(user_id)
  end

  defp holds_a_passkey(ctx, user_id) do
    case Arca.Passkeys.list(Context.actor(ctx), user_id, state: :active) do
      {:ok, rows} ->
        if Enum.any?(rows, &(&1.rp_id == Sanctum.Passkeys.rp_id())),
          do: :ok,
          else:
            {:error,
             {:conflict,
              "This is your last door here and you hold no passkey to sign in with; " <>
                "register a passkey or link another door before you unlink it"}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp admitted_without_doors(user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        case Sanctum.Door.admit_person(user) do
          {:ok, _admitted} ->
            :ok

          {:error, :unavailable} ->
            {:error, :unavailable}

          {:error, _refused} ->
            {:error,
             {:conflict,
              "This server admits you only through this door; link another door first, or " <>
                "ask the operator to allow your account, before you unlink it"}}
        end

      {:error, :not_found} ->
        {:error, :not_standing}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own_identities(user_id) do
    case Arca.Users.identities(Prima.Actor.system(), user_id) do
      {:ok, identities} -> {:ok, identities}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A person signed in through a stored session, on the external plane: a
  # door belongs to a person, and a ticket to the session that asked.
  defp signed_in_person(%Context{plane: :guest}), do: {:error, :unauthenticated}

  defp signed_in_person(%Context{user_id: user_id, session_token_hash: hash} = ctx)
       when is_binary(user_id) and is_binary(hash) do
    if ctx.authenticated and not ctx.anonymous and Prima.PersonId.person?(user_id),
      do: {:ok, ctx},
      else: {:error, :unauthenticated}
  end

  defp signed_in_person(%Context{}), do: {:error, :unauthenticated}

  defp linking_session(ctx) do
    with {:ok, ctx} <- signed_in_person(ctx) do
      case Sanctum.Caller.revalidate_session(ctx) do
        {:ok, %Context{session_token_hash: hash} = standing} when is_binary(hash) ->
          {:ok, standing}

        {:ok, _no_session} ->
          {:error, :unauthenticated}

        {:error, reason} when reason in [:unavailable, :identity_stale] ->
          {:error, :unavailable}

        {:error, _gone} ->
          {:error, :unauthenticated}
      end
    end
  end

  defp linkable(provider) when provider in @linkable, do: :ok

  defp linkable(_provider),
    do:
      {:error,
       {:invalid_argument,
        "Only a GitHub, Google or OpenID Connect sign-in is linked as a door; an email address " <>
          "or a passkey is not"}}

  defp linkable_key(key, provider) do
    with :ok <- linkable(provider),
         {:ok, %{provider: ^provider} = parts} <- Identity.parse(key) do
      {:ok, parts}
    else
      {:error, {:invalid_argument, _}} -> {:error, :not_linkable}
      _other -> {:error, :not_linkable}
    end
  end

  # The ticket, read and not taken, held to the person, the session and
  # the provider asked for. One sentence answers every way it does not hold.
  defp held_ticket(ctx, provider, ticket) do
    with {:ok, ctx} <- signed_in_person(ctx),
         {:ok, held} <- Arca.Cache.get(ticket_key(ticket)) |> found(),
         :ok <- bound(held, ctx, provider) do
      {:ok, held}
    else
      {:error, :unauthenticated} -> {:error, :unauthenticated}
      _refused -> {:error, {:invalid_argument, @link_refused}}
    end
  end

  # The ticket taken, once, and held to the same bindings: of two repeats
  # presenting it, one links.
  defp taken_ticket(ctx, provider, ticket) do
    with {:ok, held} <- Arca.Cache.take(ticket_key(ticket)) |> found(),
         :ok <- bound(held, ctx, provider) do
      {:ok, held}
    else
      _refused -> {:error, {:invalid_argument, @link_refused}}
    end
  end

  defp found({:ok, %{user_id: _, session: _, key: _, provider: _} = held}), do: {:ok, held}
  defp found(_miss), do: {:error, :missing}

  defp bound(held, %Context{user_id: user_id, session_token_hash: hash}, provider) do
    if held.user_id == user_id and held.provider == provider and is_binary(hash) and
         Plug.Crypto.secure_compare(held.session, hash),
       do: :ok,
       else: {:error, :mismatch}
  end

  # The door is asked again as the link is written: an identity the
  # operator closed the door on since the ticket was minted is not linked.
  defp door_admits(held) do
    case Sanctum.Door.admit(held.key, held.email, held.verified) do
      {:ok, verdict} -> {:ok, verdict}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, reason} -> {:error, {:door, reason}}
    end
  end

  defp ticket_key(ticket), do: {:link_ticket, :crypto.hash(:sha256, ticket)}

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
