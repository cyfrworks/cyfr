# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  What happens once, at sign-in, and never per request.

  `unlock/1`: a linked sign-in method (GitHub, Google, an OpenID Connect
  issuer, or the CYFR sign-in of a person admitted here before) unlocks
  the person it names, and never makes one. The person the method's
  identity key names (`Sanctum.Tenancy.Users.get_by_identity/1`) is asked
  about by the door (`Sanctum.Door.sign_in/1`), their contact email is
  refreshed from a claim the provider proved (`Sanctum.Tenancy.Users.seen/2`),
  the identifier invitations their CYFR identity holds activate, and their
  athanors' fills are asked for (`Sanctum.Provisioning.after_sign_in/1`).
  An identity no person has linked is refused `:no_person` and leaves no
  door request. A person is made only by an admission
  (`Sanctum.Newcomer`). No sign-in speaks to the registry.

  `record_claim/2` and `record_namespace/2`: the namespace lands on the
  `users` row the moment the registry's answer to a claim or a token mint
  names it, before, and regardless of, the push tokens. That row is what
  every request reads (`Sanctum.Namespace`).

  The sign-in paths (the browser callback, the device flow and the CYFR
  sign-in) call `unlock/1` before building the context.
  `Sanctum.Caller.establish/2` — which runs per request — only ever reads
  what this wrote.

  ## Linking a door

  A sign-in can also prove control of a new door for a person already
  signed in, instead of signing anyone in. `link_ticket/2` is minted by the
  surface that completed that sign-in (the OpenID Connect callback in link
  mode, or `Sanctum.Auth.DeviceFlow.poll_for_link/4`), only for a
  standing, non-guest session: 32
  random bytes, held in `Arca.Cache` under their SHA-256 for ten minutes
  on the node that minted them, bound to the person, their session's
  token hash, the identity (provider, issuer and subject) and the email
  claim the provider made. The ticket travels in the browser's cookie
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
  passkey here and the door admits them (`Sanctum.Door.admit_person/1`).
  Either missing would leave no way to sign in. The check runs again under the person's lock, where revoking a
  passkey takes the same lock (`Sanctum.Passkeys.revoke/2`).
  """

  require Logger

  alias Prima.Identity.Encoding
  alias Sanctum.Auth.Identity
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Members, Users}

  @typedoc """
  What a linked sign-in method's provider proved: the method's identity
  key (`Sanctum.Auth.Identity.key/3`) as `id`, and what it said of the
  person's contact fields (`t:Sanctum.Tenancy.Users.provider_info/0`).
  """
  @type method :: Users.provider_info()

  @linkable Prima.SignInProviders.all()
  @link_ticket_ms 600_000
  @link_refused "This sign-in link is not yours, has expired or was already used; sign in " <>
                  "with that sign-in method again"

  @doc """
  Unlock the person a linked sign-in method names (the module doc), and
  answer them as their row reads after the sign-in was recorded.

  Refusals: `:no_person` (no person here holds this method),
  `{:door, reason}` (the door refuses the person, or they are not
  active: `:denied`, `:not_allowed`, `:unavailable`), `:unavailable` (the
  store could not answer). Nothing is written on a refusal.
  """
  @spec unlock(method()) ::
          {:ok, Users.user()} | {:error, :no_person | {:door, atom()} | :unavailable}
  def unlock(%{id: key} = method) when is_binary(key) do
    case Users.get_by_identity(key) do
      {:ok, %{status: "active"} = user} ->
        with {:ok, :allowed} <- Sanctum.Door.sign_in(user),
             {:ok, _seen} <- seen(user, method) do
          unlocked(user.id)
        end

      {:ok, _not_active} ->
        {:error, {:door, :denied}}

      {:error, :not_found} ->
        {:error, :no_person}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp seen(user, method) do
    case Users.seen(user, method) do
      {:ok, seen} -> {:ok, seen}
      {:error, _unwritten} -> {:error, :unavailable}
    end
  end

  # Invitations activate and fills are asked for without refusing the
  # sign-in: a pending invitation activates on the next one, and a fill's
  # failure lands on its athanor's row.
  defp unlocked(user_id) do
    case Members.activate_invited(%{id: user_id}) do
      {:ok, _n} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] activate_invited failed for #{user_id}: #{inspect(reason)}"
        )
    end

    :ok = Sanctum.Provisioning.after_sign_in(user_id)
    Users.get(user_id) |> or_unavailable()
  end

  defp or_unavailable({:ok, user}), do: {:ok, user}
  defp or_unavailable({:error, _unanswered}), do: {:error, :unavailable}

  @doc """
  Record the registry's answer to the caller's handle claim
  (`%{"handle" => slug, "identifier" => identifier}`), only while the
  caller stands: their standing is read again first
  (`Sanctum.Caller.revalidate_session/1`), so a session, key or device
  revoked while the registry answered records nothing; the answer must
  name the identifier the caller signed the claim under
  (`:malformed_answer` otherwise: it answered for someone else); then the
  slug is recorded (`record_namespace/2`). Answers the context as it was
  read again, for the writes that follow under it. A store that cannot
  answer, or a remote person whose identity could not be confirmed fresh,
  is `:unavailable` or `:identity_stale` and the session stands; any
  other standing refusal is `:unauthenticated`.
  """
  @spec record_claim(Context.t(), map()) ::
          {:ok, Context.t()}
          | {:error,
             :unauthenticated
             | :unavailable
             | :identity_stale
             | :malformed_answer
             | :not_found
             | :invalid_slug
             | :namespace_owned_by_another_identity
             | term()}
  def record_claim(%Context{user_id: user_id} = ctx, %{
        "handle" => slug,
        "identifier" => identifier
      })
      when is_binary(user_id) and is_binary(slug) and is_binary(identifier) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, fresh} ->
        with :ok <- claimed_by(user_id, identifier),
             {:ok, _user} <- record_namespace(user_id, slug),
             do: {:ok, fresh}

      {:error, reason} when reason in [:unavailable, :identity_stale] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  def record_claim(%Context{}, _answer), do: {:error, :malformed_answer}

  # The answer names the identifier the person's own identity row holds.
  defp claimed_by(user_id, identifier) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{identifier: ^identifier}} -> :ok
      {:ok, _another} -> {:error, :malformed_answer}
      {:error, :not_found} -> {:error, :malformed_answer}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Record the person's cyfr.run namespace, as a registry answer names it:
  the durable copy on `users.namespace` that every request reads. Their own athanor was minted at admission; this
  only reruns the provisioning hook so a namespace-holding person's groups
  retry. Refuses a slug another identity on this server already holds; a
  row that already carries a *different* slug keeps it (logged — the
  registry, not this server, would have to say which is right).
  """
  @spec record_namespace(String.t(), String.t()) ::
          {:ok, Sanctum.Tenancy.Users.user()}
          | {:error, :not_found | :invalid_slug | :namespace_owned_by_another_identity | term()}
  def record_namespace(user_id, slug) when is_binary(user_id) and is_binary(slug) do
    with :ok <- personal_slug(slug),
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
  (`Sanctum.Caller.revalidate_session/1`) and be no guest's, and the
  provider linkable.

  Refusals: `:unauthenticated` (no standing session), `:not_linkable`,
  `:unavailable`.
  """
  @spec link_ticket(Context.t(), link_identity()) :: {:ok, String.t()} | {:error, term()}
  def link_ticket(%Context{} = ctx, %{key: key, provider: provider} = identity)
      when is_binary(key) do
    provider = to_string(provider)

    with {:ok, standing} <- linking_session(ctx),
         {:ok, parts} <- linkable_key(key, provider) do
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
  the addition refusal (`Sanctum.Pairing.addition_refusal/0`: a
  confirmation no passkey or paired client gave, once one ever existed),
  `{:conflict, _}` (another person's identity), `:not_standing`,
  `:unavailable`.
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
         {:ok, _held} <- taken_ticket(ctx, provider, ticket) do
      case Arca.Users.link_identity(
             Prima.Actor.system(),
             ctx.user_id,
             door,
             also: fn _linked -> linked_confirmed(ctx, change) end
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

  # Inside the link's transaction, under the person's lock: the
  # confirmation consumed, and, once a passkey or a paired device ever
  # existed for the person, one of them must have given it
  # (`Sanctum.Pairing.addition_confirmed/1`).
  defp linked_confirmed(ctx, change) do
    with :ok <- Authz.consume(ctx, {:sign_in_methods, change}),
         do: Sanctum.Pairing.addition_confirmed(ctx)
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
           Enum.find(identities, &(&1.key == key)) ||
             {:error, {:not_found, "sign-in method", key}},
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
            {:error, {:not_found, "sign-in method", key}}

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
    do: {:error, {:invalid_argument, "The sign-in method to unlink is named by its identity key"}}

  # The last linked method goes only while the person keeps a way in
  # without it: an active passkey here, and a door that admits them
  # (`Sanctum.Door.admit_person/1`), which is what a passkey sign-in asks
  # of them once it is gone.
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
              "This is your last sign-in method here and you hold no passkey to sign in with; " <>
                "register a passkey or link another sign-in method before you unlink it"}}

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
              "This server does not admit you without this sign-in method; link another sign-in method " <>
                "first, or ask the operator to allow you, before you unlink it"}}
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
        "Only a GitHub, Google or OpenID Connect sign-in is linked as a sign-in method; an email address " <>
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

  defp ticket_key(ticket), do: {:link_ticket, :crypto.hash(:sha256, ticket)}

  # The row as reread after a write, or the row the write returned when
  # the reread fails.
  defp or_user({:ok, user}, _fallback), do: {:ok, user}
  defp or_user(_, fallback), do: {:ok, fallback}

  defp personal_slug(slug) do
    if Prima.ComponentRef.valid_personal_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end
end
