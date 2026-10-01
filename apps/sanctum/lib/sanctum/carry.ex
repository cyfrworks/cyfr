# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Carry do
  @moduledoc """
  The sign-in carry at the person's signing home (`ARCHITECTURE.md` §9.2):
  a bounded pending action naming one destination, its signed envelope,
  and the navigation outcome the destination returns, recorded once. It
  writes no saved-home list and grants no membership.

  ## Beginning

  `begin/3` (`person.carry_begin`) is the person's explicit start, under
  their session, for exactly one destination home other than this one and
  the one operation `join`. The person must be enrolled here (their keys
  local): the payload is `%{"genesis" => genesis}`, the genesis their
  identity rests on (`Arca.IdentityAttempts.genesis/2`), which a relying
  home holds to the identifier before it resolves anything, and the
  envelope (`Prima.Carry.Envelope`) names the action, the identifier, this
  home as source, the destination, the source's fixed `/carry` return
  URL, the payload's digest and the `key_epoch` the person's row holds,
  signed by the live key (`Sanctum.Person.sign_envelope/2`). The payload
  and the whole fragment are held to their bounds (8 KiB and 16 KiB,
  `:carry_too_large`) before any storage is taken. The action is stored
  (`Arca.CarryActions`) pending for five minutes, at most twenty a person;
  opening one first ends the person's own expired actions and releases
  their payloads. It answers the action id, the envelope, the payload, the
  fragment, the destination, the return URL and the expiry: what the
  person's browser carries.

  ## Completing

  `complete/3` (`person.carry_complete`) records the navigation outcome the
  destination returned, `admitted` or `refused`, once for the action: it
  is navigation, not authority, so it grants nothing and changes no
  membership or saved address. The action must be the person's own, still
  under the `key_epoch` it was signed under: one signed before a recovery
  or rotation since is refused, as every relying home refuses its
  envelope. An exact retry after a lost response answers the recorded
  outcome with nothing applied again, after the requester's standing is
  read again; another outcome under the same action, an expired or a
  cancelled action is refused. It answers the action's destination as this
  home's row records it, which is where the person's browser goes next:
  never an address the return carried.

  ## Listing and cancelling

  `pending/1` (`person.carry_list`) answers the person's own unexpired
  pending actions, each with its id, destination, phase, expiry, the time
  it began and the `key_epoch` it was signed under (the public log hash its
  envelope carries, which `person.assert` names): what they may resume or
  cancel. It never answers a challenge, an assertion, an envelope or a
  payload, and it is no history of the homes the person visited.
  `cancel/2` (`person.carry_cancel`) ends one of their own open actions:
  nothing more is signed or navigated for it, and its payload is cleared.
  It does not undo a session the destination already admitted. Both read
  only the context's own person's actions; another person's is
  `:not_found`. `sweep/1` is the platform's own housekeeping over every
  person's carries, which the retention cycle runs.
  """

  alias Prima.Carry
  alias Prima.Carry.Envelope
  alias Prima.Identity.Encoding
  alias Sanctum.Context

  @operations ["join"]
  @outcomes ["admitted", "refused"]

  @doc """
  Begin a sign-in carry to `destination` (a home's origin) for `operation`
  (`"join"`, the one operation), for the person of `ctx` (the module doc).

  Answers `%{action_id, envelope, payload, fragment, destination,
  return_url, expires_at}`, the envelope as its JSON map.

  Refusals: `{:invalid_argument, _}` (another operation, a destination that
  is no home's origin or is this home, a carry too large), `:not_enrolled`,
  `:not_found` (the person's keys are at another home), `{:conflict, _}`
  (twenty carries already pending), `:unauthenticated`, `:unavailable`.
  """
  @spec begin(Context.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def begin(%Context{} = ctx, destination, operation \\ "join") when is_binary(destination) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         :ok <- operation(operation),
         {:ok, destination} <- destination(destination),
         {:ok, identity} <- enrolled(actor, user_id),
         {:ok, payload} <- payload(actor, user_id),
         {:ok, digest} <- bounded(Carry.payload_digest(payload)),
         source = Sanctum.Person.home(),
         {:ok, envelope} <-
           Envelope.new(
             action_id: Prima.UUID7.generate_id("car"),
             identifier: identity.identifier,
             source: source,
             destination: destination,
             payload_digest: digest,
             key_epoch: identity.head_hash,
             issued_at: System.os_time(:millisecond)
           )
           |> shaped(),
         {:ok, signed} <- Sanctum.Person.sign_envelope(user_id, envelope),
         {:ok, fragment} <- bounded(Carry.fragment(signed, payload)),
         {:ok, row} <-
           Arca.CarryActions.open(actor, %{
             user_id: user_id,
             action_id: signed.action_id,
             source_home: source,
             destination_home: destination,
             return_url: signed.return_url,
             payload: Encoding.jcs!(payload),
             payload_digest: digest,
             key_epoch: signed.key_epoch
           })
           |> opened() do
      {:ok,
       %{
         action_id: row.action_id,
         envelope: Envelope.encode(signed),
         payload: payload,
         fragment: fragment,
         destination: destination,
         return_url: signed.return_url,
         expires_at: row.expires_at
       }}
    end
  end

  @doc """
  Record the navigation outcome `outcome` (`"admitted"` or `"refused"`) of
  the person's carry `action_id` (the module doc). Answers `%{action_id,
  phase: "completed", outcome, destination}`, the same for an exact retry.

  Refusals: `{:not_found, "carry", action_id}` (no such action of the
  person's), `{:invalid_argument, _}` (another outcome word),
  `{:conflict, _}` (another outcome already recorded, an expired or
  cancelled action, or one signed under keys since replaced), the
  standing's own refusals, `:unavailable`.
  """
  @spec complete(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def complete(%Context{} = ctx, action_id, outcome)
      when is_binary(action_id) and is_binary(outcome) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx),
         :ok <- outcome(outcome),
         {:ok, action} <- own_action(actor, action_id),
         :ok <- standing(ctx),
         :ok <- current_epoch(actor, user_id, action) do
      case Arca.CarryActions.consume(actor, %{
             id: action.id,
             outcome: outcome,
             payload_digest: action.payload_digest
           }) do
        {:ok, row} ->
          {:ok,
           %{
             action_id: row.action_id,
             phase: row.phase,
             outcome: row.outcome,
             destination: row.destination_home
           }}

        {:error, :changed_content} ->
          {:error, {:conflict, "This sign-in already recorded another outcome"}}

        {:error, :expired} ->
          {:error, {:conflict, "This sign-in expired before its outcome was recorded"}}

        {:error, :cancelled} ->
          {:error, {:conflict, "This sign-in was cancelled"}}

        {:error, reason} when reason in [:not_found, :cross_tenant] ->
          {:error, {:not_found, "carry", action_id}}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  The person's own unexpired pending carries, oldest first (the module
  doc): `%{action_id, destination, phase, expires_at, began_at,
  key_epoch}` each, and nothing a carry signs or carries.

  Refusals: `:unauthenticated`, `:unavailable`.
  """
  @spec pending(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def pending(%Context{} = ctx) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- person(ctx) do
      case Arca.CarryActions.pending(actor, user_id) do
        {:ok, rows} -> {:ok, Enum.map(rows, &listed/1)}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Housekeeping, the platform's own: every person's open carries past their
  expiry move to expired with their payloads cleared, and terminal carries
  and login receipts past their retention are removed, at most `limit` of
  each (`Arca.CarryActions.sweep/2`). Opening a carry ends only its own
  person's expired ones, so this is what reaches a person who opens none.
  Answers the counts.
  """
  @spec sweep(pos_integer()) ::
          {:ok, %{expired: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, :database_error}
  def sweep(limit) when is_integer(limit) and limit > 0 do
    case Arca.CarryActions.sweep(Prima.Actor.system(), limit) do
      {:ok, counts} -> {:ok, counts}
      {:error, _reason} -> {:error, :database_error}
    end
  end

  @doc """
  Cancel the person's own open carry `action_id` (the module doc). Answers
  `%{action_id, phase: "cancelled"}`, the same for a carry already
  cancelled.

  Refusals: `{:not_found, "carry", action_id}` (no such action of the
  person's), `{:conflict, _}` (its outcome is recorded, or it expired),
  `:unauthenticated`, `:unavailable`.
  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, action_id) when is_binary(action_id) do
    actor = Context.actor(ctx)

    with {:ok, _user_id} <- person(ctx),
         {:ok, action} <- own_action(actor, action_id) do
      case Arca.CarryActions.cancel(actor, action.id) do
        {:ok, row} ->
          {:ok, %{action_id: row.action_id, phase: row.phase}}

        {:error, :not_open} ->
          {:error, {:conflict, "This sign-in already ended; there is nothing to cancel"}}

        {:error, reason} when reason in [:not_found, :cross_tenant] ->
          not_found(action_id)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  # What a listed carry shows: never its challenge, assertion, envelope or
  # payload.
  defp listed(row) do
    %{
      action_id: row.action_id,
      destination: row.destination_home,
      phase: row.phase,
      expires_at: row.expires_at,
      began_at: row.inserted_at,
      key_epoch: row.key_epoch
    }
  end

  defp person(%Context{plane: :guest}), do: {:error, :unauthenticated}

  defp person(%Context{authenticated: true, anonymous: false, user_id: user_id})
       when is_binary(user_id) do
    if Prima.PersonId.person?(user_id), do: {:ok, user_id}, else: {:error, :unauthenticated}
  end

  defp person(%Context{}), do: {:error, :unauthenticated}

  defp operation(operation) when operation in [nil | @operations], do: :ok

  defp operation(_operation),
    do: {:error, {:invalid_argument, "A sign-in carry serves one operation, join"}}

  defp outcome(outcome) when outcome in @outcomes, do: :ok

  defp outcome(_outcome),
    do: {:error, {:invalid_argument, "A carry's outcome is admitted or refused"}}

  # One destination, another home than this one, by its origin.
  defp destination(destination) do
    home = Sanctum.Person.home()

    cond do
      not Encoding.home?(destination) ->
        {:error,
         {:invalid_argument, "The destination is a home's origin, like https://hub.example"}}

      destination == home ->
        {:error, {:invalid_argument, "A sign-in carry goes to another home than this one"}}

      true ->
        {:ok, destination}
    end
  end

  defp enrolled(actor, user_id) do
    case Arca.PersonIdentities.get(actor, user_id) do
      {:ok, %{provenance: "local", enrollment: "enrolled", identifier: identifier} = row}
      when is_binary(identifier) ->
        {:ok, row}

      {:ok, %{provenance: "local"}} ->
        {:error, :not_enrolled}

      {:ok, _remote} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_enrolled}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp payload(actor, user_id) do
    with {:ok, %{genesis: genesis}} <- Arca.IdentityAttempts.genesis(actor, user_id),
         {:ok, %{} = map} <- Prima.Json.decode(genesis) do
      {:ok, %{"genesis" => map}}
    else
      {:error, :not_found} -> {:error, :not_enrolled}
      _unanswered -> {:error, :unavailable}
    end
  end

  defp bounded({:ok, value}), do: {:ok, value}

  defp bounded({:error, :carry_too_large}),
    do:
      {:error,
       {:invalid_argument,
        "This sign-in is larger than a carry may be (carry_too_large); nothing was sent"}}

  defp bounded({:error, _malformed}), do: {:error, :unavailable}

  defp shaped({:ok, envelope}), do: {:ok, envelope}
  defp shaped({:error, _reason}), do: {:error, :unavailable}

  defp opened({:ok, row}), do: {:ok, row}

  defp opened({:error, :too_many_pending}),
    do:
      {:error,
       {:conflict,
        "Twenty sign-ins are already waiting; finish one or let it expire before another"}}

  defp opened({:error, :carry_too_large}), do: bounded({:error, :carry_too_large})
  defp opened({:error, :unknown_person}), do: {:error, :unauthenticated}
  defp opened({:error, _unanswered}), do: {:error, :unavailable}

  defp own_action(actor, action_id) do
    case Arca.CarryActions.get(actor, action_id) do
      {:ok, %{kind: "source"} = action} -> {:ok, action}
      {:ok, _receipt} -> {:error, {:not_found, "carry", action_id}}
      {:error, reason} when reason in [:not_found, :cross_tenant] -> not_found(action_id)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp not_found(action_id), do: {:error, {:not_found, "carry", action_id}}

  # The requester's standing, read again whether the action is open or
  # its outcome is already recorded: an exact retry applies nothing, and
  # still answers only a person who stands.
  defp standing(ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, _standing} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # An open action signed under a head the person's row no longer holds is
  # an envelope every relying home refuses: its outcome is not recorded.
  defp current_epoch(_actor, _user_id, %{phase: "completed"}), do: :ok

  defp current_epoch(actor, user_id, action) do
    case Arca.PersonIdentities.get(actor, user_id) do
      {:ok, %{head_hash: head}} when head == action.key_epoch ->
        :ok

      {:ok, _moved} ->
        {:error,
         {:conflict,
          "This sign-in was signed under keys your identity has since replaced; begin it again"}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end
end
