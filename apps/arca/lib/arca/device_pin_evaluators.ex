# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DevicePinEvaluators do
  @moduledoc """
  The evaluators a home keeps for remote software devices' six-digit PINs
  (`Arca.Schemas.DevicePinEvaluator`): each a paired client's, its key
  sealed by the caller (`Sanctum.DevicePin`), located by the SHA-256 of
  the identifier the device holds, with the count of attempts charged
  since the device last proved a success (`Prima.DevicePin`).

  ## Lock order

  Every write here takes the paired client's row before the evaluator's,
  the order a client's revocation takes them (`Arca.PairedClients`, whose
  dependents' retirement deletes the client's evaluators): an enrollment
  takes the person's row first, the head of the standing order. A client
  that is not active, a suspended one after a declared restore among them,
  locates no evaluator: it is answered `:not_found`, as an unknown
  identifier is, until its person re-enables it.

  ## The charge, the reset and the replacement

    * `charge/2` charges one attempt and draws the evaluation's reset
      challenge in one transaction, committed before the caller computes
      any answer: a refused wait writes nothing.
    * `reset/4` clears the count of the evaluator whose last charge drew
      the presented nonce, only once the caller's verifier admits the
      proof. An evaluator's first reset marks it confirmed and deletes
      every other of the client's; a confirmed evaluator's later reset
      deletes none, so a replacement stands beside the old evaluator,
      whatever the old one does, until its own first reset.
    * `enroll/3` inserts a new evaluator for an active software client of
      the actor's athanor and deletes the client's evaluators no reset has
      confirmed, so a device holds its confirmed evaluator and at most one
      replacement.

  Each runs under the member's slot (`Arca.Repo.owned/2`): a member that
  lost it writes nothing and answers `:not_owner`. A store that cannot
  answer is `:database_error`.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{DevicePinEvaluator, PairedClient}

  @typedoc "An evaluator row, as a plain map."
  @type row :: %{
          id: String.t(),
          athanor_id: String.t(),
          user_id: String.t(),
          paired_client_id: String.t(),
          identifier_digest: binary(),
          sealed_key: binary(),
          attempts: non_neg_integer(),
          revision: non_neg_integer(),
          next_allowed_at: non_neg_integer() | nil,
          reset_nonce: binary() | nil,
          reset_expires_at: non_neg_integer() | nil,
          confirmed_at: DateTime.t() | nil
        }

  @doc """
  Enroll an evaluator for the person's paired client `attrs.paired_client_id`
  in the actor's athanor: `attrs` holds the row's `id`, `user_id`,
  `identifier_digest` and `sealed_key`. Under the person's lock and the
  client's, the client must be active and a software holder's; then
  `verify` (no arguments) must answer `:ok`, and anything else rolls back
  with it; then the client's unconfirmed evaluators are deleted and the
  new one inserted, its count empty.

  Refusals: `:no_athanor`, `:not_found` (no such active software client of
  the person), `:not_owner`, `:database_error`, or the verifier's.
  """
  @spec enroll(Prima.Actor.t(), map(), (-> :ok | {:error, term()})) ::
          {:ok, row()} | {:error, term()}
  # arca:db-raise-ok the writes run inside `Arca.Repo.owned/2`, which rescues around its transaction.
  def enroll(%Prima.Actor{athanor_id: athanor_id} = actor, attrs, verify)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) and
             is_function(verify, 0) do
    %{
      id: id,
      user_id: user_id,
      paired_client_id: client_id,
      identifier_digest: digest,
      sealed_key: sealed
    } = attrs

    Arca.Repo.owned("Arca.DevicePinEvaluators.enroll", fn ->
      _locked = Arca.DirectoryHeads.lock_person!(user_id)

      client =
        PairedClient
        |> QueryHelpers.where_tenant(actor)
        |> where(
          [p],
          p.id == ^client_id and p.user_id == ^user_id and p.standing == "active" and
            p.source_kind == "device_cert" and p.holder_kind == "software"
        )
        |> QueryHelpers.for_update()
        |> Arca.Repo.one()

      with %PairedClient{} <- client || {:error, :not_found},
           :ok <- verify.() do
        _unconfirmed =
          DevicePinEvaluator
          |> QueryHelpers.where_tenant(actor)
          |> where([e], e.paired_client_id == ^client_id and is_nil(e.confirmed_at))
          |> Arca.Repo.delete_all()

        %DevicePinEvaluator{
          id: id,
          athanor_id: athanor_id,
          user_id: user_id,
          paired_client_id: client_id,
          identifier_digest: digest,
          sealed_key: sealed
        }
        |> Arca.Repo.insert()
      end
    end)
  end

  def enroll(%Prima.Actor{}, _attrs, _verify), do: {:error, :no_athanor}

  @doc """
  Charge one attempt against the evaluator `identifier_digest` locates,
  whoever asks: the identifier is the device's only credential while it
  is locked, so this reads it unscoped. The client's row is held first,
  and must be active; then the evaluator's, and its count moves through
  `Prima.DevicePin.evaluate/2` on the database's clock. A charge writes
  the new count with `nonce` and an expiry `Prima.DeviceCert.Challenge.lifetime_ms/0`
  away as the evaluation's reset challenge, and answers the evaluator, its
  client and the instant, `%{evaluator, client, now}`, once committed.

  Refusals: `:not_found` (no evaluator, or its client not active),
  `{:pin_wait, next_allowed_at}` (nothing written), `:not_owner`,
  `:database_error`.
  """
  @spec charge(binary(), binary()) ::
          {:ok, %{evaluator: row(), client: map(), now: non_neg_integer()}}
          | {:error, :not_found | {:pin_wait, non_neg_integer()} | :not_owner | :database_error}
  # arca:db-raise-ok the reads and the write run inside `Arca.Repo.owned/2`, which rescues around its transaction.
  def charge(identifier_digest, nonce) when is_binary(identifier_digest) and is_binary(nonce) do
    Arca.Repo.owned("Arca.DevicePinEvaluators.charge", fn ->
      with {:ok, evaluator, client} <- held(by_digest(identifier_digest)) do
        now = now_ms()
        count = Map.take(evaluator, [:attempts, :revision, :next_allowed_at])

        case Prima.DevicePin.evaluate(count, now) do
          {:wait, next_allowed_at} ->
            {:error, {:pin_wait, next_allowed_at}}

          {:charged, charged} ->
            evaluator
            |> Ecto.Changeset.change(
              Map.merge(charged, %{
                reset_nonce: nonce,
                reset_expires_at: now + Prima.DeviceCert.Challenge.lifetime_ms(),
                updated_at: Arca.ServerMetaStorage.now!()
              })
            )
            |> Arca.Repo.update()
            |> case do
              {:ok, updated} ->
                {:ok, %{evaluator: updated, client: Arca.Data.project(client), now: now}}

              {:error, _changeset} ->
                {:error, :database_error}
            end
        end
      end
    end)
  end

  @doc """
  Clear the count of the evaluator of the client `client_id` in the
  actor's athanor whose last charge drew `nonce`, whoever asks: the
  device proves its key over that evaluation's reset challenge, which
  `verify` decides, handed the evaluator, its client and the database's
  instant (`:ok` or a refusal, which rolls back). Then the count moves
  through `Prima.DevicePin.reset/2` for the evaluator's own revision and
  the reset challenge is spent. An evaluator's first reset marks it
  confirmed and deletes every other evaluator of the client; a confirmed
  evaluator's later reset deletes none.

  Refusals: `:not_found` (no evaluator holds that nonce, or its client is
  not active), `:no_athanor`, `:not_owner`, `:database_error`, or the
  verifier's.
  """
  @spec reset(
          Prima.Actor.t(),
          String.t(),
          binary(),
          (row(), map(), non_neg_integer() -> :ok | {:error, term()})
        ) :: {:ok, row()} | {:error, term()}
  # arca:db-raise-ok the reads and the writes run inside `Arca.Repo.owned/2`, which rescues around its transaction.
  def reset(%Prima.Actor{athanor_id: athanor_id} = actor, client_id, nonce, verify)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) and
             is_binary(nonce) and is_function(verify, 3) do
    Arca.Repo.owned("Arca.DevicePinEvaluators.reset", fn ->
      with {:ok, evaluator, client} <- held(by_nonce(actor, client_id, nonce)),
           now = now_ms(),
           :ok <- verify.(Arca.Data.project(evaluator), Arca.Data.project(client), now),
           {:reset, cleared} <-
             Prima.DevicePin.reset(
               Map.take(evaluator, [:attempts, :revision, :next_allowed_at]),
               evaluator.revision
             ) do
        # A replacement's first reset retires the evaluator it replaces; a
        # confirmed evaluator's later reset leaves a pending replacement
        # standing until its own first reset.
        _others =
          if is_nil(evaluator.confirmed_at) do
            DevicePinEvaluator
            |> QueryHelpers.where_tenant(actor)
            |> where([e], e.paired_client_id == ^client_id and e.id != ^evaluator.id)
            |> Arca.Repo.delete_all()
          end

        evaluator
        |> Ecto.Changeset.change(
          Map.merge(cleared, %{
            reset_nonce: nil,
            reset_expires_at: nil,
            confirmed_at: evaluator.confirmed_at || Arca.ServerMetaStorage.now!(),
            updated_at: Arca.ServerMetaStorage.now!()
          })
        )
        |> Arca.Repo.update()
      end
    end)
  end

  def reset(%Prima.Actor{}, _client_id, _nonce, _verify), do: {:error, :no_athanor}

  @doc """
  The evaluators of the actor's athanor's client `client_id`, oldest
  first: what a person's devices show of a PIN.
  """
  @spec list(Prima.Actor.t(), String.t()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.DevicePinEvaluators.list", fn ->
      {:ok,
       DevicePinEvaluator
       |> QueryHelpers.where_tenant(actor)
       |> where([e], e.paired_client_id == ^client_id)
       |> order_by([e], asc: e.inserted_at, asc: e.id)
       |> Arca.Repo.all()}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _client_id), do: {:error, :no_athanor}

  @doc false
  @spec delete_clients!([String.t()]) :: non_neg_integer()
  # A revocation's dependents (`Arca.PairedClients.retire_dependents!/1`):
  # every evaluator of the revoked clients, in the caller's transaction.
  def delete_clients!([]), do: 0

  # arca:unscoped-ok the caller names the clients it revoked under its own scope.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def delete_clients!(client_ids) when is_list(client_ids) do
    {count, _} =
      Arca.Repo.delete_all(
        from(e in DevicePinEvaluator, where: e.paired_client_id in ^client_ids)
      )

    count
  end

  # ---- internals -------------------------------------------------------------

  # A locked device names its evaluator by the identifier's digest alone,
  # before any context exists.
  defp by_digest(digest), do: where(DevicePinEvaluator, [e], e.identifier_digest == ^digest)

  # A reset names the athanor and client its proof binds; the proof is
  # verified over the row it finds.
  defp by_nonce(actor, client_id, nonce) do
    DevicePinEvaluator
    |> QueryHelpers.where_tenant(actor)
    |> where([e], e.paired_client_id == ^client_id and e.reset_nonce == ^nonce)
  end

  # The evaluator `query` names and its client, the client's row held
  # first, as a revocation takes it, then the evaluator's, read again under
  # its lock: a client that is not active locates nothing.
  # arca:unscoped-ok a locked device's evaluator is found by its identifier's digest before any context exists, and its client under the athanor that row names.
  defp held(query) do
    with %DevicePinEvaluator{} = found <- Arca.Repo.one(query) || {:error, :not_found},
         %PairedClient{} = client <-
           PairedClient
           |> where(
             [p],
             p.id == ^found.paired_client_id and p.athanor_id == ^found.athanor_id and
               p.standing == "active"
           )
           |> QueryHelpers.for_share()
           |> Arca.Repo.one() || {:error, :not_found},
         %DevicePinEvaluator{} = evaluator <-
           query
           |> where([e], e.id == ^found.id)
           |> QueryHelpers.for_update()
           |> Arca.Repo.one() || {:error, :not_found} do
      {:ok, evaluator, client}
    end
  end

  defp now_ms, do: DateTime.to_unix(Arca.ServerMetaStorage.now!(), :millisecond)
end
