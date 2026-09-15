# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaBaselineTest do
  @moduledoc """
  The schema on the active adapter is the one the baseline migration
  declares: the same tables, each with the same columns, every `null: false`
  column `NOT NULL`. The expectations are read from the migration's source,
  so a table or column added there is checked without a second list here.

  The athanor is the only tenant column: the tables that carry `athanor_id`
  are exactly `Arca.TenantTables`'s roster, only `memberships` and
  `sessions` may leave it null, and the tables without it are the ones the
  roster names as not athanor-scoped or reached through a parent, the
  athanors themselves, and the server's people and door.
  """

  use ExUnit.Case, async: false

  require Arca.Repo.Errors

  @migration Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__)

  # The retired vocabularies, spelled split so the vocabulary gate does not
  # trip on the assertions that prove they are gone.
  @retired_tables ["orgs", "projects", "conver" <> "sations"]
  @retired_columns ["org" <> "_id", "project" <> "_id", "conver" <> "sation_id"]

  setup_all do
    [path] = Cyfr.Test.SourceTree.files!(@migration)
    {:ok, declared: path |> Cyfr.Test.SourceTree.read() |> declared_tables()}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  test "the live tables are exactly the migration's", %{declared: declared} do
    assert map_size(declared) > 0

    assert Enum.sort(table_names()) == Enum.sort(Map.keys(declared))

    for retired <- @retired_tables, do: refute(Map.has_key?(declared, retired))
  end

  test "every table has exactly the migration's columns, NOT NULL where declared",
       %{declared: declared} do
    for {table, columns} <- declared do
      live = Map.new(columns(table), &{&1.name, &1})

      assert Enum.sort(Map.keys(live)) == Enum.sort(Map.keys(columns)),
             "#{table}: live columns differ from the migration"

      for {name, %{not_null?: true}} <- columns do
        assert live[name].not_null?, "#{table}.#{name} is declared null: false"
      end

      for {name, %{not_null?: false, primary_key?: false}} <- columns do
        refute live[name].not_null?, "#{table}.#{name} is not declared null: false"
      end

      for retired <- @retired_columns, do: refute(Map.has_key?(live, retired))
    end
  end

  test "the tables carrying athanor_id are Arca.TenantTables's roster, NOT NULL but two",
       %{declared: declared} do
    scoped = for {table, %{"athanor_id" => column}} <- declared, into: %{}, do: {table, column}

    assert Enum.sort(Map.keys(scoped)) == Enum.sort(Arca.TenantTables.roster())

    nullable = for {table, %{not_null?: false}} <- scoped, do: table
    assert Enum.sort(nullable) == ["memberships", "sessions"]

    for table <- Map.keys(scoped) do
      athanor = Enum.find(columns(table), &(&1.name == "athanor_id"))
      assert athanor.default == nil, "#{table}.athanor_id must have no default"
    end
  end

  test "a table without athanor_id is documented as such", %{declared: declared} do
    unscoped =
      for {table, columns} <- declared, not Map.has_key?(columns, "athanor_id"), do: table

    documented =
      ["athanors" | Arca.TenantTables.not_athanor_scoped()] ++
        for({table, _fk, _parent} <- Arca.TenantTables.by_parent(), do: table)

    # The server's people and its door exist before any athanor does.
    assert Enum.sort(unscoped -- documented) == [
             "external_identities",
             "server_allowlist",
             "users"
           ]

    assert documented -- unscoped == []
  end

  test "sessions carry no scope; the person's standing is a users + memberships fact" do
    refute "scope" in Enum.map(columns("sessions"), & &1.name)
    user_names = Enum.map(columns("users"), & &1.name)

    for col <- ~w(email email_verified namespace personal_athanor_id status prefs),
        do: assert(col in user_names)

    membership_names = Enum.map(columns("memberships"), & &1.name)
    for col <- ~w(email status added_by), do: assert(col in membership_names)
    refute Enum.find(columns("memberships"), &(&1.name == "user_id")).not_null?
  end

  test "api_keys and webhooks have no scope-type column; vault_entries has no system column" do
    fossil = "scope" <> "_type"
    refute fossil in Enum.map(columns("api_keys"), & &1.name)
    refute fossil in Enum.map(columns("webhooks"), & &1.name)
    refute "system" in Enum.map(columns("vault_entries"), & &1.name)
  end

  test "an execution attempt is fenced and names the runner that attached to it" do
    columns = Map.new(columns("execution_attempts"), &{&1.name, &1})

    assert columns["fence"].not_null?
    refute columns["claimed_by"].not_null?
    assert columns["runner_id"].not_null?
  end

  test "a turn is fenced and pins its catalyst release" do
    columns = Map.new(columns("turns"), &{&1.name, &1})

    assert columns["fence"].not_null?
    refute columns["catalyst_ref"].not_null?
    assert columns["thread_id"].not_null?
  end

  test "threads hold the messages and subscriptions" do
    for table <- ~w(messages thread_subscriptions tool_grants approvals) do
      assert "thread_id" in Enum.map(columns(table), & &1.name), "#{table} lacks thread_id"
    end

    assert Enum.find(columns("messages"), &(&1.name == "thread_id")).not_null?
    assert "turn_seq" in Enum.map(columns("threads"), & &1.name)
  end

  test "an MCP server row has a transport and an epoch, and a url exactly when it is http" do
    columns = Map.new(columns("mcp_servers"), &{&1.name, &1})

    assert columns["transport"].not_null?
    assert columns["epoch"].not_null?
    refute columns["url"].not_null?

    assert :ok = insert_server("stdio", nil)
    assert :ok = insert_server("http", "https://example.test/mcp")

    for {transport, url} <- [{"http", nil}, {"stdio", "https://example.test/mcp"}, {"sse", nil}] do
      assert :refused = insert_server(transport, url),
             "#{transport} with url #{inspect(url)} was accepted"
    end
  end

  # --------------------------------------------------------------------------
  # The migration's declarations

  # `%{table => %{column => %{not_null?:, primary_key?:}}}` from every
  # `create table(...) do ... end` in the migration source.
  defp declared_tables(source) do
    {_ast, tables} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(%{}, fn
        {:create, _, [{:table, _, [name | _]}, [do: body]]} = node, acc ->
          {node, Map.put(acc, Atom.to_string(name), declared_columns(body))}

        node, acc ->
          {node, acc}
      end)

    tables
  end

  defp declared_columns({:__block__, _, statements}), do: declared_columns(statements)

  defp declared_columns(statements) when is_list(statements),
    do: Enum.reduce(statements, %{}, &column/2)

  defp declared_columns(statement), do: declared_columns([statement])

  defp column({:add, _, [name, _type | rest]}, acc) do
    opts = List.first(rest, [])

    Map.put(acc, Atom.to_string(name), %{
      not_null?: Keyword.get(opts, :null) == false,
      primary_key?: Keyword.get(opts, :primary_key, false)
    })
  end

  defp column({:timestamps, _, args}, acc) do
    opts = List.first(args, [])

    for field <- [:inserted_at, :updated_at],
        Keyword.get(opts, field) != false,
        into: acc,
        do: {Atom.to_string(field), %{not_null?: true, primary_key?: false}}
  end

  defp column(_statement, acc), do: acc

  # --------------------------------------------------------------------------
  # Adapter-aware introspection

  defp sqlite?, do: Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.SQLite3

  defp table_names do
    rows =
      if sqlite?() do
        Arca.Repo.query!(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).rows
      else
        Arca.Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        ).rows
      end

    List.flatten(rows) -- ["schema_migrations"]
  end

  defp columns(table) do
    if sqlite?() do
      # cid, name, type, notnull, dflt_value, pk
      Arca.Repo.query!("PRAGMA table_info(#{table})").rows
      |> Enum.map(fn [_cid, name, _type, notnull, default, _pk] ->
        %{name: name, not_null?: notnull == 1, default: default}
      end)
    else
      Arca.Repo.query!(
        """
        SELECT column_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      ).rows
      |> Enum.map(fn [name, nullable, default] ->
        %{name: name, not_null?: nullable == "NO", default: default}
      end)
    end
  end

  # One row inside its own savepoint, so a refused insert leaves the
  # sandbox's transaction usable on Postgres.
  defp insert_server(transport, url) do
    now = NaiveDateTime.utc_now()

    row = %{
      id: "mcp_#{System.unique_integer([:positive])}",
      name: "server-#{System.unique_integer([:positive])}",
      transport: transport,
      url: url,
      config_json: "{}",
      epoch: 1,
      athanor_id: "ath_schema",
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.transaction(fn -> Arca.Repo.insert_all("mcp_servers", [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end
end
