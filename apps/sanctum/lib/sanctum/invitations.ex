# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Invitations do
  @moduledoc """
  Invitations to become a person at this CYFR (`Arca.Invitations`): who
  may issue and revoke one, what the invitation page shows of one, and
  the checks its redemption makes in the invitation admission's
  transaction (`Sanctum.Newcomer`, `{:invitation, code}`).

  ## Issuing

  The platform administrator issues one naming no athanor. Anyone,
  the administrator included, issues one naming a group athanor they hold
  an active seat in: the invitation seats its newcomer there, which is the
  group's act, and the administrator's capability is over the instance,
  never a seat. A person's own athanor, a frozen roster and an archived
  athanor take none, and to a caller with no seat an athanor answers as a
  missing one does. An invitation may offer its newcomer a name, which
  their invitation page fills in; it reserves nothing, and the newcomer
  may take another. The code is 32 random bytes, given to the issuer once
  as base64url without padding; only the lowercase hex SHA-256 of the
  bytes is stored. It expires seven days after it is issued.

  ## Revoking and listing

  The issuer, or the platform administrator, revokes an invitation that
  is still open. The administrator lists every invitation, anyone else the
  ones they issued; to anyone else another's invitation answers as a
  missing one does. Each shows its state (`pending`, `redeemed`, `revoked`
  or `expired`), its expiry, and the athanor it names when it names one,
  whose name only a viewer seated there reads.

  ## Redeeming

  `redeemable/1` is the check: the code's invitation exists and is
  unexpired, unredeemed and unrevoked; its issuer is still an active
  person here (a door deny marks them denied) at the standing they issued
  it under, their `security_generation` still the one the invitation
  recorded (`Arca.Invitations`), so a denial, an allow or a declared
  restore since retires it and restored authority never redeems; one
  naming an athanor needs the issuer still seated there and the athanor
  still an active group with an open roster, and one naming none needs
  the issuer still the platform administrator. Any failure is
  `:invitation_invalid`, one answer for all, so a code reveals nothing of
  why. `lookup/1` makes exactly that check for the invitation page, and
  reads only. `redeem/2` marks the invitation redeemed by the person, by
  one conditional write that lands only while the row is open and
  unexpired, inside the admission's transaction after the check. The seat
  an invitation naming a group makes reads its issuer's standing and seat
  there once more, under the group's lock (`issuer_seated/1`).

  ## Redeeming as an existing identity

  A person whose keys another CYFR holds redeems an invitation through
  the CYFR sign-in, which carries the code's hash (`code_hash/1`) in this
  CYFR's own session, never the code. `redeemable_hash/1` is
  `redeemable/1`'s check from the hash. `redeem_for/2` redeems it for a
  person this CYFR already knows, in a transaction of its own, and
  `redeem_hash/2` for one it does not, in the remote admission's
  (`Sanctum.Newcomer`). After the conditional write both write, in that
  transaction, the seat the invitation names, under the group's lock,
  and the identifier's allow (`Sanctum.Door.Store.allow_unless_denied/4`),
  the row `door.allow`
  writes, added by the issuer, noting the invitation, labelled with the
  person's name here when they have one. A deny of the identifier, even
  one committed a moment before, refuses the allow, and a deny of the
  person or the identifier read again before the commit refuses it too:
  either rolls the redemption back with the invitation unspent and no
  seat, and the person is refused `{:door, :denied}`. Later sign-ins are
  admitted by that allow, which any later deny outranks.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @lifetime_ms 7 * 24 * 60 * 60 * 1000
  @code_bytes 32

  @typedoc "An invitation as its issuer or the administrator sees it."
  @type view :: %{
          required(:id) => String.t(),
          required(:state) => String.t(),
          required(:issued_by) => String.t(),
          required(:expires_at) => DateTime.t(),
          optional(:athanor_id) => String.t(),
          optional(:athanor_name) => String.t()
        }

  @typedoc """
  What the invitation page shows: who invited, to which athanor, until
  when, and the name it offers.
  """
  @type shown :: %{
          required(:inviter) => String.t(),
          required(:expires_at) => DateTime.t(),
          optional(:athanor) => String.t(),
          optional(:name) => String.t()
        }

  @doc """
  Issue an invitation naming the group athanor `athanor_id`, or none
  (`nil`), offering its newcomer `name`, or none (`nil`), a name by
  `Sanctum.Newcomer.name/1`. Answers the invitation and its code, which is
  given once and never stored.
  """
  @spec create(Context.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{invitation: view(), code: String.t()}} | {:error, term()}
  def create(%Context{user_id: user_id} = ctx, athanor_id, name \\ nil)
      when is_binary(user_id) do
    with :ok <- offered(name),
         {:ok, actor} <- issuable(ctx, athanor_id) do
      bytes = :crypto.strong_rand_bytes(@code_bytes)

      attrs = %{
        code_hash: Prima.Digest.sha256_hex(bytes),
        issued_by: user_id,
        lifetime_ms: @lifetime_ms,
        name: name
      }

      case Arca.Invitations.insert(actor, attrs) do
        {:ok, row} -> {:ok, %{invitation: view(row, seats(user_id)), code: encode(bytes)}}
        {:error, reason} -> {:error, unavailable(reason)}
      end
    end
  end

  @doc "Revoke the invitation `id`, as its issuer or the platform administrator."
  @spec revoke(Context.t(), String.t()) :: {:ok, view()} | {:error, term()}
  def revoke(%Context{user_id: user_id} = ctx, id) when is_binary(user_id) and is_binary(id) do
    with {:ok, _row} <- visible(ctx, id) do
      case Arca.Invitations.revoke(server(), id) do
        {:ok, row} ->
          {:ok, view(row, seats(user_id))}

        {:error, :redeemed} ->
          {:error,
           {:invalid_argument, "That invitation was used already, so it cannot be revoked"}}

        {:error, :not_found} ->
          {:error, {:not_found, "Invitation", id}}

        {:error, reason} ->
          {:error, unavailable(reason)}
      end
    end
  end

  @doc """
  The invitations the caller sees, newest first: every one for the
  platform administrator, the ones they issued for anyone else.
  """
  @spec list(Context.t()) :: {:ok, [view()]} | {:error, term()}
  def list(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    opts = if admin?(ctx), do: [], else: [issued_by: user_id]

    case Arca.Invitations.list(server(), opts) do
      {:ok, rows} ->
        seats = seats(user_id)
        {:ok, Enum.map(rows, &view(&1, seats))}

      {:error, reason} ->
        {:error, unavailable(reason)}
    end
  end

  @doc """
  What the invitation page shows of the invitation `code` opens: who
  invited (their display name, else their handle, else "a member of this
  CYFR", never an address), the athanor's name when it names one, its
  expiry, and the name it offers when it offers one; or
  `:invitation_invalid` under exactly the check redemption makes
  (`redeemable/1`). Reads only.
  """
  @spec lookup(term()) :: {:ok, shown()} | {:error, :invitation_invalid | :unavailable}
  def lookup(code) do
    with {:ok, code_hash} <- code_hash(code),
         {:ok, %{row: row, issuer: issuer, athanor: athanor}} <- standing(code_hash) do
      shown = %{inviter: inviter(issuer), expires_at: row.expires_at}
      shown = if athanor, do: Map.put(shown, :athanor, athanor.name), else: shown
      {:ok, if(is_binary(row.name), do: Map.put(shown, :name, row.name), else: shown)}
    end
  end

  @doc """
  Whether the invitation `code` opens would admit a person now (the
  module doc): `:ok`, `{:error, :invitation_invalid}`, or
  `{:error, :unavailable}` when the store cannot answer. Reads only, so it
  runs as the invitation admission's `verify:`.
  """
  @spec redeemable(term()) :: :ok | {:error, :invitation_invalid | :unavailable}
  def redeemable(code) do
    with {:ok, code_hash} <- code_hash(code), do: redeemable_hash(code_hash)
  end

  @doc """
  `redeemable/1` from the code's hash (`code_hash/1`), making exactly its
  checks: `:ok`, `{:error, :invitation_invalid}`, or `{:error,
  :unavailable}`. A value that is no hash opens nothing. Reads only.
  """
  @spec redeemable_hash(term()) :: :ok | {:error, :invitation_invalid | :unavailable}
  def redeemable_hash(code_hash) do
    with :ok <- hash(code_hash), {:ok, _standing} <- standing(code_hash), do: :ok
  end

  @doc """
  The hash an invitation is stored under, of the code `code` as it was
  given (base64url without padding, of 32 bytes): the lowercase hex
  SHA-256 of its bytes. Anything else is `:invitation_invalid`, as an
  unknown code is.
  """
  @spec code_hash(term()) :: {:ok, String.t()} | {:error, :invitation_invalid}
  def code_hash(code) when is_binary(code) do
    case Base.url_decode64(code, padding: false) do
      {:ok, <<_::binary-size(@code_bytes)>> = bytes} -> {:ok, Prima.Digest.sha256_hex(bytes)}
      _malformed -> invalid()
    end
  end

  def code_hash(_code), do: invalid()

  @doc """
  Mark the invitation `code` opens redeemed by the person `user_id`, in
  the admission's transaction, after `redeemable/1` agreed: one
  conditional write, which lands only while the invitation is unredeemed,
  unrevoked and unexpired. Answers the redeemed invitation; one that
  another redemption or a revocation closed first is
  `:invitation_invalid`.
  """
  @spec redeem(term(), String.t()) ::
          {:ok, map()} | {:error, :invitation_invalid | :unavailable}
  def redeem(code, user_id) when is_binary(user_id) do
    with {:ok, code_hash} <- code_hash(code) do
      case Arca.Invitations.redeem(server(), code_hash, user_id) do
        {:ok, row} -> {:ok, row}
        {:error, :not_found} -> {:error, :invitation_invalid}
        {:error, reason} -> {:error, unavailable(reason)}
      end
    end
  end

  @doc """
  Redeem the invitation `code_hash` names for the person `user_id`, whom
  this CYFR already knows by their identifier (the module doc): after
  `redeemable_hash/1` agreed, in one transaction, the conditional write
  `redeem/2` makes, then the seat, the allow and the deny read once more
  (the module doc). Answers the redeemed
  invitation. One closed meanwhile, or by another redemption first, is
  `:invitation_invalid`; a deny is `{:door, :denied}`; either writes
  nothing.
  """
  @spec redeem_for(term(), String.t()) ::
          {:ok, map()} | {:error, :invitation_invalid | {:door, :denied} | :unavailable | term()}
  def redeem_for(code_hash, user_id) when is_binary(user_id) do
    with :ok <- redeemable_hash(code_hash),
         {:ok, person} <- known(user_id) do
      case Arca.Invitations.redeem_for(server(), code_hash, user_id,
             also: &seat_and_allow(&1, person)
           ) do
        {:ok, row} ->
          joined(row, user_id)
          {:ok, row}

        {:error, :not_found} ->
          invalid()

        {:error, reason} ->
          {:error, unavailable(reason)}
      end
    end
  end

  @typedoc "Who an existing identity's redemption admits: their id, identifier and name here."
  @type redeemer :: %{
          required(:user_id) => String.t(),
          required(:identifier) => String.t(),
          required(:label) => String.t() | nil
        }

  @doc """
  Redeem the invitation `code_hash` names for `person`, a remote person
  the admission is making, in the admission's transaction after
  `redeemable_hash/1` agreed (the module doc): the conditional write,
  then the seat, the allow and the deny read once more. Answers `:ok`;
  one closed meanwhile is `:invitation_invalid` and a deny `{:door,
  :denied}`, each rolling the admission back.
  """
  @spec redeem_hash(String.t(), redeemer()) :: :ok | {:error, term()}
  def redeem_hash(code_hash, %{user_id: user_id} = person) when is_binary(code_hash) do
    case Arca.Invitations.redeem(server(), code_hash, user_id) do
      {:ok, row} -> seat_and_allow(row, person)
      {:error, :not_found} -> invalid()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tell the group the invitation `code_hash` names of the person `user_id`
  it seated there, once the redemption committed. One naming no group, or
  one that cannot be read, tells no one.
  """
  @spec announce(String.t(), String.t()) :: :ok
  def announce(code_hash, user_id) when is_binary(code_hash) and is_binary(user_id) do
    case Arca.Invitations.by_code_hash(server(), code_hash) do
      {:ok, row} -> joined(row, user_id)
      {:error, _unread} -> :ok
    end
  end

  defp joined(%{athanor_id: athanor_id}, user_id) when is_binary(athanor_id) do
    Members.broadcast_change(user_id, athanor_id, :joined)
    Sanctum.Notify.member_changed(athanor_id)
    :ok
  end

  defp joined(_invitation, _user_id), do: :ok

  # What a redemption by an existing identity writes in its transaction,
  # after the invitation's conditional write (the module doc): the seat
  # the invitation names, when it names one, then the identifier's allow,
  # then the door's deny read once more.
  defp seat_and_allow(invitation, %{user_id: user_id, identifier: identifier} = person) do
    with :ok <- invited_seat(invitation, user_id),
         :ok <- allowed(invitation, person) do
      case Sanctum.Door.Store.denied(user_id, identifier) do
        {:ok, false} -> :ok
        {:ok, true} -> {:error, {:door, :denied}}
        {:error, :unavailable} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Whether the issuer of `invitation`, which names a group athanor, is
  still an active person at the standing they issued it under, seated
  there: asked again by the seat's `reserve:` under that athanor's lock
  (`Arca.Members.seat/3`), which a leave and a deny of the issuer take
  too, so the seat and a removal of the issuer decide in one order.
  `:invitation_invalid` otherwise.
  """
  @spec issuer_seated(map()) :: :ok | {:error, :invitation_invalid | :unavailable}
  def issuer_seated(%{issued_by: issuer, athanor_id: athanor_id} = invitation)
      when is_binary(athanor_id) do
    with {:ok, _user} <- issuer(invitation), do: seated(issuer, athanor_id)
  end

  @doc """
  The group athanor the redeemed invitation `code` opened seats its
  person in, read after the admission committed: `{:ok, athanor_id}`, or
  `:none` when it names none or cannot be read.
  """
  @spec seat(term()) :: {:ok, String.t()} | :none
  def seat(code) do
    with {:ok, code_hash} <- code_hash(code),
         {:ok, %{athanor_id: athanor_id}} when is_binary(athanor_id) <-
           Arca.Invitations.by_code_hash(server(), code_hash) do
      {:ok, athanor_id}
    else
      _none -> :none
    end
  end

  # ---- issuing ---------------------------------------------------------------

  defp offered(nil), do: :ok
  defp offered(name), do: Sanctum.Newcomer.name(name)

  # The actor the invitation is written under: the platform scope's for
  # one naming no athanor, the group's for one naming it.
  defp issuable(ctx, nil) do
    if admin?(ctx), do: {:ok, server()}, else: {:error, :platform_admin_required}
  end

  defp issuable(%Context{user_id: user_id}, athanor_id) when is_binary(athanor_id) do
    with {:ok, athanor} <- seated_in(user_id, athanor_id) do
      cond do
        athanor.kind != "group" ->
          {:error,
           {:invalid_argument,
            "A person's own athanor has one member, its owner; invite people to a group"}}

        athanor.roster == "frozen" ->
          {:error,
           {:invalid_argument,
            "A direct thread's two members were set when it opened; invite people to a group"}}

        athanor.status != "active" ->
          {:error, {:invalid_argument, "That athanor is archived"}}

        true ->
          {:ok, Prima.Actor.in_athanor(athanor.id)}
      end
    end
  end

  defp issuable(_ctx, _athanor_id),
    do: {:error, {:invalid_argument, "athanor_id names an athanor by its id"}}

  # The athanor, read only for a caller seated in it: anyone else is told
  # what a missing athanor tells them.
  defp seated_in(user_id, athanor_id) do
    missing = {:error, {:not_found, "Athanor", athanor_id}}

    with {:ok, athanor} <- Athanors.get(athanor_id),
         {:ok, _seat} <- Members.active_seat(user_id, athanor_id) do
      {:ok, athanor}
    else
      {:error, :not_found} -> missing
      :none -> missing
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  # ---- revoking and listing --------------------------------------------------

  # The invitation, for its issuer or the administrator; to anyone else it
  # answers as a missing one does.
  defp visible(%Context{user_id: user_id} = ctx, id) do
    case Arca.Invitations.get(server(), id) do
      {:ok, %{issued_by: ^user_id} = row} ->
        {:ok, row}

      {:ok, row} ->
        if admin?(ctx), do: {:ok, row}, else: {:error, {:not_found, "Invitation", id}}

      {:error, :not_found} ->
        {:error, {:not_found, "Invitation", id}}

      {:error, reason} ->
        {:error, unavailable(reason)}
    end
  end

  # The athanors the viewer holds an active seat in, whose names their
  # invitations may show. An unanswered read shows none.
  defp seats(user_id) do
    case Members.list_by_user(user_id) do
      {:ok, rows} -> for %{athanor_id: id} <- rows, is_binary(id), into: MapSet.new(), do: id
      {:error, _unanswered} -> MapSet.new()
    end
  end

  defp view(row, seats) do
    %{
      id: row.id,
      state: state(row, DateTime.utc_now()),
      issued_by: row.issued_by,
      expires_at: row.expires_at
    }
    |> named(row.athanor_id, seats)
  end

  defp named(view, nil, _seats), do: view

  defp named(view, athanor_id, seats) do
    view = Map.put(view, :athanor_id, athanor_id)

    with true <- MapSet.member?(seats, athanor_id),
         {:ok, %{name: name}} when is_binary(name) <- Athanors.get(athanor_id) do
      Map.put(view, :athanor_name, name)
    else
      _unseated -> view
    end
  end

  defp state(%{redeemed_at: %DateTime{}}, _now), do: "redeemed"
  defp state(%{revoked_at: %DateTime{}}, _now), do: "revoked"

  defp state(%{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: "pending", else: "expired"
  end

  # ---- redeeming -------------------------------------------------------------

  # The invitation, its issuer and the athanor it names, when every check
  # of the module doc holds.
  defp standing(code_hash) do
    with {:ok, row} <- invitation(code_hash),
         :ok <- open(row),
         {:ok, issuer} <- issuer(row),
         {:ok, athanor} <- named_place(row) do
      {:ok, %{row: row, issuer: issuer, athanor: athanor}}
    end
  end

  # A hash `code_hash/1` answers: 64 lowercase hex digits.
  defp hash(value) when is_binary(value) and byte_size(value) == 64 do
    if value =~ ~r/\A[0-9a-f]{64}\z/, do: :ok, else: invalid()
  end

  defp hash(_value), do: invalid()

  # The person a redemption admits, as this CYFR knows them: their
  # identifier, and their name here for the allow's label.
  defp known(user_id) do
    with {:ok, %{identifier: identifier}} when is_binary(identifier) <-
           Arca.PersonIdentities.get(server(), user_id),
         {:ok, user} <- Users.get(user_id) do
      label = if is_binary(user[:namespace]) and user[:namespace] != "", do: user.namespace
      {:ok, %{user_id: user_id, identifier: identifier, label: label}}
    else
      {:ok, _no_identifier} -> invalid()
      {:error, :not_found} -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  # The seat a group invitation names, under the group's lock, its issuer
  # still seated there and the group's member cap counted, as the
  # invitation admission's is; a person seated there already keeps the
  # seat they hold.
  defp invited_seat(%{athanor_id: nil}, _user_id), do: :ok

  defp invited_seat(%{athanor_id: athanor_id, issued_by: issuer} = invitation, user_id) do
    case Members.ensure(user_id,
           scope: "athanor",
           athanor_id: athanor_id,
           added_by: issuer,
           reserve: fn ->
             with :ok <- issuer_seated(invitation), do: Members.member_cap(athanor_id)
           end
         ) do
      {:ok, _seat} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed(%{id: id, issued_by: issuer}, %{identifier: identifier, label: label}) do
    case Sanctum.Door.Store.allow_unless_denied("identifier", identifier, issuer,
           note: "invitation " <> id,
           label: label
         ) do
      {:ok, _entry} -> :ok
      {:error, :denied} -> {:error, {:door, :denied}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invitation(code_hash) do
    case Arca.Invitations.by_code_hash(server(), code_hash) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  defp open(row), do: if(state(row, DateTime.utc_now()) == "pending", do: :ok, else: invalid())

  # The issuer, still an active person here at the generation the
  # invitation recorded: any change of their standing since raised it.
  defp issuer(%{issued_by: user_id, issuer_generation: generation}) do
    case Users.get(user_id) do
      {:ok, %{status: "active", security_generation: ^generation} = user} -> {:ok, user}
      {:ok, _moved} -> invalid()
      {:error, :not_found} -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  # One naming no athanor needs its issuer still the administrator; one
  # naming an athanor needs them still seated there, and the athanor still
  # an active group with an open roster.
  defp named_place(%{athanor_id: nil, issued_by: issuer}) do
    case Members.platform_seat(issuer) do
      {:ok, _seat} -> {:ok, nil}
      :none -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  defp named_place(%{athanor_id: athanor_id, issued_by: issuer}) do
    with {:ok, athanor} <- place(athanor_id),
         :ok <- seated(issuer, athanor_id) do
      {:ok, athanor}
    end
  end

  defp place(athanor_id) do
    case Athanors.get(athanor_id) do
      {:ok, %{kind: "group", status: "active", roster: "open"} = athanor} -> {:ok, athanor}
      {:ok, _closed} -> invalid()
      {:error, :not_found} -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  defp seated(user_id, athanor_id) do
    case Members.active_seat(user_id, athanor_id) do
      {:ok, _seat} -> :ok
      :none -> invalid()
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  # A name a person reads: never an address.
  defp inviter(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp inviter(%{namespace: handle}) when is_binary(handle) and handle != "", do: "@" <> handle
  defp inviter(_issuer), do: "a member of this CYFR"

  # ---- shared ----------------------------------------------------------------

  defp admin?(%Context{platform_admin: admin}), do: admin == true

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  defp invalid, do: {:error, :invitation_invalid}

  defp unavailable(:database_error), do: :unavailable
  defp unavailable(reason), do: reason

  defp server, do: Prima.Actor.system()
end
