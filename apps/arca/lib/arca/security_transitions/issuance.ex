# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Issuance do
  @moduledoc """
  The one transaction a credential is issued in: the rows its standing
  rests on locked and reread, the caller's policy asked over them, and the
  credential written only if it agrees — all before commit, so a
  transition that retires that standing either commits first, and the
  issuance rereads its result, or waits for the credential and then
  retires it.

  `targets` names the rows: the person (`:user_id`), the estate the
  credential works in (`:athanor_id`, or nil), the membership that
  authorized the caller's focus (`:membership_id`, or nil) and the
  credential the caller holds (`:source`: `{:session, token_hash}`,
  `{:api_key, id}`, or nil). They are locked in the order every standing
  transition takes (`Arca.SecurityTransitions`): person, estate,
  membership, session, key; the credential `write` changes comes last.

  `verify` is handed plain maps of those rows, each nil when there is no
  such row, and the database's own time read after every lock was won —
  an expiry is judged on that instant, never on one taken before a wait.
  `write` runs only after `verify` answers `:ok` and answers
  `{:ok, result}` or `{:error, reason}`; either refusal rolls everything
  back.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, User}
  alias Arca.SecurityTransitions.Projection

  @type source :: {:session, binary()} | {:api_key, String.t()} | nil
  @type targets :: %{
          required(:user_id) => String.t(),
          required(:athanor_id) => String.t() | nil,
          required(:membership_id) => String.t() | nil,
          required(:source) => source()
        }

  @doc "Lock `targets`' rows, ask `verify`, then `write`, in one locking transaction."
  @spec run(
          targets(),
          (map() -> :ok | {:error, term()}),
          (map() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  # arca:db-raise-ok a transaction step: every caller (`Arca.SessionStorage`, `Arca.ApiKeyStorage`) rescues around it.
  def run(%{user_id: user_id} = targets, verify, write)
      when is_binary(user_id) and is_function(verify, 1) and is_function(write, 1) do
    fn ->
      projection = locked(targets)

      with :ok <- verify.(projection),
           {:ok, result} <- write.(projection) do
        result
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end
    |> Arca.Repo.locking_transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # The rows `targets` names, locked in the standing order and projected,
  # with the database's own time read after every lock was won. Runs
  # inside the caller's locking transaction; `Arca.CredentialBindings`
  # reads a derived credential's rows through it too.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  @spec locked(targets()) :: map()
  def locked(%{user_id: user_id} = targets) when is_binary(user_id) do
    %{
      user: Projection.user(lock_user(user_id)),
      athanor: Projection.athanor(lock_athanor(Map.get(targets, :athanor_id))),
      membership: Projection.membership(lock_membership(Map.get(targets, :membership_id))),
      source: lock_source(Map.get(targets, :source)),
      now: Arca.ServerMetaStorage.now!()
    }
  end

  defp lock_user(user_id) do
    from(u in User, where: u.id == ^user_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_athanor(athanor_id) when is_binary(athanor_id) do
    from(a in Athanor, where: a.id == ^athanor_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_athanor(_athanor_id), do: nil

  # arca:unscoped-ok the membership an issuing context was focused through, by its own id; a platform row names no athanor.
  defp lock_membership(membership_id) when is_binary(membership_id) do
    from(m in Membership, where: m.id == ^membership_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp lock_membership(_membership_id), do: nil

  # arca:unscoped-ok a session addressed by its token hash, the credential the caller holds.
  defp lock_source({:session, token_hash}) when is_binary(token_hash) do
    session =
      from(s in Session, where: s.token_hash == ^token_hash)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    %{kind: :session, row: Projection.session(session)}
  end

  # arca:unscoped-ok an API key addressed by its own id, the credential the caller holds.
  defp lock_source({:api_key, id}) when is_binary(id) do
    key =
      from(k in ApiKey, where: k.id == ^id)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    %{kind: :api_key, row: Projection.api_key(key)}
  end

  defp lock_source(_source), do: nil
end
