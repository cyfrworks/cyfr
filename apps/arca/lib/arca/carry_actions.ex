# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CarryActions do
  @moduledoc """
  The sign-in carry's durable actions (`Arca.Schemas.CarryAction`), which
  are a person's and never an athanor's.

  ## Source actions

  At the person's signing home, a `source` action is opened for exactly one
  destination (`open/2`): the person, the source and destination homes,
  the fixed return URL, the operation (`join`), the immutable payload and
  its digest, the `key_epoch` and a five-minute lifetime on the database's
  clock. A person holds at most 20 unexpired pending actions, and a
  payload is at most 8 KiB (`:carry_too_large`).

  Its phases are `pending | delivered | completed | cancelled | expired`,
  each move a conditional write on the phase and revision the caller read.
  The destination's challenge is attached once (`attach_challenge/3`) and
  the issued assertion recorded once (`record_assertion/3`): either is
  immutable, the same value again is answered as it stands, and another is
  refused. `consume/2` completes the action once with its outcome: an
  exact retry answers the recorded result without a second mutation, and
  changed content is refused. Completion, cancellation and expiry clear
  the payload; the row keeps its digests and outcome for 24 hours
  (`retain_until`), after which `sweep/2` removes it.

  ## Login receipts

  At a relying home, `record_receipt/2` writes one `login_receipt` per
  destination home and challenge id, bound to the resolved person, the
  browser-binding digest and the accepted assertion's digest, in the
  caller's transaction beside the session it mints. The exact receipt
  again answers the recorded one; another binding or assertion is refused.
  A receipt expires with the carry retention and admits nothing after.

  Every function takes the actor first: a person reaches their own source
  actions, and the platform's own actor any action and every receipt.
  Opening an action, attaching its challenge, recording its assertion and
  recording a receipt prove first that this member still owns its slot
  (`:not_owner`).
  """

  import Ecto.Query

  alias Arca.Schemas.{CarryAction, User}

  @lifetime_ms 5 * 60 * 1000
  @retention_ms 24 * 60 * 60 * 1000
  @max_pending 20
  @max_payload_bytes 8 * 1024
  @open ~w(pending delivered)
  @sweep_batch 500

  @typedoc "A carry row, as a plain map."
  @type row :: map()

  @doc "How long a pending action lives, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  @doc "How long a terminal action or a receipt is retained, in milliseconds."
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @doc "The most unexpired pending actions one person holds."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc "The largest payload, in bytes."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc """
  Open a pending source action: `attrs` names the `:user_id` (the
  actor's own, unless the platform's actor opens it), the `:action_id`,
  the `:source_home`, the `:destination_home`, the fixed `:return_url`,
  the `:payload` bytes and their `:payload_digest`, and the `:key_epoch`.
  Refusals: `:carry_too_large`, `:too_many_pending`, `:conflict` (the
  action id is taken), `:unknown_person`, `:not_owner`, `:cross_tenant`,
  `{:invalid, errors}`, `:database_error`.
  """
  @spec open(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def open(%Prima.Actor{} = actor, attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    with :ok <- person(actor, attrs[:user_id]),
         {:ok, row} <- build_source(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.CarryActions.open", fn ->
        fenced(fn -> open_in(row) end)
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Attach the destination's challenge to the pending action `id`, once:
  `challenge` is its text and `challenge_digest` its digest. The same
  challenge again answers the action; another is `:challenge_attached`.
  """
  @spec attach_challenge(Prima.Actor.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def attach_challenge(%Prima.Actor{} = actor, id, %{challenge: text, challenge_digest: digest})
      when is_binary(id) and is_binary(text) and text != "" do
    if Prima.Identity.Encoding.digest?(digest) do
      once(actor, id, "Arca.CarryActions.attach_challenge", fn action, now ->
        cond do
          action.challenge == text and action.challenge_digest == digest -> {:ok, action}
          not is_nil(action.challenge) -> {:error, :challenge_attached}
          true -> write_once(action, [challenge: text, challenge_digest: digest], now)
        end
      end)
    else
      {:error, {:invalid, %{challenge_digest: ["is not a sha256 digest"]}}}
    end
  end

  @doc """
  Record the assertion issued for the pending action `id`, once, after its
  challenge is attached: the same assertion again answers the action;
  another is `:assertion_recorded`.
  """
  @spec record_assertion(Prima.Actor.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def record_assertion(%Prima.Actor{} = actor, id, %{assertion: bytes, assertion_digest: digest})
      when is_binary(id) and is_binary(bytes) and bytes != "" do
    if Prima.Identity.Encoding.digest?(digest) do
      once(actor, id, "Arca.CarryActions.record_assertion", fn action, now ->
        cond do
          action.assertion == bytes and action.assertion_digest == digest -> {:ok, action}
          not is_nil(action.assertion) -> {:error, :assertion_recorded}
          is_nil(action.challenge) -> {:error, :no_challenge}
          true -> write_once(action, [assertion: bytes, assertion_digest: digest], now)
        end
      end)
    else
      {:error, {:invalid, %{assertion_digest: ["is not a sha256 digest"]}}}
    end
  end

  @doc """
  Move the pending action `id` to `delivered` while it still holds
  `expected_revision`. `:stale` when it moved, `:expired` past its expiry.
  """
  @spec deliver(Prima.Actor.t(), String.t(), pos_integer()) :: {:ok, row()} | {:error, term()}
  def deliver(%Prima.Actor{} = actor, id, expected_revision)
      when is_binary(id) and is_integer(expected_revision) do
    transition(actor, id, "Arca.CarryActions.deliver", fn action, now ->
      cond do
        action.phase != "pending" -> {:error, :not_pending}
        action.revision != expected_revision -> {:error, :stale}
        expired?(action, now) -> {:error, :expired}
        true -> moved(action, "pending", [phase: "delivered"], now)
      end
    end)
  end

  @doc """
  Complete the open action `attrs.id` once with `attrs.outcome` (and
  `attrs.outcome_body`, text), for the content `attrs.payload_digest`
  names. An exact retry answers the recorded result and writes nothing;
  another outcome or digest under the same action is `:changed_content`.
  Refusals also: `:expired`, `:cancelled`, `:not_found`, `:cross_tenant`.
  """
  @spec consume(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def consume(%Prima.Actor{} = actor, %{id: id, outcome: outcome} = attrs)
      when is_binary(id) and is_binary(outcome) and outcome != "" do
    body = Map.get(attrs, :outcome_body)
    digest = Map.get(attrs, :payload_digest)

    transition(actor, id, "Arca.CarryActions.consume", fn action, now ->
      same? =
        action.outcome == outcome and action.outcome_body == body and
          action.payload_digest == digest

      cond do
        action.phase == "completed" and same? -> {:ok, action}
        action.phase == "completed" -> {:error, :changed_content}
        action.payload_digest != digest -> {:error, :changed_content}
        action.phase == "cancelled" -> {:error, :cancelled}
        action.phase == "expired" -> {:error, :expired}
        expired?(action, now) -> {:error, :expired}
        true -> finish(action, "completed", [outcome: outcome, outcome_body: body], now)
      end
    end)
  end

  @doc "Cancel the open action `id`: no further signing or navigation; its payload is cleared."
  @spec cancel(Prima.Actor.t(), String.t()) :: {:ok, row()} | {:error, term()}
  def cancel(%Prima.Actor{} = actor, id) when is_binary(id) do
    transition(actor, id, "Arca.CarryActions.cancel", fn action, now ->
      cond do
        action.phase == "cancelled" -> {:ok, action}
        action.phase in @open -> finish(action, "cancelled", [], now)
        true -> {:error, :not_open}
      end
    end)
  end

  @doc "The action `id`, if the actor may read it."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.CarryActions.get", fn -> held(actor, id) end)
    |> Arca.Data.project()
  end

  @doc "The person's unexpired open source actions, oldest first: what they may resume or cancel."
  @spec pending(Prima.Actor.t(), String.t()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  def pending(%Prima.Actor{} = actor, user_id) when is_binary(user_id) do
    with :ok <- person(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.CarryActions.pending", fn ->
        now = Arca.ServerMetaStorage.now!()

        {:ok,
         Arca.Repo.all(
           from(a in CarryAction,
             where:
               a.kind == "source" and a.user_id == ^user_id and a.phase in ^@open and
                 a.expires_at > ^now,
             order_by: [asc: a.inserted_at, asc: a.id]
           )
         )}
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Record a relying home's login receipt: `attrs` names the carry
  `:action_id`, this home as `:destination_home`, the `:challenge_id`, the
  resolved `:user_id`, the `:source_home`, the `:key_epoch`, the
  `:browser_binding_digest`, the `:assertion_digest` and the `:outcome`
  (with an optional `:outcome_body`, text). The platform's own actor
  only, in the caller's transaction beside the session it mints. The exact
  receipt again answers the recorded one; another binding or assertion
  under that challenge is `:receipt_conflict`; a receipt past its
  retention is `:expired`. An exact retry that raced the first and lost
  the receipt's unique index waits for it and answers it the same way.
  """
  @spec record_receipt(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def record_receipt(%Prima.Actor{scope: :platform, system: true}, attrs) when is_map(attrs) do
    with {:ok, row} <- build_receipt(Map.new(attrs)) do
      Arca.Repo.Errors.with_db_rescue("Arca.CarryActions.record_receipt", fn ->
        fenced(fn -> receipt_in(row) end)
      end)
      |> Arca.Data.project()
    end
  end

  def record_receipt(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  Housekeeping, the platform's own actor only: open actions past their
  expiry move to `expired` with their payload cleared, and terminal
  actions and receipts past their retention are removed, at most `limit`
  of each per call. Answers the counts.
  """
  @spec sweep(Prima.Actor.t(), pos_integer()) ::
          {:ok, %{expired: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, :cross_tenant | :database_error}
  def sweep(actor, limit \\ @sweep_batch)

  def sweep(%Prima.Actor{scope: :platform, system: true}, limit)
      when is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.CarryActions.sweep", fn ->
      Arca.Repo.locking_transaction(fn -> swept(limit) end)
    end)
  end

  def sweep(%Prima.Actor{}, _limit), do: {:error, :cross_tenant}

  defp swept(limit) do
      now = Arca.ServerMetaStorage.now!()
      retain = DateTime.add(now, @retention_ms, :millisecond)

      due =
        from(a in CarryAction,
          where: a.phase in ^@open and a.expires_at <= ^now,
          select: a.id,
          limit: ^limit
        )

      {expired, _} =
        from(a in CarryAction, where: a.id in subquery(due) and a.phase in ^@open)
        |> Arca.Repo.update_all(
          set: [phase: "expired", payload: nil, retain_until: retain, updated_at: now],
          inc: [revision: 1]
        )

      gone =
        from(a in CarryAction,
          where: not is_nil(a.retain_until) and a.retain_until <= ^now,
          select: a.id,
          limit: ^limit
        )

      {removed, _} = Arca.Repo.delete_all(from(a in CarryAction, where: a.id in subquery(gone)))

      %{expired: expired, removed: removed}
  end

  # ---- internals -------------------------------------------------------------

  defp open_in(row) do
    now = Arca.ServerMetaStorage.now!()

    # The person's row, locked, orders two opens of one person, so the
    # count below is never an unlocked read.
    person =
      from(u in User, where: u.id == ^row.user_id, select: u.id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()

    pending_count =
      Arca.Repo.one(
        from(a in CarryAction,
          where:
            a.kind == "source" and a.user_id == ^row.user_id and a.phase in ^@open and
              a.expires_at > ^now,
          select: count(a.id)
        )
      )

    cond do
      is_nil(person) ->
        {:error, :unknown_person}

      pending_count >= @max_pending ->
        {:error, :too_many_pending}

      true ->
        row = %{
          row
          | expires_at: DateTime.add(now, @lifetime_ms, :millisecond),
            inserted_at: now,
            updated_at: now
        }

        case Arca.Repo.insert_all(CarryAction, [row], on_conflict: :nothing) do
          {1, _} -> {:ok, Arca.Repo.get!(CarryAction, row.id)}
          {0, _} -> {:error, :conflict}
        end
    end
  end

  defp receipt_in(row) do
    now = Arca.ServerMetaStorage.now!()

    existing =
      Arca.Repo.one(
        from(a in CarryAction,
          where:
            a.kind == "login_receipt" and a.destination_home == ^row.destination_home and
              a.challenge_id == ^row.challenge_id
        )
      )

    case existing do
      nil ->
        row = %{
          row
          | expires_at: DateTime.add(now, @retention_ms, :millisecond),
            retain_until: DateTime.add(now, @retention_ms, :millisecond),
            inserted_at: now,
            updated_at: now
        }

        case Arca.Repo.insert_all(CarryAction, [row], on_conflict: :nothing) do
          {1, _} -> {:ok, Arca.Repo.get!(CarryAction, row.id)}
          {0, _} -> recorded_receipt(row, now)
        end

      %CarryAction{} = receipt ->
        answer_receipt(receipt, row, now)
    end
  end

  # The insert lost the receipt's unique index to a concurrent writer that
  # has since committed (PostgreSQL waits for it before answering the
  # conflict): the receipt it recorded, read again, answers this one.
  defp recorded_receipt(row, now) do
    from(a in CarryAction,
      where:
        a.kind == "login_receipt" and a.destination_home == ^row.destination_home and
          a.challenge_id == ^row.challenge_id
    )
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :receipt_conflict}
      %CarryAction{} = receipt -> answer_receipt(receipt, row, now)
    end
  end

  defp answer_receipt(receipt, row, now) do
    cond do
      DateTime.compare(receipt.expires_at, now) != :gt -> {:error, :expired}
      same_receipt?(receipt, row) -> {:ok, receipt}
      true -> {:error, :receipt_conflict}
    end
  end

  defp same_receipt?(receipt, row) do
    receipt.user_id == row.user_id and receipt.action_id == row.action_id and
      receipt.browser_binding_digest == row.browser_binding_digest and
      receipt.assertion_digest == row.assertion_digest and receipt.outcome == row.outcome and
      receipt.key_epoch == row.key_epoch
  end

  # A move of one source action, read and decided under a lock and written
  # conditionally on the phase it read.
  defp transition(actor, id, tag, decide) do
    Arca.Repo.Errors.with_db_rescue(tag, fn ->
      Arca.Repo.locking_transaction(fn ->
        now = Arca.ServerMetaStorage.now!()

        with {:ok, action} <- locked(actor, id) do
          decide.(action, now)
        end
        |> committed()
      end)
    end)
    |> Arca.Data.project()
  end

  # A challenge or an assertion, once: what the action will sign or carry,
  # so the write is fenced (`fenced/1`) as well as locked.
  defp once(actor, id, tag, decide) do
    Arca.Repo.Errors.with_db_rescue(tag, fn ->
      fenced(fn ->
        now = Arca.ServerMetaStorage.now!()

        with {:ok, action} <- locked(actor, id) do
          cond do
            action.phase not in @open -> {:error, :not_open}
            expired?(action, now) -> {:error, :expired}
            true -> decide.(action, now)
          end
        end
      end)
    end)
    |> Arca.Data.project()
  end

  defp write_once(action, set, now), do: moved(action, action.phase, set, now)

  defp finish(action, phase, set, now) do
    moved(
      action,
      action.phase,
      [phase: phase, payload: nil, retain_until: DateTime.add(now, @retention_ms, :millisecond)] ++
        set,
      now
    )
  end

  defp moved(action, from_phase, set, now) do
    {count, _} =
      from(a in CarryAction,
        where: a.id == ^action.id and a.phase == ^from_phase and a.revision == ^action.revision
      )
      |> Arca.Repo.update_all(set: Keyword.put(set, :updated_at, now), inc: [revision: 1])

    if count == 1,
      do: {:ok, Arca.Repo.get!(CarryAction, action.id)},
      else: {:error, :stale}
  end

  defp locked(actor, id) do
    from(a in CarryAction, where: a.id == ^id and a.kind == "source")
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      action -> if person(actor, action.user_id) == :ok, do: {:ok, action}, else: {:error, :cross_tenant}
    end
  end

  defp held(actor, id) do
    case Arca.Repo.get(CarryAction, id) do
      nil ->
        {:error, :not_found}

      %CarryAction{kind: "login_receipt"} = receipt ->
        if platform?(actor), do: {:ok, receipt}, else: {:error, :cross_tenant}

      action ->
        if person(actor, action.user_id) == :ok, do: {:ok, action}, else: {:error, :cross_tenant}
    end
  end

  defp expired?(action, now), do: DateTime.compare(action.expires_at, now) != :gt

  # A relying home's receipt is the platform's to read, never a person's.
  defp platform?(%Prima.Actor{scope: :platform}), do: true
  defp platform?(%Prima.Actor{}), do: false

  defp person(%Prima.Actor{scope: :platform}, _user_id), do: :ok

  defp person(%Prima.Actor{user_id: user_id}, user_id) when is_binary(user_id) and user_id != "",
    do: :ok

  defp person(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  defp build_source(attrs) do
    payload = attrs[:payload]

    errors =
      [
        {:user_id, nonempty?(attrs[:user_id])},
        {:action_id, Prima.Identity.Encoding.id?(attrs[:action_id])},
        {:source_home, Prima.Identity.Encoding.home?(attrs[:source_home])},
        {:destination_home, Prima.Identity.Encoding.home?(attrs[:destination_home])},
        {:return_url, nonempty?(attrs[:return_url])},
        {:payload, is_binary(payload) and payload != ""},
        {:payload_digest, Prima.Identity.Encoding.digest?(attrs[:payload_digest])},
        {:key_epoch, Prima.Identity.Encoding.digest?(attrs[:key_epoch])}
      ]
      |> errors()

    cond do
      errors != %{} ->
        {:error, {:invalid, errors}}

      byte_size(payload) > @max_payload_bytes ->
        {:error, :carry_too_large}

      true ->
        {:ok,
         Map.merge(blank(), %{
           id: attrs.action_id,
           kind: "source",
           action_id: attrs.action_id,
           user_id: attrs.user_id,
           source_home: attrs.source_home,
           destination_home: attrs.destination_home,
           return_url: attrs.return_url,
           payload: payload,
           payload_digest: attrs.payload_digest,
           key_epoch: attrs.key_epoch,
           phase: "pending"
         })}
    end
  end

  defp build_receipt(attrs) do
    errors =
      [
        {:action_id, Prima.Identity.Encoding.id?(attrs[:action_id])},
        {:destination_home, Prima.Identity.Encoding.home?(attrs[:destination_home])},
        {:source_home, Prima.Identity.Encoding.home?(attrs[:source_home])},
        {:challenge_id, Prima.Identity.Encoding.id?(attrs[:challenge_id])},
        {:user_id, nonempty?(attrs[:user_id])},
        {:key_epoch, Prima.Identity.Encoding.digest?(attrs[:key_epoch])},
        {:browser_binding_digest, Prima.Identity.Encoding.digest?(attrs[:browser_binding_digest])},
        {:assertion_digest, Prima.Identity.Encoding.digest?(attrs[:assertion_digest])},
        {:outcome, nonempty?(attrs[:outcome])}
      ]
      |> errors()

    if errors == %{} do
      {:ok,
       Map.merge(blank(), %{
         id: Prima.UUID7.generate_id("crr"),
         kind: "login_receipt",
         action_id: attrs.action_id,
         user_id: attrs.user_id,
         source_home: attrs.source_home,
         destination_home: attrs.destination_home,
         key_epoch: attrs.key_epoch,
         challenge_id: attrs.challenge_id,
         browser_binding_digest: attrs.browser_binding_digest,
         assertion_digest: attrs.assertion_digest,
         outcome: attrs.outcome,
         outcome_body: attrs[:outcome_body],
         phase: "completed"
       })}
    else
      {:error, {:invalid, errors}}
    end
  end

  defp blank do
    %{
      return_url: nil,
      operation: "join",
      payload: nil,
      payload_digest: nil,
      challenge: nil,
      challenge_digest: nil,
      challenge_id: nil,
      assertion: nil,
      assertion_digest: nil,
      browser_binding_digest: nil,
      outcome: nil,
      outcome_body: nil,
      revision: 1,
      expires_at: nil,
      retain_until: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  defp errors(checks) do
    checks
    |> Enum.reject(&elem(&1, 1))
    |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  # Opening an action, attaching its challenge, recording its assertion and
  # recording a receipt widen what a signing home will sign and what a
  # relying home admitted, so each transaction first proves this member
  # still owns its slot on the database's clock
  # (`Arca.ControlPlane.verify_held/1`): a stale owner writes nothing.
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)
end
