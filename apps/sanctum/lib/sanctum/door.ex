# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Door do
  @moduledoc """
  The door: which people may sign in to this server.

  The door judges people, never a sign-in method, an email or a provider
  subject. A person is made only by an admission (`Sanctum.Newcomer`), and
  a sign-in method only unlocks a person who exists (`Sanctum.SignIn`), so
  what the door asks at every sign-in is about the person:

    * A local person — one whose keys this server holds — is admitted
      unless a deny names them: their admission was the admitting act.
    * A remote person — one whose keys another CYFR holds, admitted
      through the CYFR sign-in — is admitted by `*` or by an allow naming
      their identifier (`per_…`), unless a deny names them.

  The server allowlist (`Sanctum.Door.Store`) holds allows of an
  identifier or `*`, and denies of a person (their `usr_…` id) or an
  identifier. A deny wins over every allow, so a public door still has an
  eject; allowing that person again is an explicit operator act. A deny
  naming a platform administrator is refused where it is written
  (`Sanctum.Door.Store.deny/4`).

  A refusal the operator can undo leaves a trace: a remote person, or a
  remote newcomer, the door does not admit is recorded as a pending
  request naming their identifier, which `door.requests` lists and
  `door.resolve` turns into an allow. A deny already has its answer, so
  it leaves none. Refusals carry no detail a stranger could use to
  enumerate the list.

  `{:error, :unavailable}` is the store failing to answer, which is
  neither a deny nor "not allowed": the door refuses on it without
  claiming either.
  """

  require Logger

  alias Sanctum.Door.Store

  # The page the users walk takes; `Users.list/1` caps at 500 either way.
  @page 500

  @type verdict :: {:ok, :allowed} | {:error, :denied | :not_allowed | :unavailable}

  @doc """
  Whether the person `user` (their `users` row, as a map) may sign in now
  (the module doc). No side effect: a sign-in path that acts on the answer
  asks `sign_in/1`.
  """
  @spec admit_person(%{required(:id) => String.t(), optional(atom()) => term()}) :: verdict()
  def admit_person(%{id: user_id}) when is_binary(user_id) do
    case identity(user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        with :no <- deny_arm(user_id, identifier), :no <- remote_arms(identifier) do
          {:error, :not_allowed}
        end

      {:ok, identity} ->
        with :no <- deny_arm(user_id, identity[:identifier]), do: {:ok, :allowed}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  @doc """
  Whether a remote newcomer, no person here yet, named by the identifier
  their CYFR sign-in verified, may be admitted: no deny names the
  identifier, and `*` or an allow names it. No side effect.
  """
  @spec admit_identifier(String.t()) :: verdict()
  def admit_identifier(identifier) when is_binary(identifier) do
    with :no <- deny_arm(nil, identifier), :no <- remote_arms(identifier) do
      {:error, :not_allowed}
    end
  end

  @doc """
  `admit_person/1` at a sign-in: a refusal is audited, a remote person
  the door does not admit leaves a request naming their identifier, and
  the refusal travels as `{:error, {:door, reason}}`.
  """
  @spec sign_in(%{required(:id) => String.t(), optional(atom()) => term()}) ::
          {:ok, :allowed} | {:error, {:door, atom()}}
  def sign_in(%{id: user_id} = user) when is_binary(user_id) do
    case admit_person(user) do
      {:ok, :allowed} ->
        {:ok, :allowed}

      {:error, reason} ->
        identifier =
          case identity(user_id) do
            {:ok, %{provenance: "remote", identifier: identifier}} -> identifier
            _local -> nil
          end

        refused(reason, user_id, identifier)
    end
  end

  @doc "`admit_identifier/1` at a remote newcomer's sign-in, refusing as `sign_in/1` does."
  @spec sign_in_identifier(String.t()) :: {:ok, :allowed} | {:error, {:door, atom()}}
  def sign_in_identifier(identifier) when is_binary(identifier) do
    case admit_identifier(identifier) do
      {:ok, :allowed} -> {:ok, :allowed}
      {:error, reason} -> refused(reason, nil, identifier)
    end
  end

  @doc """
  Would an invite of the person identifier `identifier` (`per_…`) admit
  that person on their first CYFR sign-in? `admit_identifier/1`'s answer,
  with an identifier the store could not be asked about not admitted, so
  the invite queues a request the operator can resolve rather than going
  out as if the door were open.
  """
  @spec identifier_admitted?(String.t()) :: boolean()
  def identifier_admitted?(identifier) when is_binary(identifier),
    do: match?({:ok, :allowed}, admit_identifier(identifier))

  @doc """
  Ask the door about everyone it has already let in, and eject whoever it
  would refuse now.

  Removing an allow entry — `*` most of all — closes the door, but the
  sessions and keys it issued outlive it by up to their whole TTL. Rather
  than work out which entry admitted whom, this re-asks `admit_person/1`
  for every person the server knows: it is the same decision, made by the
  same function, so the door cannot mean one thing at sign-in and another
  here.

  What it takes is what the door issued: sessions and API keys. What it
  leaves is standing — nothing is archived and no membership is touched.
  That is the difference between closing a door and denying a person
  (`Sanctum.Tenancy.Users.deny/1`, which does both).

  Returns the number of people ejected. Rare and operator-triggered, so the
  full walk is affordable; it is called from a task so a door verb answers
  without waiting.
  """
  @spec reconcile() :: {:ok, non_neg_integer()}
  def reconcile do
    {:ok, eject_refused(nil, 0)}
  end

  # In id order, each page after the last person the previous one visited,
  # ejected or not: a sign-in during the walk changes no one's place in it.
  defp eject_refused(after_id, ejected) do
    case Sanctum.Tenancy.Users.list_by_id(limit: @page, after: after_id) do
      {:ok, []} ->
        ejected

      {:ok, users} ->
        ejected = ejected + Enum.count(users, &eject_if_refused/1)

        # A page short of the limit is the last one; anything else and the
        # walk continues, because ejecting does not remove the rows.
        if length(users) < @page,
          do: ejected,
          else: eject_refused(List.last(users).id, ejected)

      # An outage is not a refusal: the people not yet asked about stay
      # admitted, and the next reconcile asks again.
      {:error, _unanswered} ->
        Logger.warning(
          "[Sanctum.Door] the people after #{inspect(after_id)} could not be read " <>
            "(the store did not answer) — leaving them admitted"
        )

        ejected
    end
  end

  defp eject_if_refused(user) do
    case admit_person(user) do
      {:ok, :allowed} ->
        false

      # An outage is not a refusal. Ejecting on one would take every
      # session and key on the server the first time the store blinked,
      # and nothing here would say why. The walk leaves them and the next
      # reconcile asks again.
      {:error, :unavailable} ->
        Logger.warning(
          "[Sanctum.Door] #{user.id} could not be asked about (the door store did not " <>
            "answer) — leaving them admitted"
        )

        false

      {:error, reason} ->
        Logger.info("[Sanctum.Door] #{user.id} no longer admitted (#{reason}) — ejecting")
        Sanctum.Session.revoke_all_for_user(user.id)
        Sanctum.ApiKey.revoke_all_created_by(user.id)
        true
    end
  end

  @doc "The one refusal a stranger sees, whichever branch refused."
  @spec refusal_message() :: String.t()
  def refusal_message, do: "not allowed on this server — ask the operator"

  # The person's identity row: provenance and identifier. A person with no
  # row is judged as a local person by their own id.
  defp identity(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, identity} -> {:ok, identity}
      {:error, :not_found} -> {:ok, %{provenance: "local", identifier: nil}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The stored door, in the order the entries outrank each other: a deny
  # beats `*`, `*` beats an identifier allow. A lookup the store could not
  # answer stops the walk there rather than falling through to the next
  # arm, which would read an outage as "nothing admits you".
  defp deny_arm(user_id, identifier) do
    case Store.denied(user_id, identifier) do
      {:ok, true} -> {:error, :denied}
      {:ok, false} -> :no
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp remote_arms(identifier) do
    with :no <- admits(Store.wildcard()), do: admits(Store.allowed("identifier", identifier))
  end

  defp admits({:ok, true}), do: {:ok, :allowed}
  defp admits({:ok, false}), do: :no
  defp admits({:error, :unavailable}), do: {:error, :unavailable}

  defp refused(reason, user_id, identifier) do
    :telemetry.execute([:cyfr, :sanctum, :door, :refused], %{count: 1}, %{
      user_id: user_id,
      identifier: identifier,
      reason: reason
    })

    record_request(reason, identifier)
    {:error, {:door, reason}}
  end

  # A refusal the operator can act on: only `:not_allowed` of an identifier.
  # A `:denied` refusal already has its answer, and writing a request for
  # it would offer to undo a deny by approving it.
  defp record_request(:not_allowed, identifier) when is_binary(identifier) do
    case Store.request("identifier", identifier, identifier, "refused at sign-in") do
      {:ok, :created, _} -> Sanctum.Notify.allowlist_request(identifier)
      _ -> :ok
    end
  end

  defp record_request(_reason, _identifier), do: :ok
end
