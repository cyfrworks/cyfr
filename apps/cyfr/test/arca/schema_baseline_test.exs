# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaBaselineTest do
  @moduledoc """
  The schema on the active adapter is the one the baseline migration
  declares: the same tables, each with the same columns, every `null: false`
  column `NOT NULL`. The expectations are read from the migration's source,
  so a table or column added there is checked without a second list here.

  The athanor is the only tenant column: the tables that carry `athanor_id`
  are exactly `Arca.TenantTables`'s roster, only `memberships`,
  `sessions` and `decision_logs` may leave it null, and the tables without it are the ones the
  roster names as not athanor-scoped or reached through a parent, the
  athanors themselves, and the server's people and door.

  The cases that exercise a claim — the cell's member slots, its job
  claims, a thread's active turn — are about rows this case made, under
  keys nothing else in the suite uses. A shared, cross-node table is
  measured by its own delta and never by an absolute count, or the case
  would be testing the order the suite happened to run in.
  """

  use ExUnit.Case, async: false

  require Arca.Repo.Errors

  @migration Path.expand("../../../arca/priv/repo/migrations/*_baseline.exs", __DIR__)

  # The retired vocabularies, spelled split so the vocabulary gate does not
  # trip on the assertions that prove they are gone.
  @retired_tables ["orgs", "projects", "conver" <> "sations"]
  @retired_columns ["org" <> "_id", "project" <> "_id", "conver" <> "sation_id"]

  setup_all do
    [path] = Prima.Test.SourceTree.files!(@migration)
    {:ok, declared: path |> Prima.Test.SourceTree.read() |> declared_tables()}
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

  test "the tables carrying athanor_id are Arca.TenantTables's roster, NOT NULL but three",
       %{declared: declared} do
    scoped = for {table, %{"athanor_id" => column}} <- declared, into: %{}, do: {table, column}

    assert Enum.sort(Map.keys(scoped)) == Enum.sort(Arca.TenantTables.roster())

    nullable = for {table, %{not_null?: false}} <- scoped, do: table
    assert Enum.sort(nullable) == ["decision_logs", "memberships", "sessions"]

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

  test "a person and an estate carry a positive standing generation, 1 at birth" do
    for table <- ~w(users athanors) do
      column = Enum.find(columns(table), &(&1.name == "security_generation"))
      assert column.not_null?, "#{table}.security_generation is NOT NULL"
      assert to_string(column.default) =~ "1", "#{table}.security_generation defaults to 1"
    end

    for schema <- [Arca.Schemas.User, Arca.Schemas.Athanor] do
      assert :security_generation in schema.__schema__(:fields)
    end

    now = NaiveDateTime.utc_now()

    estate = fn generation ->
      %{
        id: "ath_gen_#{System.unique_integer([:positive])}",
        kind: "group",
        name: "Generation",
        slug: "generation-#{System.unique_integer([:positive])}",
        created_by: "usr_schema",
        security_generation: generation,
        created_at: now,
        updated_at: now
      }
    end

    person = fn generation ->
      %{
        id: "usr_gen_#{System.unique_integer([:positive])}",
        provider: "github",
        security_generation: generation,
        first_seen_at: now,
        last_seen_at: now,
        created_at: now,
        updated_at: now
      }
    end

    assert :ok = insert_row("athanors", estate.(1))
    assert :ok = insert_row("users", person.(1))

    for generation <- [0, -1] do
      assert :refused = insert_row("athanors", estate.(generation))
      assert :refused = insert_row("users", person.(generation))
    end
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
    assert columns["boot_id"].not_null?
    refute columns["service_id"].not_null?
  end

  test "an execution attempt stores the estate standing it was admitted under, with no default" do
    column = Enum.find(columns("execution_attempts"), &(&1.name == "athanor_generation"))
    assert column.not_null?, "execution_attempts.athanor_generation is NOT NULL"
    assert is_nil(column.default), "execution_attempts.athanor_generation has no default"
    assert :athanor_generation in Arca.Schemas.ExecutionAttempt.__schema__(:fields)
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

  test "an MCP server row has a transport, an epoch and a creator, and a url exactly when it is http" do
    columns = Map.new(columns("mcp_servers"), &{&1.name, &1})

    assert columns["transport"].not_null?
    assert columns["epoch"].not_null?
    assert columns["created_by"].not_null?
    refute columns["url"].not_null?

    assert :ok = insert_server("stdio", nil)
    assert :ok = insert_server("http", "https://example.test/mcp")

    for {transport, url} <- [{"http", nil}, {"stdio", "https://example.test/mcp"}, {"sse", nil}] do
      assert :refused = insert_server(transport, url),
             "#{transport} with url #{inspect(url)} was accepted"
    end
  end

  test "a storage unit is one pointer per estate, root and key, published only by a commit" do
    columns = Map.new(columns("storage_units"), &{&1.name, &1})

    for column <- ~w(root unit_key state), do: assert(columns[column].not_null?)

    for column <- ~w(current_revision draft_writer_token),
        do: refute(columns[column].not_null?)

    # A pointer row says what is published and nothing about what was
    # published: a release's activation identity is the `components`
    # row's, and the bytes' identity the journal's.
    refute Map.has_key?(columns, "release_digest")

    unit = unit_row("components", "reagents/local/hello/1.0.0")
    assert :ok = insert_row("storage_units", unit)

    # The same key under the same root is the same unit; another root or
    # another estate is not.
    assert :refused = insert_row("storage_units", %{unit | id: "su_twice"})
    assert :ok = insert_row("storage_units", %{unit | id: "su_aqua", root: "aqua"})
    assert :ok = insert_row("storage_units", %{unit | id: "su_theirs", athanor_id: "ath_theirs"})
  end

  test "a storage commit is appended per revision and names its unit within the estate" do
    columns = Map.new(columns("storage_commits"), &{&1.name, &1})

    for column <- ~w(storage_unit_id new_revision content_identity commit_identity committed_at),
        do: assert(columns[column].not_null?)

    refute columns["prior_revision"].not_null?

    unit = unit_row("aqua", "roles/scribe.md")
    assert :ok = insert_row("storage_units", unit)

    # Append-only: every commit of the unit is one more row.
    assert :ok = insert_row("storage_commits", commit_row(unit, nil, "rev_1"))
    assert :ok = insert_row("storage_commits", commit_row(unit, "rev_1", "rev_2"))

    # A journal row for a unit the estate does not hold is refused: the
    # composite key ties it to its unit's row, never across estates.
    assert :refused = insert_row("storage_commits", commit_row(%{unit | id: "su_none"}, nil, "r"))

    assert :refused =
             insert_row(
               "storage_commits",
               commit_row(%{unit | athanor_id: "ath_theirs"}, nil, "r")
             )
  end

  test "one provisioning claim per estate, fenced and leased, settled by an outcome" do
    columns = Map.new(columns("provisioning_claims"), &{&1.name, &1})

    for column <- ~w(owner attempt entry_kind lease_until fence),
        do: assert(columns[column].not_null?)

    for column <- ~w(outcome outcome_detail), do: refute(columns[column].not_null?)

    claim = claim_row("ath_claimed")
    assert :ok = insert_row("provisioning_claims", claim)

    # A second claim on the estate is refused whoever takes it: the row is
    # taken over by compare-and-set, never duplicated.
    assert :refused =
             insert_row("provisioning_claims", %{
               claim
               | id: "pc_twice",
                 owner: "boot_2",
                 fence: 2
             })

    assert :ok =
             insert_row("provisioning_claims", %{claim | id: "pc_other", athanor_id: "ath_other"})
  end

  test "a storage write intent names its attempt and fence and belongs to an execution of its estate" do
    columns = Map.new(columns("storage_write_intents"), &{&1.name, &1})

    for column <- ~w(execution_id attempt fence runner op path state inserted_at),
        do: assert(columns[column].not_null?)

    for column <- ~w(bytes reason settled_at), do: refute(columns[column].not_null?)

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_schema_#{System.unique_integer([:positive])}",
          reference: "catalyst:local.schema:0.1.0",
          user_id: "usr_schema",
          athanor_id: "ath_schema",
          component_type: "catalyst",
          input: "{}"
        },
        Arca.Test.Actor.standing("ath_schema")
      )

    intent = %{
      id: "swi_#{System.unique_integer([:positive])}",
      athanor_id: "ath_schema",
      execution_id: execution.id,
      attempt: attempt.attempt,
      fence: 1,
      runner: "runner_schema",
      op: "put",
      path: "data/a.txt",
      state: "pending",
      inserted_at: NaiveDateTime.utc_now()
    }

    # One attempt writes one path as often as it likes: each write is a row.
    assert :ok = insert_row("storage_write_intents", intent)
    assert :ok = insert_row("storage_write_intents", %{intent | id: "swi_again"})

    # An intent for an execution the estate does not hold is refused.
    assert :refused =
             insert_row("storage_write_intents", %{
               intent
               | id: "swi_none",
                 execution_id: "exec_0"
             })

    assert :refused =
             insert_row("storage_write_intents", %{
               intent
               | id: "swi_theirs",
                 athanor_id: "ath_theirs"
             })
  end

  test "the storage-unit, claim and write-intent schemas carry exactly their tables' columns",
       %{declared: declared} do
    for schema <- [
          Arca.Schemas.StorageUnit,
          Arca.Schemas.StorageCommit,
          Arca.Schemas.ProvisioningClaim,
          Arca.Schemas.StorageWriteIntent,
          Arca.Schemas.CellLease,
          Arca.Schemas.JobClaim,
          Arca.Schemas.RateWindow
        ] do
      table = schema.__schema__(:source)
      fields = schema.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert fields == Enum.sort(Map.keys(declared[table])),
             "#{inspect(schema)} drifts from the #{table} table"
    end
  end

  test "the recorded fingerprint is the digest of the migration sources on disk" do
    digest =
      @migration
      |> Prima.Test.SourceTree.files!()
      |> Enum.sort()
      |> Enum.map_join(fn path ->
        Path.basename(path) <> "\n" <> Prima.Test.SourceTree.read(path)
      end)
      |> Prima.Digest.sha256_hex()

    # The baseline is edited in place and records this digest as it builds
    # the schema, so every edit of it — this slice's columns included —
    # leaves a database built from the version before carrying a
    # fingerprint that is no longer this release's.
    # `Arca.SchemaFingerprintTest` covers the refusal that follows; this
    # covers what makes the refusal fire at all.
    assert Arca.SchemaFingerprint.current() == digest
    assert {:ok, ^digest} = Arca.ServerMetaStorage.get(Arca.SchemaFingerprint.key())
  end

  test "a cell slot is one member's while its lease stands, and a takeover fences its predecessor" do
    columns = Map.new(columns("cell_leases"), &{&1.name, &1})

    for column <- ~w(owner generation fence lease_until taken_at),
        do: assert(columns[column].not_null?)

    node = "cell-#{System.unique_integer([:positive])}@test"
    assert :ok = insert_row("cell_leases", lease_row(node, "boot_a", 60))

    # The slot is the node's, not a boot's: a second row for the same node
    # is refused, so a member takes its predecessor's row over instead of
    # opening a second one beside it.
    assert :refused = insert_row("cell_leases", lease_row(node, "boot_b", 60))

    # A live lease is nobody else's to take.
    assert took_over(node, "boot_b") == 0
    assert %{owner: "boot_a", generation: 1, fence: 1} = lease(node)

    expire(node)
    assert took_over(node, "boot_b") == 1

    # The take raises both: the generation the successor stamps outward,
    # and the row's write token.
    assert %{owner: "boot_b", generation: 2, fence: 2} = lease(node)

    # The predecessor still believes it holds, and writes nothing: its
    # renew names the fence it read.
    assert renewed(node, "boot_a", 1) == 0
    assert renewed(node, "boot_b", 2) == 1
    assert %{owner: "boot_b", generation: 2, fence: 3} = lease(node)
  end

  test "a job claim is one per kind and key, taken over and never duplicated" do
    columns = Map.new(columns("job_claims"), &{&1.name, &1})

    for column <- ~w(kind key owner lease_until fence), do: assert(columns[column].not_null?)
    refute columns["detail"].not_null?

    key = "svc-#{System.unique_integer([:positive])}"
    claim = job_claim_row("worker_watch", key)
    assert :ok = insert_row("job_claims", claim)

    # One claim per job, whoever takes it.
    assert :refused =
             insert_row("job_claims", %{claim | id: "jcl_twice", owner: "boot_b", fence: 2})

    # The same key under another kind is another job.
    assert :ok = insert_row("job_claims", %{claim | id: "jcl_other", kind: "seed_release"})

    assert "worker_watch" in Arca.Schemas.JobClaim.kinds()
  end

  test "a rate window is one row per athanor and bucket, and is the athanor's to erase" do
    columns = Map.new(columns("rate_windows"), &{&1.name, &1})

    for column <- ~w(athanor_id bucket window_start window_ms count prior_count),
        do: assert(columns[column].not_null?)

    bucket = "reagents/local/rate/#{System.unique_integer([:positive])}"
    window = rate_window_row("ath_schema", bucket)
    assert :ok = insert_row("rate_windows", window)
    assert :refused = insert_row("rate_windows", %{window | id: "rw_twice"})

    # The bucket is the athanor's: another estate's window of the same name
    # is a different row, and the roster says whose it is to delete.
    assert :ok =
             insert_row("rate_windows", %{window | id: "rw_theirs", athanor_id: "ath_theirs"})

    assert "rate_windows" in Arca.TenantTables.roster()
  end

  test "a thread claim lands once, and only on the consumed sequence the claimant read" do
    thread = thread_row()
    assert :ok = insert_row("threads", thread)

    # The claim names the turn AND the sequence it read.
    assert claimed(thread.id, "trn_first", 0) == 1
    assert %{active_turn_id: "trn_first", turn_seq: 0} = thread_state(thread.id)

    # A second member reading the same row claims nothing: the thread is
    # held, and holding it is not something a peer takes over.
    assert claimed(thread.id, "trn_second", 0) == 0

    assert released(thread.id, "trn_first") == 1
    assert %{active_turn_id: nil} = thread_state(thread.id)

    # Another member accepted the next message while this one was deciding:
    # the sequence moved, so the claim it had prepared writes nothing.
    consume(thread.id, 1)
    assert claimed(thread.id, "trn_stale", 0) == 0
    assert %{active_turn_id: nil, turn_seq: 1} = thread_state(thread.id)

    assert claimed(thread.id, "trn_fresh", 1) == 1
    assert %{active_turn_id: "trn_fresh", turn_seq: 1} = thread_state(thread.id)
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

  defp insert_server(transport, url) do
    now = NaiveDateTime.utc_now()

    insert_row("mcp_servers", %{
      id: "mcp_#{System.unique_integer([:positive])}",
      name: "server-#{System.unique_integer([:positive])}",
      transport: transport,
      url: url,
      config_json: "{}",
      epoch: 1,
      created_by: "usr_schema",
      athanor_id: "ath_schema",
      inserted_at: now,
      updated_at: now
    })
  end

  defp unit_row(root, unit_key) do
    now = NaiveDateTime.utc_now()

    %{
      id: "su_#{System.unique_integer([:positive])}",
      athanor_id: "ath_schema",
      root: root,
      unit_key: unit_key,
      state: "draft",
      inserted_at: now,
      updated_at: now
    }
  end

  defp commit_row(unit, prior_revision, new_revision) do
    %{
      id: "sc_#{System.unique_integer([:positive])}",
      athanor_id: unit.athanor_id,
      storage_unit_id: unit.id,
      prior_revision: prior_revision,
      new_revision: new_revision,
      content_identity: "sha256:#{new_revision}",
      commit_identity: "usr_schema",
      committed_at: NaiveDateTime.utc_now()
    }
  end

  defp claim_row(athanor_id) do
    now = NaiveDateTime.utc_now()

    %{
      id: "pc_#{System.unique_integer([:positive])}",
      athanor_id: athanor_id,
      owner: "boot_1",
      attempt: "att_1",
      entry_kind: "first_need",
      lease_until: NaiveDateTime.add(now, 60, :second),
      fence: 1,
      inserted_at: now,
      updated_at: now
    }
  end

  defp lease_row(node, owner, lease_seconds) do
    now = NaiveDateTime.utc_now()

    %{
      node: node,
      owner: owner,
      generation: 1,
      fence: 1,
      lease_until: NaiveDateTime.add(now, lease_seconds, :second),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp lease(node) do
    [[owner, generation, fence]] =
      query("SELECT owner, generation, fence FROM cell_leases WHERE node = ?", [node]).rows

    %{owner: owner, generation: generation, fence: fence}
  end

  defp expire(node) do
    past = NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)
    query("UPDATE cell_leases SET lease_until = ? WHERE node = ?", [past, node])
  end

  # The take: only past the lease, and it raises both numbers at once.
  defp took_over(node, owner) do
    now = NaiveDateTime.utc_now()

    query(
      """
      UPDATE cell_leases
         SET owner = ?, generation = generation + 1, fence = fence + 1,
             lease_until = ?, taken_at = ?, updated_at = ?
       WHERE node = ? AND lease_until <= ?
      """,
      [owner, NaiveDateTime.add(now, 60, :second), now, now, node, now]
    ).num_rows
  end

  # The renew: the fence the caller read is what admits it.
  defp renewed(node, owner, fence) do
    now = NaiveDateTime.utc_now()

    query(
      """
      UPDATE cell_leases
         SET lease_until = ?, fence = fence + 1, updated_at = ?
       WHERE node = ? AND owner = ? AND fence = ?
      """,
      [NaiveDateTime.add(now, 60, :second), now, node, owner, fence]
    ).num_rows
  end

  defp job_claim_row(kind, key) do
    now = NaiveDateTime.utc_now()

    %{
      id: "jcl_#{System.unique_integer([:positive])}",
      kind: kind,
      key: key,
      owner: "boot_a",
      lease_until: NaiveDateTime.add(now, 60, :second),
      fence: 1,
      inserted_at: now,
      updated_at: now
    }
  end

  defp rate_window_row(athanor_id, bucket) do
    now = NaiveDateTime.utc_now()

    %{
      id: "rw_#{System.unique_integer([:positive])}",
      athanor_id: athanor_id,
      bucket: bucket,
      window_start: now,
      window_ms: 60_000,
      count: 1,
      prior_count: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  defp thread_row do
    now = NaiveDateTime.utc_now()

    %{
      id: "thr_#{System.unique_integer([:positive])}",
      athanor_id: "ath_schema",
      title: "Claimed",
      created_by: "usr_schema",
      turn_seq: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  defp thread_state(thread_id) do
    [[active, seq]] =
      query("SELECT active_turn_id, turn_seq FROM threads WHERE id = ?", [thread_id]).rows

    %{active_turn_id: active, turn_seq: seq}
  end

  # The thread claim: one statement naming the turn and the consumed
  # sequence the claimant read.
  defp claimed(thread_id, turn_id, expected_seq) do
    query(
      """
      UPDATE threads SET active_turn_id = ?
       WHERE id = ? AND athanor_id = ? AND active_turn_id IS NULL AND turn_seq = ?
      """,
      [turn_id, thread_id, "ath_schema", expected_seq]
    ).num_rows
  end

  defp released(thread_id, turn_id) do
    query(
      "UPDATE threads SET active_turn_id = NULL WHERE id = ? AND active_turn_id = ?",
      [thread_id, turn_id]
    ).num_rows
  end

  defp consume(thread_id, seq) do
    query("UPDATE threads SET turn_seq = ? WHERE id = ?", [seq, thread_id])
  end

  # One statement in the dialect this build speaks: `?` placeholders on
  # SQLite, `$n` on Postgres.
  defp query(sql, params) do
    sql =
      if sqlite?() do
        sql
      else
        params
        |> Enum.with_index(1)
        |> Enum.reduce(sql, fn {_param, n}, acc ->
          String.replace(acc, "?", "$#{n}", global: false)
        end)
      end

    Arca.Repo.query!(sql, params)
  end

  # One row inside its own savepoint, so a refused insert leaves the
  # sandbox's transaction usable on Postgres.
  defp insert_row(table, row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(table, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end
end
