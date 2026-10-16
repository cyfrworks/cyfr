# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PersonSeals do
  @moduledoc """
  A person's seal at this home (`Arca.Schemas.PersonSeal`): one row beside
  the person's `users` row, never a column of it, so no read of the person
  (`Arca.Users`, projected whole by `Arca.Data`) carries the seal.
  `Sanctum.Seal` is its one caller, and decides who may read and write it;
  this store holds the row to its person.

  ## Who reads and writes

  Every function takes the actor first, and only the person's own actor
  (one whose `user_id` is theirs) reads or writes their row: no other
  person's actor and not the platform's. Refusals are `:not_found`,
  `:cross_tenant`, `:already_set` (a first choice when one is set),
  `:not_set` (a change when none is), `{:invalid, errors}`, `:not_owner`
  (a member that no longer owns its slot) and `:database_error`. Rows are
  plain maps (`Arca.Data`).

  The row is written once by the person's first choice (`choose/3`) and
  replaced after that only by a change (`change/4`), whose `also:` closure
  runs first in the same transaction: the caller consumes the change's
  fresh confirmation there, so the row and the proof commit together or
  not at all. Both writes stamp `set_at` on the database's clock. The row
  goes with the person's `users` row (its foreign key deletes it).
  """

  import Ecto.Query

  alias Arca.Schemas.PersonSeal

  # The longest words and glyph a row holds, in bytes; `Sanctum.Seal`
  # decides which words and glyphs a seal is made of.
  @text_bytes 64
  @glyph_bytes 16

  @typedoc "A person's seal row, as a plain map: `user_id`, `text`, `glyph` and `set_at`."
  @type row :: map()

  @typedoc "What a seal is written with: its words and an optional glyph."
  @type attrs :: %{required(:text) => String.t(), optional(:glyph) => String.t() | nil}

  @doc "The seal of the person `user_id`, read by their own actor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, user_id) when is_binary(user_id) and user_id != "" do
    with :ok <- own(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonSeals.get", fn ->
        found(Arca.Repo.one(from(s in PersonSeal, where: s.user_id == ^user_id)))
      end)
      |> Arca.Data.project()
    end
  end

  def get(%Prima.Actor{}, _user_id), do: {:error, :not_found}

  @doc """
  Write the first seal of the person `user_id`, by their own actor. Written
  once: a person who already has one is `{:error, :already_set}`, so of two
  first choices made at once one is written and the other refused. Runs in
  its own locking transaction and proves this member still owns its slot
  first.
  """
  @spec choose(Prima.Actor.t(), String.t(), attrs()) ::
          {:ok, row()}
          | {:error,
             :already_set | :cross_tenant | :not_owner | :database_error | {:invalid, map()}}
  def choose(%Prima.Actor{} = actor, user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with :ok <- own(actor, user_id),
         {:ok, fields} <- build(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonSeals.choose", fn ->
        fenced(fn -> insert(user_id, fields) end)
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Replace the seal of the person `user_id`, by their own actor. `opts[:also]`
  (a zero-arity closure answering `:ok` or `{:error, reason}`) runs first,
  inside the transaction, before the row is written: the caller consumes
  the change's confirmation there, and its refusal rolls the change back.
  A person with no seal yet is `{:error, :not_set}`: a first seal is a
  choice, never a change.
  """
  @spec change(Prima.Actor.t(), String.t(), attrs(), keyword()) ::
          {:ok, row()}
          | {:error,
             :not_set
             | :cross_tenant
             | :not_owner
             | :database_error
             | {:invalid, map()}
             | term()}
  def change(%Prima.Actor{} = actor, user_id, attrs, opts \\ [])
      when is_binary(user_id) and is_map(attrs) and is_list(opts) do
    also = Keyword.get(opts, :also, fn -> :ok end)

    with :ok <- own(actor, user_id),
         {:ok, fields} <- build(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonSeals.change", fn ->
        fenced(fn ->
          with :ok <- also.(), do: replace(user_id, fields)
        end)
      end)
      |> Arca.Data.project()
    end
  end

  # ---- internals -------------------------------------------------------------

  defp own(%Prima.Actor{scope: :platform}, _user_id), do: {:error, :cross_tenant}

  defp own(%Prima.Actor{user_id: user_id}, user_id) when is_binary(user_id) and user_id != "",
    do: :ok

  defp own(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  defp insert(user_id, fields) do
    row = Map.merge(fields, %{user_id: user_id, set_at: Arca.ServerMetaStorage.now!()})

    case Arca.Repo.insert_all(PersonSeal, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Arca.Repo.get!(PersonSeal, user_id)}
      {0, _} -> {:error, :already_set}
    end
  end

  defp replace(user_id, fields) do
    set = Map.to_list(Map.put(fields, :set_at, Arca.ServerMetaStorage.now!()))

    case Arca.Repo.update_all(from(s in PersonSeal, where: s.user_id == ^user_id), set: set) do
      {1, _} -> {:ok, Arca.Repo.get!(PersonSeal, user_id)}
      {0, _} -> {:error, :not_set}
    end
  end

  defp build(attrs) do
    text = Map.get(attrs, :text)
    glyph = Map.get(attrs, :glyph)

    errors =
      []
      |> check(:text, is_binary(text) and text != "" and byte_size(text) <= @text_bytes)
      |> check(
        :glyph,
        is_nil(glyph) or (is_binary(glyph) and glyph != "" and byte_size(glyph) <= @glyph_bytes)
      )
      |> check(:attrs, Map.keys(attrs) -- [:text, :glyph] == [])

    if errors == [],
      do: {:ok, %{text: text, glyph: glyph}},
      else: {:error, {:invalid, Map.new(errors)}}
  end

  defp check(errors, _field, true), do: errors
  defp check(errors, field, false), do: [{field, ["is malformed"]} | errors]

  defp found(nil), do: {:error, :not_found}
  defp found(%PersonSeal{} = row), do: {:ok, row}

  # A write of a person's row: its transaction first proves this member
  # still owns its slot on the database's clock
  # (`Arca.ControlPlane.verify_held/1`), so a stale owner writes nothing.
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
