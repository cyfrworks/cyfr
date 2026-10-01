# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Members do
  @moduledoc """
  Membership assignments — "user X is a member of athanor A".

  A membership row is a presence-only grant: its existence makes the user a
  member (every member is the athanor's admin — there is no role tier). A
  `"platform"` row names no athanor: it makes the user a platform admin, the
  server's operator, minted on first sign-in for the emails in
  `CYFR_PLATFORM_ADMIN_EMAILS` (see `Sanctum.SignIn`).

  An `invited` row names an email or a person identifier (`per_…`) instead
  of a person: someone was added to a group before they ever signed in
  here. It activates on their first admitted sign-in (`activate_invited/1`):
  an email for an address the provider proved, an identifier for the
  `cyfr` identity the person signed in with. It is withdrawn when the door
  denies that address or identifier (`withdraw_invites_for_email/1`,
  `withdraw_invites_for_identifier/1`) — a seat must not outlive the
  eject. Adding an email or an identifier the door does not admit also
  queues a request for the platform admin — an invite never opens the
  door by itself.

  Leaving an athanor, or being removed from one, is one standing
  transition (`Arca.SecurityTransitions.leave_athanor/3`): the seat, the
  person's follows there, their sessions bound to it and the frame
  credentials, paired clients, device certificates and pending pairing
  invitations they hold there go together, and a remote person left with
  no membership here is retired here with it (that transition's doc).
  Their other memberships, their identity and their door entry stand: a
  removal is not a deny, so they may still sign in, admitted to nothing
  they were removed from. An address a client saved for this home grants
  nothing either way.

  Every change is announced (`Sanctum.Telemetry.membership_changed/3`),
  keyed by the person, so a mounted LiveView can re-derive what it shows.

  ## What is decided here, and what is stored below

  The statements are `Arca.Members`'. What stays here is the deciding: who
  may be seated and on what proof, which cap bounds a roster, that a
  frozen athanor never gains a member, what a leave archives, and who is
  told afterwards. A row inside one athanor is written and read as the
  server narrowed to that athanor; the rows that name no athanor, or that
  name a person across every athanor, run as the server itself.
  """

  alias Sanctum.Door
  alias Sanctum.Tenancy.{Athanors, Caps, Users}

  @typedoc "A membership row, as the plain map `Arca.Members` answers."
  @type membership :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc """
  Insert a membership. `attrs` must carry `:scope`; an active row `:user_id`,
  an invited row `:email`; `:athanor_id` is required for the `"athanor"`
  scope and must name an existing athanor.
  """
  @spec create(map(), keyword()) :: {:ok, membership()} | {:error, term()}
  def create(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    if Map.get(attrs, :scope) == "platform" do
      Arca.Members.grant_platform(server(), attrs)
    else
      seat(attrs, opts)
    end
  end

  # A frozen athanor took its members at birth and never gains another —
  # every writer of a membership row is held to that here, not only
  # `add/3`; the birth itself says so with `birth: true`
  # (`Sanctum.Tenancy.Athanors`).
  defp seat(attrs, opts) do
    athanor_id = Map.get(attrs, :athanor_id)

    if not Keyword.get(opts, :birth, false) and frozen?(athanor_id) do
      {:error, :frozen_roster}
    else
      Arca.Members.seat(in_athanor(athanor_id), attrs)
    end
  end

  defp frozen?(athanor_id) when is_binary(athanor_id),
    do: match?({:ok, %{roster: "frozen"}}, Athanors.get(athanor_id))

  defp frozen?(_athanor_id), do: false

  @doc """
  Idempotently ensure an active membership exists for `user_id`.

  Opts: `:scope` (required — the two scopes are different grants and neither
  is a default), `:athanor_id`, `:added_by`. Safe under concurrent first
  sign-ins — a unique-constraint conflict resolves to a re-read of the
  existing row.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, membership()} | {:error, term()}
  def ensure(user_id, opts) when is_binary(user_id) do
    scope = Keyword.fetch!(opts, :scope)
    athanor_id = Keyword.get(opts, :athanor_id)

    # Read-before-write: the membership almost always already exists (it is
    # minted once), so probing first avoids a failed INSERT — and the noisy
    # `QUERY ERROR ... memberships` log line — on every later sign-in. A
    # concurrent first-login can still race past the probe; the INSERT's
    # conflict then resolves to a re-read.
    case find(user_id, scope, athanor_id) do
      {:ok, membership} ->
        {:ok, membership}

      _ ->
        case create(%{
               user_id: user_id,
               scope: scope,
               athanor_id: athanor_id,
               added_by: Keyword.get(opts, :added_by)
             }) do
          {:ok, membership} -> {:ok, membership}
          # Lost the race: re-read the existing assignment.
          {:error, :conflict} -> find(user_id, scope, athanor_id)
          other -> other
        end
    end
  end

  @doc "Ensure the platform-admin row for `user_id`."
  @spec ensure_platform(String.t()) :: {:ok, membership()} | {:error, term()}
  def ensure_platform(user_id), do: ensure(user_id, scope: "platform")

  @doc """
  The platform grant an admitted operator sign-in asks for, checked
  against exactly the identity facts that sign-in asserted
  (`t:Arca.Members.identity/0`): the person's row is locked and must
  still carry them, and the email must not be explicitly unverified, or
  nothing is written and the answer is `{:error, :stale_identity}`.
  `{:ok, :granted}` when this call wrote the row, `{:ok, :held}` when it
  was already there.
  """
  @spec grant_platform(String.t(), Arca.Members.identity()) ::
          {:ok, :granted | :held} | {:error, term()}
  def grant_platform(user_id, %{email: _, email_verified: _} = expected_identity)
      when is_binary(user_id) do
    case Arca.Members.ensure_platform(server(), user_id, expected_identity: expected_identity) do
      {:ok, %{granted: true}} -> {:ok, :granted}
      {:ok, %{granted: false}} -> {:ok, :held}
      {:error, _reason} = refusal -> refusal
    end
  end

  @doc "Every platform-admin row — the server's operators, as the rows say."
  @spec list_platform() :: {:ok, [membership()]} | {:error, :database_error}
  def list_platform, do: Arca.Members.list_platform(server())

  @doc """
  Remove the platform-admin row for `user_id`, if any. A failure is
  reported, not swallowed: the caller is taking a capability away, and
  answering `:ok` while the row survives would leave the operator bit on.

  When a row was actually removed, the person's sessions go with it in
  the same transaction (`Arca.Members.revoke_platform/3`): the capability
  rides on established contexts — memoized per request, held for a
  LiveView socket's lifetime — and ending the sessions is what makes the
  revocation a next-request fact on every surface. Either both go or
  neither does, and only after the commit are the removed sessions'
  memos dropped and the revocation announced. A no-op revoke (no row)
  touches nothing, so the routine sign-in of a non-operator never logs
  anyone out.

  `expected_identity:` is an admitted sign-in's facts, checked as
  `grant_platform/2` checks them (`{:error, :stale_identity}`).
  """
  @spec revoke_platform(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_platform(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    case Arca.Members.revoke_platform(server(), user_id, Keyword.take(opts, [:expected_identity])) do
      {:ok, %{removed: 0}} ->
        :ok

      {:ok, %{session_hashes: hashes}} ->
        Sanctum.Session.announce_revoked(user_id, hashes)

      {:error, _reason} = refusal ->
        refusal
    end
  end

  @spec get(String.t()) :: {:ok, membership()} | {:error, :not_found | :database_error}
  def get(id), do: Arca.Members.get(server(), id)

  @doc "Is `user_id` an active member of the athanor?"
  @spec member?(String.t() | nil, String.t()) :: boolean()
  def member?(user_id, athanor_id), do: match?({:ok, _seat}, active_seat(user_id, athanor_id))

  @doc """
  The active membership row seating `user_id` in the athanor: `{:ok, row}`,
  `:none`, or `{:error, reason}` when the store cannot answer. Its id is
  what a focus on that athanor is bound to
  (`t:Sanctum.Context.credential_binding/0`).
  """
  @spec active_seat(String.t() | nil, String.t() | nil) ::
          {:ok, membership()} | :none | {:error, term()}
  def active_seat(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    case find(user_id, "athanor", athanor_id) do
      {:ok, %{status: "active"} = row} -> {:ok, row}
      {:ok, %{}} -> :none
      {:error, :not_found} -> :none
      {:error, _} = err -> err
    end
  end

  def active_seat(_user_id, _athanor_id), do: :none

  @doc "The person's platform row, as `active_seat/2` answers: `{:ok, row}`, `:none` or `{:error, reason}`."
  @spec platform_seat(String.t() | nil) :: {:ok, membership()} | :none | {:error, term()}
  def platform_seat(user_id) when is_binary(user_id) do
    case find(user_id, "platform", nil) do
      {:ok, %{status: "active"} = row} -> {:ok, row}
      {:ok, %{}} -> :none
      {:error, :not_found} -> :none
      {:error, _} = err -> err
    end
  end

  def platform_seat(_user_id), do: :none

  @doc """
  Add someone to an athanor: a person already on this server (`user_id:`)
  becomes an active member; an `email:` becomes an active member when
  exactly one identity with that verified email is known, else an `invited`
  row — and, when the door would not admit that address, a pending request
  for the platform admin. Answers uniformly for a stranger's address and a
  known one so it cannot be used to learn who is on the server; the two
  addresses it cannot seat — one that two identities here sign in with
  (`:ambiguous_email`: add by user id), and one a known person's provider
  positively refuses (`:email_unverified`: a permanent invite would be the
  alternative) — are refused with the reason. An `identifier:` (`per_…`)
  becomes an active member when a person here holds that identifier, else
  an `invited` row the person claims on their first admitted `cyfr`
  sign-in — and, when the door would not admit that identifier, a pending
  request for the platform admin; whether this home can resolve the
  identifier at its directory is not asked, since only the person's own
  sign-in carries their genesis. A malformed one is `:invalid_identifier`.
  The per-group member cap applies. A person's own athanor has exactly one
  member — its owner — on every path, not only in the UI.
  """
  @spec add(
          Sanctum.Tenancy.Athanors.athanor(),
          [user_id: String.t()] | [email: String.t()] | [identifier: String.t()],
          String.t()
        ) ::
          {:ok, :added | :invited} | {:error, term()}
  def add(athanor, target, added_by)

  def add(%{kind: "person"}, _target, _added_by), do: {:error, :person_athanor}

  # A frozen athanor took its members at birth and never gains another —
  # that is what makes a DM a DM. Guarded here, beside the person clause,
  # so BOTH the `user_id:` and `email:` arms are covered: a rule enforced
  # on one arm is a rule an invitation walks around. Growing the room is a
  # different act — mint an open athanor with the three of them, and the
  # pair stays as it was.
  def add(%{roster: "frozen"}, _target, _added_by), do: {:error, :frozen_roster}

  def add(%{id: athanor_id, status: "active"} = athanor, [user_id: user_id], added_by)
      when is_binary(user_id) do
    opts = [scope: "athanor", athanor_id: athanor_id, added_by: added_by]

    # A membership names a person — by their own id, or by an IdP identity
    # key that names them. An id nobody has signed in with, or one the door
    # has since denied, is refused. (Unlike the email arm, a verified email
    # is not required — a person admitted by a `user_id` door entry may
    # have none.)
    with {:ok, %{status: "active", id: user_id}} <- find_person(user_id),
         :ok <- member_cap(athanor_id),
         {:ok, _} <- ensure(user_id, opts) do
      broadcast_change(user_id, athanor.id, :joined)
      Sanctum.Notify.member_changed(athanor.id)
      {:ok, :added}
    else
      {:ok, %{}} -> {:error, :unknown_user}
      {:error, :not_found} -> {:error, :unknown_user}
      other -> other
    end
  end

  def add(%{id: athanor_id, status: "active"} = athanor, [email: email], added_by)
      when is_binary(email) do
    email = String.downcase(String.trim(email))

    with true <- String.contains?(email, "@") or {:error, :invalid_email},
         :ok <- member_cap(athanor_id) do
      known = Users.list_by_email(email)

      case Enum.filter(known, &known_and_active?/1) do
        [%{id: user_id}] ->
          add(athanor, [user_id: user_id], added_by)

        [_, _ | _] ->
          {:error, :ambiguous_email}

        [] ->
          if Enum.any?(known, &(&1.status == "active" and &1.email_verified == false)) do
            {:error, :email_unverified}
          else
            with {:ok, _} <- invite(athanor_id, email, added_by) do
              unless Door.email_admitted?(email) do
                # Only a request that was actually written puts someone at the
                # operator's door; an address that already has an entry (a
                # standing deny, say) has its answer already.
                case Door.Store.request("email", email, added_by) do
                  {:ok, :created, _} -> Sanctum.Notify.allowlist_request(email)
                  _ -> :ok
                end
              end

              Sanctum.Notify.member_changed(athanor.id)
              {:ok, :invited}
            end
          end
      end
    end
  end

  def add(%{id: athanor_id, status: "active"} = athanor, [identifier: identifier], added_by)
      when is_binary(identifier) do
    with true <-
           Prima.Identity.Encoding.identifier?(identifier) or {:error, :invalid_identifier},
         :ok <- member_cap(athanor_id) do
      # Uniform with the email arm: a stranger's identifier and a denied
      # person's are invited alike, and the caller learns only that the
      # row is in place.
      case Users.get_by_identifier(identifier) do
        {:ok, %{status: "active", id: user_id}} -> add(athanor, [user_id: user_id], added_by)
        {:ok, %{}} -> invite_identifier(athanor, identifier, added_by)
        {:error, :not_found} -> invite_identifier(athanor, identifier, added_by)
        {:error, _unanswered} -> {:error, :database_error}
      end
    end
  end

  def add(_athanor, _target, _added_by), do: {:error, :athanor_archived}

  # The invitation an identifier holds, and the operator's request when
  # the door would not admit it: only a request actually written puts
  # someone at the door, as for an address.
  defp invite_identifier(%{id: athanor_id}, identifier, added_by) do
    with {:ok, _} <- invited_identifier(athanor_id, identifier, added_by) do
      unless Door.identifier_admitted?(identifier) do
        case Door.Store.request("identifier", identifier, added_by) do
          {:ok, :created, _} -> Sanctum.Notify.allowlist_request(identifier)
          _ -> :ok
        end
      end

      Sanctum.Notify.member_changed(athanor_id)
      {:ok, :invited}
    end
  end

  defp invited_identifier(athanor_id, identifier, added_by) do
    case Arca.Members.find_invited_identifier(in_athanor(athanor_id), identifier) do
      {:ok, row} ->
        {:ok, row}

      {:error, :not_found} ->
        create(%{
          person_identifier: identifier,
          scope: "athanor",
          status: "invited",
          athanor_id: athanor_id,
          added_by: added_by
        })

      {:error, _} = err ->
        err
    end
  end

  # Every seat the athanor has handed out — active members and pending
  # invitations — is what the cap bounds; an invitation is a seat someone
  # will take.
  defp member_cap(athanor_id) do
    Caps.check_counted(:max_members_per_group, fn ->
      Arca.Members.count_seats(in_athanor(athanor_id))
    end)
  end

  # Seat by email only when the provider verifies it. Unknown verification
  # creates an invitation pending a verified sign-in; explicit false refuses.
  # Use user_id for providers that omit email verification.
  defp known_and_active?(%{} = user),
    do: user.email_verified == true and user.status == "active"

  defp find_person(id) do
    if Sanctum.Auth.Identity.key?(id), do: Users.get_by_identity(id), else: Users.get(id)
  end

  defp invite(athanor_id, email, added_by) do
    case Arca.Members.find_invited(in_athanor(athanor_id), email) do
      {:ok, row} ->
        {:ok, row}

      {:error, :not_found} ->
        create(%{
          email: email,
          scope: "athanor",
          status: "invited",
          athanor_id: athanor_id,
          added_by: added_by
        })

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Turn every `invited` row for the person's email, and for the identifier
  of each `cyfr` identity they hold, into their active membership — an
  email only for an address the provider **proved**.

  An identifier invitation is claimed by the person whose `cyfr` identity
  names it as its subject (`Sanctum.Auth.Identity.cyfr_identifier/1`):
  the `cyfr` door wrote that identity only after verifying their
  assertion under the identifier's current head, so holding it is proof
  of the identifier, as a proved address is of an email.

  An invited row names an email and no person, so activating it is a grant
  keyed on the address alone: anyone who can get an issuer to assert
  `carol@acme.com` would inherit every seat held for Carol. `Sanctum.Door`
  already refuses an exact email allowlist entry on anything but `true`, and
  a group seat is the same kind of grant, so it takes the same answer. An
  issuer that never asserts `email_verified` seats nobody by email; the seat
  is not withdrawn, and a later sign-in that does prove the address claims it.

  Two set-based statements in one transaction, so two first sign-ins of the
  same identity cannot both claim a row: invitations for athanors where the
  person is already active are dropped, the rest are activated with the email
  consumed (the assignment index then admits no second row for the person and
  athanor). An invitation already activated, or already withdrawn, is not
  there to find and produces no second membership. Returns how many
  activated; the seats an email claimed are announced even when the
  identifier's claim that follows cannot be made.
  """
  @spec activate_invited(Sanctum.Tenancy.Users.user()) ::
          {:ok, non_neg_integer()} | {:error, :database_error | :not_owner}
  def activate_invited(%{id: user_id} = user) when is_binary(user_id) do
    with {:ok, by_email} <- claimed(user_id, activate_by_email(user)),
         {:ok, by_identifier} <- claimed(user_id, activate_by_identifier(user_id)) do
      {:ok, by_email + by_identifier}
    end
  end

  def activate_invited(_user), do: {:ok, 0}

  defp activate_by_email(%{email: email, email_verified: true, id: user_id})
       when is_binary(email),
       do: Arca.Members.activate_invited(server(), user_id, email, DateTime.utc_now())

  defp activate_by_email(_user), do: {:ok, []}

  defp activate_by_identifier(user_id) do
    case Arca.Users.identities(server(), user_id) do
      {:ok, identities} ->
        identities
        |> Enum.flat_map(&cyfr_identifiers/1)
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, claimed} ->
          case Arca.Members.activate_invited_identifier(
                 server(),
                 user_id,
                 identifier,
                 DateTime.utc_now()
               ) do
            {:ok, athanor_ids} -> {:cont, {:ok, claimed ++ athanor_ids}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      {:error, _unanswered} ->
        {:error, :database_error}
    end
  end

  defp cyfr_identifiers(%{key: key}) do
    case Sanctum.Auth.Identity.cyfr_identifier(key) do
      {:ok, identifier} -> [identifier]
      :error -> []
    end
  end

  defp claimed(user_id, {:ok, athanor_ids}) do
    for athanor_id <- athanor_ids do
      broadcast_change(user_id, athanor_id, :joined)
      Sanctum.Notify.member_changed(athanor_id)
    end

    {:ok, length(athanor_ids)}
  end

  defp claimed(_user_id, {:error, _} = err), do: err

  @doc """
  Drop every pending invitation for an address — what a deny at the door
  owes the groups that were holding a seat for it. Invited rows name an
  email and no person, so the deny's sweep by `user_id` cannot see them;
  without this a seat survives the eject and the next allow would seat
  someone the operator threw out. Returns how many were withdrawn.
  """
  @spec withdraw_invites_for_email(String.t() | nil) :: non_neg_integer()
  def withdraw_invites_for_email(email) when is_binary(email) and email != "" do
    email = String.downcase(String.trim(email))

    # Deliberate default: the deny's best-effort sweep — a withdrawal the
    # store missed leaves invited rows, not seats: activation re-checks the
    # door, which now denies the address.
    case Arca.Members.withdraw_invites_for_email(server(), email) do
      {:ok, athanor_ids} ->
        for athanor_id <- athanor_ids, is_binary(athanor_id) do
          Sanctum.Notify.member_changed(athanor_id)
        end

        length(athanor_ids)

      {:error, _} ->
        0
    end
  end

  def withdraw_invites_for_email(_), do: 0

  @doc """
  Drop every pending invitation for a person identifier — what a deny of
  that identifier at the door owes the groups holding a seat for it, as
  `withdraw_invites_for_email/1` does for an address. Returns how many
  were withdrawn.
  """
  @spec withdraw_invites_for_identifier(String.t() | nil) :: non_neg_integer()
  def withdraw_invites_for_identifier(identifier)
      when is_binary(identifier) and identifier != "" do
    # The deny's best-effort sweep, as for an address: a withdrawal the
    # store missed leaves invited rows, not seats, and only an admitted
    # `cyfr` sign-in claims one, which the door now refuses.
    case Arca.Members.withdraw_invites_for_identifier(server(), identifier) do
      {:ok, athanor_ids} ->
        for athanor_id <- athanor_ids, is_binary(athanor_id) do
          Sanctum.Notify.member_changed(athanor_id)
        end

        length(athanor_ids)

      {:error, _} ->
        0
    end
  end

  def withdraw_invites_for_identifier(_), do: 0

  @doc """
  Delete one membership row as it stands: how an invitation is withdrawn.
  It retires nothing a seat held; a person leaves an athanor through
  `remove_member/2`.
  """
  @spec remove(membership()) :: {:ok, membership()} | {:error, term()}
  def remove(%{id: id}) when is_binary(id), do: Arca.Members.delete(server(), id)

  @doc """
  Remove a person from an athanor (or a pending invite by email or by
  identifier). The last active member leaving a group archives it.
  The owner of a person's athanor is that athanor's one member and is never
  removed — deny at the door is the only way out of one's own furnace.

  A person leaves through `Arca.SecurityTransitions.leave_athanor/3`: their
  seat, their thread follows there, their sessions bound to the athanor
  and the frame credentials, paired clients, device certificates and
  pending pairing invitations they hold there go in one transaction, or
  nothing does; a remote person it leaves with no membership here is
  retired here with it. A follow left behind would resume the moment they
  are re-added, so a returning member starts unfollowed like a new one.

  `identifier:` withdraws the invitation that identifier holds here, or,
  when it holds none, removes the person here who holds the identifier.
  """
  @spec remove_member(
          Sanctum.Tenancy.Athanors.athanor(),
          [user_id: String.t()] | [email: String.t()] | [identifier: String.t()]
        ) ::
          :ok | {:error, term()}
  def remove_member(%{kind: "person"}, _target), do: {:error, :person_athanor}

  def remove_member(%{id: athanor_id} = athanor, user_id: user_id) when is_binary(user_id) do
    # A frozen athanor is archived BEFORE the leave, for the reason
    # `end_if_frozen/1` gives; a leave that then fails is retried straight
    # through, the archive being idempotent.
    with {:ok, _row} <- find(user_id, "athanor", athanor_id),
         :ok <- end_if_frozen(athanor),
         {:ok, change} <-
           Arca.SecurityTransitions.leave_athanor(in_athanor(athanor_id), user_id,
             verify: &leavable/1
           ) do
      announce_left(user_id, athanor_id, change)
      archive_when_empty(athanor)
      :ok
    else
      {:error, :not_member} -> {:error, :not_found}
      other -> other
    end
  end

  def remove_member(%{id: athanor_id}, email: email) when is_binary(email) do
    with {:ok, row} <- Arca.Members.find_invited(in_athanor(athanor_id), String.downcase(email)),
         {:ok, _} <- remove(row) do
      Sanctum.Notify.member_changed(athanor_id)
      :ok
    end
  end

  def remove_member(%{id: athanor_id} = athanor, identifier: identifier)
      when is_binary(identifier) do
    case Arca.Members.find_invited_identifier(in_athanor(athanor_id), identifier) do
      {:ok, row} ->
        with {:ok, _} <- remove(row) do
          Sanctum.Notify.member_changed(athanor_id)
          :ok
        end

      {:error, :not_found} ->
        case Users.get_by_identifier(identifier) do
          {:ok, %{id: user_id}} -> remove_member(athanor, user_id: user_id)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Decided again with the athanor locked: a person's own athanor keeps
  # its owner.
  defp leavable(%{athanor: %{kind: "person"}}), do: {:error, :person_athanor}
  defp leavable(_rows), do: :ok

  # After the commit, from what it returned: the sessions it ended let go,
  # the person's other contexts drop their memo so their next request
  # revalidates, and the person and the roster are told.
  defp announce_left(user_id, athanor_id, change) do
    if change.revoked_session_hashes != [],
      do: Sanctum.Session.announce_revoked(user_id, change.revoked_session_hashes)

    Sanctum.Session.invalidate_memo_for_user(user_id)
    broadcast_change(user_id, athanor_id, :left)
    Sanctum.Notify.member_changed(athanor_id)
  end

  @doc """
  Announce the rows a committed denial removed, from the data it
  returned (`Arca.SecurityTransitions.deny_user/3`): the person hears
  they left every athanor they sat in, and every roster that lost a seat
  or an invitation is told.
  """
  @spec announce_removed(String.t(), map()) :: :ok
  def announce_removed(user_id, %{removed_memberships: removed, withdrawn_invitations: withdrawn}) do
    for %{athanor_id: athanor_id} <- removed, is_binary(athanor_id) do
      broadcast_change(user_id, athanor_id, :left)
    end

    (removed ++ withdrawn)
    |> Enum.map(& &1.athanor_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(&Sanctum.Notify.member_changed/1)
  end

  @doc """
  The members of an athanor — active and invited — as display rows, oldest
  first: `%{user_id, email, person_identifier, display_name, namespace,
  status, added_by, since}`.
  Paged with `limit:` (default and ceiling `Arca.Members.max_page/0`) and
  `offset:`; the member cap bounds the roster, the page bounds one read.
  """
  @spec list_by_athanor(String.t(), keyword()) :: {:ok, [map()]} | {:error, :database_error}
  def list_by_athanor(athanor_id, opts \\ []) when is_binary(athanor_id),
    do: Arca.Members.list(in_athanor(athanor_id), opts)

  @doc "Every row of a person: platform and athanor, active only. Uncapped."
  @spec list_by_user(String.t()) :: {:ok, [membership()]} | {:error, :database_error}
  def list_by_user(user_id), do: Arca.Members.list_active_for_user(server(), user_id)

  @doc """
  How many active members an athanor has. Strict like `Athanors.count/0`:
  a count that decides anything (auto-archive keys on zero) must refuse
  when the store cannot answer, never read as empty.
  """
  @spec count_by_athanor(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count_by_athanor(athanor_id), do: Arca.Members.count_active(in_athanor(athanor_id))

  @doc """
  Whether two people currently sit together in at least one ACTIVE athanor.

  The DM reachability rule: a pair can be minted only with someone already
  in a room with you. This is what keeps `athanor.pair` from being a
  directory — a user id you cannot see on any members list is a user id you
  cannot pair with, and probing one answers exactly what probing an unknown
  one does. No athanor is shared server-wide, so two people who belong to no
  group together cannot reach each other at all; operators are no exception
  and add each other to a group to talk.

  Active memberships in active athanors only: an invitation is not a seat,
  and an archived room is not a room. Fails toward "no", like `solo?/1` —
  an unanswerable read must not open a door.
  """
  @spec shared_athanor?(String.t(), String.t()) :: boolean()
  def shared_athanor?(user_a, user_b) when is_binary(user_a) and is_binary(user_b),
    do: match?({:ok, true}, Arca.Members.shared_athanor?(server(), user_a, user_b))

  def shared_athanor?(_, _), do: false

  @doc """
  Whether exactly one human is in this athanor.

  Returns whether the athanor has a single human member. Used for implicit
  agent addressing and speaker prefixes in turn tasks.

  Active memberships only: an `invited` row is a seat nobody is sitting in.
  Fails toward "several", so an unanswerable count costs an `@` rather than
  starting turns nobody addressed.
  """
  @spec solo?(String.t() | nil) :: boolean()
  def solo?(athanor_id) when is_binary(athanor_id),
    do: match?({:ok, 1}, count_by_athanor(athanor_id))

  def solo?(_), do: false

  @doc false
  def broadcast_change(user_id, athanor_id, change) when is_binary(user_id),
    do: Sanctum.Telemetry.membership_changed(user_id, athanor_id, change)

  def broadcast_change(_user_id, _athanor_id, _change), do: :ok

  # ---- internal --------------------------------------------------------------

  # A person's seats span athanors and a platform row names none, so the
  # fabric reads as the server.
  defp server, do: Prima.Actor.system()

  # The server narrowed to one athanor — the actor a read or write of that
  # athanor's own roster runs as. A nil athanor is refused by the facade
  # before any query.
  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  # A frozen athanor ends when ANYONE leaves, not when the last person does.
  # Waiting for empty would leave a one-member pair standing: a second You
  # that the person who stayed can still open, whose `pair_key` still
  # hashes both ids — so the two could never be paired again, because the
  # husk holds the key. Ending it releases the key; clicking the name later
  # mints a new tape rather than reopening this one.
  #
  # Archived BEFORE the leave, and the result is the leave's to report:
  # with the row already gone, a failed archive could never be retried
  # (`find/3` answers :not_found), and the husk's `pair_key` would block
  # those two pairing forever. `Athanors.archive/2` re-reads and is
  # idempotent on an archived row, so both failure orders self-heal — a
  # failed archive leaves everything as it was, and a failed leave after
  # it retries straight through.
  defp end_if_frozen(%{kind: "group", roster: "frozen"} = athanor) do
    with {:ok, _} <- Athanors.archive(athanor, reason: :empty), do: :ok
  end

  defp end_if_frozen(_athanor), do: :ok

  defp archive_when_empty(%{id: id, kind: "group"} = athanor) do
    # Only a verified zero archives. A store failure aborts: archiving is
    # terminal for a group (an :empty archive releases the slug and cannot
    # be undone), so a transient read error must never read as "empty".
    with {:ok, 0} <- count_by_athanor(id),
         {:ok, current} <- Athanors.get(id) do
      Athanors.archive(current, reason: :empty)
    else
      _ -> {:ok, athanor}
    end

    :ok
  end

  defp archive_when_empty(_), do: :ok

  defp find(user_id, "platform", _athanor_id),
    do: Arca.Members.find_platform(server(), user_id)

  defp find(user_id, _scope, athanor_id),
    do: Arca.Members.find(in_athanor(athanor_id), user_id)
end
