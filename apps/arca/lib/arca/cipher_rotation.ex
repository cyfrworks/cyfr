# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CipherRotation do
  @moduledoc """
  The rows a key rotation walks: the sealed columns of the four credential
  tables, read a page at a time and written back only while the ciphertext
  the page carried is still the one in the row.

  This module moves **ciphertext**. Keys, plaintext and the envelope
  vocabulary are `Sanctum.Cipher`'s and never reach here — a facade that
  took or returned a decrypted value would put plaintext below the
  security boundary and into anything that inspects its arguments. What
  crosses is a row's id, the columns its caller rebuilds its AAD from, and
  sealed bytes.

  ## The first argument

  Every function takes `%Cyfr.Actor{}` first and matches `scope:
  :platform` in the head. A rotation retires a key everywhere or nowhere,
  so its walk crosses every athanor by construction; the one authority a
  `Cyfr.Actor` carries for a read that is not scoped to a tenant is the
  platform scope (`Cyfr.Actor.system/0` holds it, and the operator's
  `bin/cyfr eval` runs as the server). An athanor-scoped actor is refused
  with `{:error, :not_platform}` before any query, so walking every
  tenant's sealed rows is not something a tenant's own caller can ask for.

  ## Paging and the compare-and-set

  `page/4` is keyset pagination by `id`: bounded memory whatever the table
  holds, and a run that stops part-way resumes from the last id it saw
  instead of starting over. There is no unpaged read of a credential
  table here — the audit walk (`ciphertext_page/4`) takes the same cursor.

  `swap/5` writes a row's re-sealed columns **only while the ciphertext
  the page read is still in the row's CAS column** — `cas_column/1`, the
  table's primary sealed column. A concurrent legitimate write (a rotated
  webhook secret, a re-sealed vault payload) changes that column, the swap
  then matches no row and answers `:stale`, and the caller counts the row
  as not rotated. A plain update in its place would silently discard that
  write and leave the rotation half-applied with no failing test.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  # Each table: the schema, the CAS column, every sealed column in
  # compare-and-set-first order, and the columns a caller rebuilds the
  # row's AAD from. The CAS column is the table's primary sealed column —
  # the one a legitimate concurrent write to the row's credential must
  # change — and it is also the column `ciphertext_page/4` audits.
  @tables %{
    webhooks: %{
      schema: Arca.Schemas.Webhook,
      cas: :secret_encrypted,
      sealed: [:secret_encrypted, :previous_secret_encrypted],
      binding: [:name, :athanor_id]
    },
    vault_entries: %{
      schema: Arca.Schemas.VaultEntry,
      cas: :sealed_payload,
      sealed: [:sealed_payload],
      binding: [:athanor_id, :provider_hint]
    },
    registry_tokens: %{
      schema: Arca.Schemas.RegistryToken,
      cas: :credential_ciphertext,
      sealed: [:credential_ciphertext],
      binding: [:user_id, :registry, :namespace_slug]
    },
    oauth_provider_credentials: %{
      schema: Arca.Schemas.OauthProviderCredential,
      cas: :payload_ciphertext,
      sealed: [:payload_ciphertext],
      binding: [:athanor_id, :provider]
    }
  }

  # A cursor is `nil` for the first page, or the id the last page ended on.
  # An empty string is neither: it would compare greater than nothing and
  # silently restart the walk, which is a lost resume point looking like a
  # fresh one.
  defguardp is_cursor(cursor) when is_nil(cursor) or (is_binary(cursor) and cursor != "")

  defguardp is_page_limit(limit) when is_integer(limit) and limit > 0

  # A row id and a compare-and-set token both come out of a page row, so
  # neither is ever empty. An empty one would match no row rather than no
  # head, and `swap/5` would report a race that never happened.
  defguardp is_token(token) when is_binary(token) and token != ""

  @typedoc """
  One row of a page: its id, the binding columns merged in flat, and
  `ciphertexts` — every non-null sealed column as `{column, bytes}`, CAS
  column first. The order is the contract: the head of the list is what a
  `swap/5` compares against, so a caller must not sort or re-key it.
  """
  @type row :: %{:id => String.t(), :ciphertexts => [{atom(), binary()}], atom() => term()}

  @type refusal :: {:error, :not_platform | :database_error | {:unknown_table, term()}}

  @doc "The tables this module knows how to walk."
  @spec tables() :: [atom()]
  def tables, do: Map.keys(@tables)

  @doc "The column a `swap/5` on `table` compares against, and the one `ciphertext_page/4` reads."
  @spec cas_column(atom()) :: atom()
  def cas_column(table) when is_map_key(@tables, table), do: @tables[table].cas

  @doc """
  The next page of `table` after `cursor` (`nil` for the first), at most
  `limit` rows, ordered by id.

  An empty list is the end of the table. `{:error, :database_error}` is
  the store failing to answer, which is not the end of anything: the
  caller resumes from `cursor`.

  "No cursor" is spelled `nil` and only `nil`. An empty string would read
  as a cursor and behave as the beginning, which is how a lost resume
  point turns into a silent restart of the walk; it matches no head here.
  """
  @spec page(Cyfr.Actor.t(), atom(), String.t() | nil, pos_integer()) ::
          {:ok, [row()]} | refusal()
  def page(%Cyfr.Actor{scope: :platform}, table, cursor, limit)
      when is_map_key(@tables, table) and is_cursor(cursor) and is_page_limit(limit) do
    spec = @tables[table]

    Arca.Repo.Errors.with_db_rescue("Arca.CipherRotation.page", fn ->
      rows =
        table
        |> load([:id | spec.binding ++ spec.sealed], cursor, limit)
        |> Enum.map(&split_ciphertexts(&1, spec.sealed))

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  def page(%Cyfr.Actor{scope: :platform}, table, cursor, limit)
      when is_cursor(cursor) and is_page_limit(limit),
      do: unknown(table)

  def page(%Cyfr.Actor{scope: scope}, _table, _cursor, _limit) when scope != :platform,
    do: {:error, :not_platform}

  @doc """
  The next page of `table`'s CAS column after `cursor`, as
  `%{id: id, ciphertext: bytes}`.

  The audit reads labels off these bytes without decrypting; the labels
  are the caller's vocabulary, not this module's.
  """
  @spec ciphertext_page(Cyfr.Actor.t(), atom(), String.t() | nil, pos_integer()) ::
          {:ok, [%{id: String.t(), ciphertext: binary()}]} | refusal()
  def ciphertext_page(%Cyfr.Actor{scope: :platform}, table, cursor, limit)
      when is_map_key(@tables, table) and is_cursor(cursor) and is_page_limit(limit) do
    cas = @tables[table].cas

    Arca.Repo.Errors.with_db_rescue("Arca.CipherRotation.ciphertext_page", fn ->
      rows =
        table
        |> load([:id, cas], cursor, limit)
        |> Enum.map(&%{id: &1.id, ciphertext: &1[cas]})

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  def ciphertext_page(%Cyfr.Actor{scope: :platform}, table, cursor, limit)
      when is_cursor(cursor) and is_page_limit(limit),
      do: unknown(table)

  def ciphertext_page(%Cyfr.Actor{scope: scope}, _table, _cursor, _limit) when scope != :platform,
    do: {:error, :not_platform}

  @doc """
  Write `sealed` — a map of sealed column to new bytes — into the row `id`
  names, and stamp `updated_at`.

  The write lands only while the row's CAS column still holds `cas`, the
  bytes the page that produced `sealed` read there. `{:ok, :swapped}` is
  one row written; `{:ok, :stale}` is none, because someone else wrote the
  row in between, and nothing was overwritten. Only the table's own
  sealed columns may be set: anything else is `{:error, :unknown_column}`
  and writes nothing.

  Columns outside `sealed` are untouched. A vault entry's `payload_rev` in
  particular is the material compare-and-set token of `Sanctum.Vault` and
  must not move because an encryption pass rewrote unchanged material.

  The id and the token both come from a `page/4` row, so neither is ever
  empty. An empty one matches no head rather than matching no row: `:stale`
  says a concurrent write beat this one, and an unresolved id answering it
  would report a race that never happened and leave the row unrotated with
  nothing to say so.
  """
  @spec swap(Cyfr.Actor.t(), atom(), String.t(), binary(), %{atom() => binary()}) ::
          {:ok, :swapped | :stale} | {:error, :unknown_column} | refusal()
  def swap(%Cyfr.Actor{scope: :platform}, table, id, cas, sealed)
      when is_map_key(@tables, table) and is_token(id) and is_token(cas) and is_map(sealed) and
             map_size(sealed) > 0 do
    spec = @tables[table]

    if Enum.all?(Map.keys(sealed), &(&1 in spec.sealed)) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      set = Map.to_list(sealed) ++ [updated_at: now]

      Arca.Repo.Errors.with_db_rescue("Arca.CipherRotation.swap", fn ->
        case cas_update(table, id, cas, set) do
          {1, _} -> {:ok, :swapped}
          {0, _} -> {:ok, :stale}
        end
      end)
    else
      {:error, :unknown_column}
    end
  end

  def swap(%Cyfr.Actor{scope: :platform}, table, id, cas, sealed)
      when is_token(id) and is_token(cas) and is_map(sealed) and map_size(sealed) > 0,
      do: unknown(table)

  def swap(%Cyfr.Actor{scope: scope}, _table, _id, _cas, _sealed) when scope != :platform,
    do: {:error, :not_platform}

  # ---- queries ---------------------------------------------------------------

  # arca:unscoped-ok a key rotation walks every athanor's sealed rows — a
  # key an operator is about to retire must stop sealing anything anywhere,
  # so this read crosses tenants by construction. The gate is the caller's
  # platform scope, matched in each public head above; an athanor-scoped
  # actor never reaches here.
  defp load(table, columns, cursor, limit) do
    %{schema: schema, cas: cas} = @tables[table]

    # A null CAS column is a row with nothing sealed in it — a tombstoned
    # vault entry, whose payload was erased. Excluding it in SQL rather
    # than after the fact is what keeps `List.last(page).id` a correct
    # resume cursor: a page filtered in Elixir could end on a row the
    # caller never sees and walk backwards.
    from(r in schema,
      where: not is_nil(field(r, ^cas)),
      order_by: [asc: r.id],
      limit: ^limit,
      select: map(r, ^columns)
    )
    |> after_cursor(cursor)
    |> Arca.Repo.all()
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: where(query, [r], r.id > ^cursor)

  # arca:unscoped-ok one row of a cross-tenant rotation, addressed by its
  # own id; the platform scope matched in `swap/5` is what admits it, and
  # the `where` is the compare-and-set that keeps a concurrent write to
  # the same row from being overwritten.
  defp cas_update(table, id, cas, set) do
    %{schema: schema, cas: cas_column} = @tables[table]

    from(r in schema, where: r.id == ^id and field(r, ^cas_column) == ^cas)
    |> Arca.Repo.update_all(set: set)
  end

  # ---- internal --------------------------------------------------------------

  # Sealed columns leave as an ordered list, CAS column first, with the
  # nulls dropped — a map would re-order them by term and hand the caller a
  # nullable column as its compare-and-set token. The list is never empty:
  # `load/4` excludes the rows whose CAS column is null.
  defp split_ciphertexts(row, sealed) do
    ciphertexts = for col <- sealed, is_binary(row[col]), do: {col, row[col]}

    row |> Map.drop(sealed) |> Map.put(:ciphertexts, ciphertexts)
  end

  defp unknown(table), do: {:error, {:unknown_table, table}}
end
