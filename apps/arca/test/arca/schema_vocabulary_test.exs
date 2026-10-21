# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaVocabularyTest do
  @moduledoc """
  A status column holds only its owner's vocabulary, and the database
  itself refuses anything else.

  The baseline spells each vocabulary as a literal CHECK, so the migration
  stays the frozen text its fingerprint hashes; the owning module is where
  the code reads the set. This reads each CHECK back from the live
  catalog (`sqlite_master`, `pg_constraint`) and holds it equal to its
  owner's set, so the two cannot drift apart unseen. A constraint the
  catalog does not answer for fails the case: an empty read is never a
  match.

  Each column is then written by direct SQL, past every changeset: every
  value of the vocabulary lands, `"bogus"` is refused by the named
  constraint and not by some other rule of an incomplete row, and a
  nullable column still takes NULL. The schedule's missed-run columns are
  held the same way, NULL and zero limits among the refused rows, and so
  is a pairing invitation's confirmer, whose kind and id are set together
  or not at all.
  """

  use ExUnit.Case, async: false

  import Arca.Test.Adapter, only: [sqlite?: 0]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])
    {:ok, n: n, athanor: "ath_vocab_#{n}"}
  end

  # {table, constraint, column, the owner's set}
  defp vocabularies do
    [
      {"executions", "executions_status_known", "status", Prima.ExecutionState.statuses()},
      {"execution_attempts", "execution_attempts_state_known", "state",
       Prima.ExecutionState.attempt_states()},
      {"execution_attempts", "execution_attempts_outcome_known", "outcome",
       Prima.ExecutionState.outcomes()},
      {"turns", "turns_status_known", "status", Prima.TurnState.statuses()},
      {"schedule_occurrences", "schedule_occurrences_state_known", "state",
       Arca.ScheduleOccurrences.states()},
      {"profiles", "profiles_status_known", "status", Arca.StatusTransitions.statuses(:profiles)},
      {"vault_entries", "vault_entries_status_known", "status",
       Arca.StatusTransitions.statuses(:credentials)},
      {"instance_entries", "instance_entries_status_known", "status",
       Arca.StatusTransitions.statuses(:credentials)},
      # `Arca.PairingInvitations` writes the kind of the confirmer it reads
      # from the consumed confirmation: a passkey or a paired device.
      {"pairing_invitations", "pairing_invitations_confirmer_kind_known", "confirmer_kind",
       ~w(passkey device)},
      {"consumer_receipts", "consumer_receipts_outcome_known", "outcome",
       Arca.ConsumerReceipts.outcomes()},
      # A declared restore suspends an active client or passkey
      # (`Arca.SecurityTransitions.restore/1`) until its person re-enables it.
      {"paired_clients", "paired_clients_standing_known", "standing",
       Arca.Schemas.PairedClient.standings()},
      {"passkeys", "passkeys_state_known", "state", Arca.Schemas.Passkey.states()},
      # `Arca.CliSignIns` approves or cancels a command line's pending
      # sign-in, and nothing leaves either.
      {"cli_sign_ins", "cli_sign_ins_state_known", "state", Arca.Schemas.CliSignIn.states()}
    ]
  end

  describe "each status CHECK in the catalog" do
    test "is its owner's set, exactly" do
      for {table, constraint, column, owned} <- vocabularies() do
        {checked_column, values} = check!(table, constraint)

        assert checked_column == column, "#{constraint} constrains #{checked_column}"
        assert values == Enum.uniq(values), "#{constraint} lists a value twice"

        assert Enum.sort(values) == Enum.sort(owned),
               "#{constraint} lists #{inspect(values)}; its owner holds #{inspect(owned)}"
      end
    end

    test "names the sets the schemas validate with" do
      assert Arca.Schemas.Execution.statuses() == Prima.ExecutionState.statuses()
      assert Arca.Execution.statuses() == Prima.ExecutionState.statuses()

      assert Arca.Schemas.InstanceEntry.statuses() ==
               Arca.StatusTransitions.statuses(:credentials)

      assert Arca.Schemas.Profile.statuses() == Arca.StatusTransitions.statuses(:profiles)
    end
  end

  describe "a direct write of a status" do
    test "lands every value of an execution's vocabulary and refuses any other", ctx do
      for status <- ~w(running paused completed failed cancelled) do
        assert {1, _} = insert!("executions", execution(ctx, status))
      end

      refused!("executions", execution(ctx, "bogus"), "executions_status_known")
    end

    test "lands every attempt state and outcome, a NULL outcome among them, and refuses any other",
         ctx do
      execution_id = execution_row!(ctx)

      for state <- ~w(running paused completed failed cancelled lapsed) do
        assert {1, _} = insert!("execution_attempts", attempt(ctx, execution_id, state, nil))
      end

      for outcome <- ~w(ok error result_lost cancelled uncertain) do
        assert {1, _} =
                 insert!("execution_attempts", attempt(ctx, execution_id, "completed", outcome))
      end

      refused!(
        "execution_attempts",
        attempt(ctx, execution_id, "bogus", nil),
        "execution_attempts_state_known"
      )

      refused!(
        "execution_attempts",
        attempt(ctx, execution_id, "completed", "bogus"),
        "execution_attempts_outcome_known"
      )
    end

    test "lands every turn status and refuses any other", ctx do
      thread_id = thread_row!(ctx)

      for status <- ~w(accepted running paused completed failed cancelled uncertain) do
        assert {1, _} = insert!("turns", turn(ctx, thread_id, status))
      end

      refused!("turns", turn(ctx, thread_id, "bogus"), "turns_status_known")
    end

    test "lands every occurrence state and refuses any other", ctx do
      schedule_id = schedule_row!(ctx)

      for state <- ~w(claimed started completed failed uncertain) do
        assert {1, _} = insert!("schedule_occurrences", occurrence(ctx, schedule_id, state))
      end

      refused!(
        "schedule_occurrences",
        occurrence(ctx, schedule_id, "bogus"),
        "schedule_occurrences_state_known"
      )
    end

    test "lands every profile status and refuses any other, the credentials' among them", ctx do
      for status <- ~w(active needs_consent revoked) do
        assert {1, _} = insert!("profiles", profile(ctx, status))
      end

      for status <- ~w(bogus needs_reauth tombstoned) do
        refused!("profiles", profile(ctx, status), "profiles_status_known")
      end
    end

    test "lands every command-line sign-in state and refuses any other" do
      for state <- ~w(pending approved cancelled) do
        assert {1, _} = insert!("cli_sign_ins", cli_sign_in(state))
      end

      refused!("cli_sign_ins", cli_sign_in("bogus"), "cli_sign_ins_state_known")
    end

    test "lands every receipt outcome and refuses any other", ctx do
      for outcome <- ~w(applied superseded conflict refused) do
        assert {1, _} = insert!("consumer_receipts", receipt(ctx, outcome))
      end

      refused!("consumer_receipts", receipt(ctx, "bogus"), "consumer_receipts_outcome_known")
    end

    test "lands every credential status in both stores and refuses any other", ctx do
      for status <- ~w(active needs_reauth revoked tombstoned) do
        assert {1, _} = insert!("vault_entries", vault_entry(ctx, status))
        assert {1, _} = insert!("instance_entries", instance_entry(ctx, status))
      end

      for status <- ~w(bogus needs_consent) do
        refused!("vault_entries", vault_entry(ctx, status), "vault_entries_status_known")
        refused!("instance_entries", instance_entry(ctx, status), "instance_entries_status_known")
      end
    end
  end

  describe "a pairing invitation's confirmer" do
    test "lands every kind with its id, or neither, and refuses another kind or one without the other",
         ctx do
      assert {1, _} = insert!("pairing_invitations", invitation(ctx, nil, nil))

      for kind <- ~w(passkey device) do
        assert {1, _} = insert!("pairing_invitations", invitation(ctx, kind, id("cfm")))
      end

      refused!(
        "pairing_invitations",
        invitation(ctx, "bogus", id("cfm")),
        "pairing_invitations_confirmer_kind_known"
      )

      refused!(
        "pairing_invitations",
        invitation(ctx, "passkey", nil),
        "pairing_invitations_confirmer_whole"
      )

      refused!(
        "pairing_invitations",
        invitation(ctx, nil, id("cfm")),
        "pairing_invitations_confirmer_whole"
      )
    end
  end

  describe "a person's recovery from a declared restore" do
    test "is open exactly while it has no closing time, and a text false is refused" do
      user = id("usr")

      {1, _} =
        insert!("users", %{
          id: user,
          provider: "github",
          email: "#{user}@example.com",
          first_seen_at: now(),
          last_seen_at: now(),
          created_at: now(),
          updated_at: now()
        })

      # Written through the typed schema, as `Arca.SecurityTransitions` writes.
      row = fn open, closed_at ->
        %{
          restore_id: id("rst"),
          user_id: user,
          open: open,
          closed_at: closed_at && DateTime.utc_now()
        }
      end

      table = Arca.Schemas.RestorePerson
      assert {1, _} = insert!(table, row.(true, nil))
      assert {1, _} = insert!(table, row.(false, :closed))
      refused!(table, row.(true, :closed), "restore_people_open_until_closed")
      refused!(table, row.(false, nil), "restore_people_open_until_closed")

      # SQLite stores an untyped `false` as the text 'false', which the
      # CHECK refuses: every write goes through `Arca.Schemas.RestorePerson`.
      if sqlite?() do
        message =
          try do
            Arca.Repo.query!(
              "INSERT INTO restore_people (restore_id, user_id, open, closed_at) " <>
                "VALUES (?1, ?2, 'false', ?3)",
              [id("rst"), user, now()]
            )

            nil
          rescue
            error -> Exception.message(error)
          end

        assert message =~ "restore_people_open_until_closed"
      end
    end
  end

  describe "a schedule's missed-run columns" do
    test "default to skip with no limit and no episode", ctx do
      {1, [row]} =
        Arca.Repo.insert_all("cron_schedules", [schedule(ctx, %{})],
          returning: [:missed_runs, :catch_up_limit, :catch_up_until, :catch_up_left]
        )

      assert row == %{
               missed_runs: "skip",
               catch_up_limit: nil,
               catch_up_until: nil,
               catch_up_left: 0
             }
    end

    test "hold a catch-up limit of 1 to 24 under catch_up and none under skip", ctx do
      for limit <- [1, 24] do
        assert {1, _} =
                 insert!(
                   "cron_schedules",
                   schedule(ctx, %{missed_runs: "catch_up", catch_up_limit: limit})
                 )
      end

      assert {1, _} = insert!("cron_schedules", schedule(ctx, %{missed_runs: "skip"}))

      assert check!("cron_schedules", "cron_schedules_missed_runs_known") ==
               {"missed_runs", ["skip", "catch_up"]}

      # An unknown policy breaks the limit's rule as well; either adapter
      # may name either.
      refused!("cron_schedules", schedule(ctx, %{missed_runs: "bogus"}), [
        "cron_schedules_missed_runs_known",
        "cron_schedules_catch_up_limit_declared"
      ])

      for limit <- [nil, 0, -1, 25] do
        refused!(
          "cron_schedules",
          schedule(ctx, %{missed_runs: "catch_up", catch_up_limit: limit}),
          "cron_schedules_catch_up_limit_declared"
        )
      end

      for limit <- [0, 1] do
        refused!(
          "cron_schedules",
          schedule(ctx, %{missed_runs: "skip", catch_up_limit: limit}),
          "cron_schedules_catch_up_limit_declared"
        )
      end
    end

    test "hold an episode's work only under catch_up, within the limit's range and with its cursor",
         ctx do
      until = NaiveDateTime.utc_now()
      catch_up = %{missed_runs: "catch_up", catch_up_limit: 3}

      for episode <- [
            %{catch_up_left: 3, catch_up_until: until},
            %{catch_up_left: 0, catch_up_until: until},
            %{catch_up_left: 0, catch_up_until: nil}
          ] do
        assert {1, _} = insert!("cron_schedules", schedule(ctx, Map.merge(catch_up, episode)))
      end

      assert {1, _} =
               insert!(
                 "cron_schedules",
                 schedule(ctx, %{missed_runs: "skip", catch_up_until: until})
               )

      for row <- [
            Map.merge(catch_up, %{catch_up_left: 2, catch_up_until: nil}),
            Map.merge(catch_up, %{catch_up_left: -1, catch_up_until: until}),
            Map.merge(catch_up, %{catch_up_left: 25, catch_up_until: until}),
            %{missed_runs: "skip", catch_up_left: 1, catch_up_until: until}
          ] do
        refused!("cron_schedules", schedule(ctx, row), "cron_schedules_catch_up_episode")
      end
    end
  end

  # The column and the quoted values of one CHECK, as the live catalog
  # spells it. SQLite keeps the CREATE TABLE text with each check inline;
  # PostgreSQL answers the constraint's definition.
  defp check!(table, constraint) do
    definition =
      if sqlite?() do
        %{rows: rows} =
          Arca.Repo.query!(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table]
          )

        assert [[sql]] = rows, "the catalog holds no table #{table}"

        assert [_, check] =
                 Regex.run(~r/CONSTRAINT "?#{constraint}"? CHECK \((\w+ IN \([^)]*\))\)/, sql),
               "#{table} carries no CHECK #{constraint}"

        check
      else
        %{rows: rows} =
          Arca.Repo.query!(
            """
            SELECT pg_get_constraintdef(c.oid)
            FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
            WHERE t.relname = $1 AND c.conname = $2 AND c.contype = 'c'
            """,
            [table, constraint]
          )

        assert [[check]] = rows, "#{table} carries no CHECK #{constraint}"
        check
      end

    assert [_, column] =
             Regex.run(~r/^(?:CHECK )?\(*(\w+)\)?(?:::text)? (?:IN|= ANY)/, definition),
           "#{constraint} reads #{definition}"

    {column, Regex.scan(~r/'([^']*)'/, definition, capture: :all_but_first) |> List.flatten()}
  end

  # A direct insert inside a savepoint, so a refused row leaves the test's
  # transaction usable on PostgreSQL.
  defp insert!(table, row) do
    {:ok, result} = Arca.Repo.transaction(fn -> Arca.Repo.insert_all(table, [row]) end)
    result
  end

  defp refused!(table, row, constraints) do
    message =
      try do
        insert!(table, row)
        nil
      rescue
        error -> Exception.message(error)
      end

    assert message, "#{table} took #{inspect(row)}"

    assert Enum.any?(List.wrap(constraints), &(message =~ &1)),
           "#{table} refused #{inspect(row)} for another reason: #{message}"
  end

  defp id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
  defp now, do: NaiveDateTime.utc_now()

  defp execution(%{athanor: athanor}, status) do
    id = id("exec")

    %{
      id: id,
      root_execution_id: id,
      reference: "reagent:local.vocab",
      user_id: "user_vocab",
      started_at: now(),
      status: status,
      athanor_id: athanor
    }
  end

  defp execution_row!(ctx) do
    row = execution(ctx, "running")
    {1, _} = insert!("executions", row)
    row.id
  end

  defp attempt(%{athanor: athanor}, execution_id, state, outcome) do
    %{
      attempt: id("att"),
      athanor_id: athanor,
      athanor_generation: 1,
      execution_id: execution_id,
      fence: System.unique_integer([:positive]),
      boot_id: "boot_vocab",
      lease_until: now(),
      state: state,
      outcome: outcome,
      started_at: now()
    }
  end

  defp thread_row!(%{athanor: athanor}) do
    id = id("thread")

    {1, _} =
      insert!("threads", %{
        id: id,
        athanor_id: athanor,
        created_by: "user_vocab",
        inserted_at: now(),
        updated_at: now()
      })

    id
  end

  defp turn(%{athanor: athanor}, thread_id, status) do
    %{
      id: id("turn"),
      athanor_id: athanor,
      thread_id: thread_id,
      status: status,
      accepted_at: now(),
      origin: "interactive",
      fence: 1
    }
  end

  defp schedule(%{athanor: athanor}, attrs) do
    Map.merge(
      %{
        id: id("sched"),
        user_id: "user_vocab",
        name: id("name"),
        cron_expression: "0 * * * *",
        reference: "reagent:local.vocab",
        resolved_reference: "reagent:local.vocab:1.0.0",
        athanor_id: athanor,
        profile_id: "prof_vocab",
        created_at: now(),
        updated_at: now()
      },
      attrs
    )
  end

  defp schedule_row!(ctx) do
    row = schedule(ctx, %{})
    {1, _} = insert!("cron_schedules", row)
    row.id
  end

  defp occurrence(%{athanor: athanor}, schedule_id, state) do
    %{
      id: id("occ"),
      athanor_id: athanor,
      schedule_id: schedule_id,
      # Distinct per row: an occurrence is one per schedule and time.
      scheduled_for: NaiveDateTime.add(now(), System.unique_integer([:positive]), :second),
      state: state,
      claimed_at: now()
    }
  end

  defp cli_sign_in(state) do
    %{
      id: id("csi"),
      approval_hash: :crypto.strong_rand_bytes(32),
      token_hash: :crypto.strong_rand_bytes(32),
      token_prefix: "tokenpre",
      user_code: "K7QM-3XRD",
      machine: "laptop",
      state: state,
      expires_at: now(),
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp receipt(%{athanor: athanor}, outcome) do
    %{
      consumer: "schedule_notes",
      source_kind: "schedule_occurrence",
      source_id: id("occ"),
      source_revision: "2026-10-16T00:00:00.000000Z",
      athanor_id: athanor,
      outcome: outcome,
      inserted_at: now()
    }
  end

  defp profile(%{athanor: athanor}, status) do
    %{
      id: id("prof"),
      athanor_id: athanor,
      source_ref: "reagent:local.vocab",
      label: id("label"),
      status: status,
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp vault_entry(%{athanor: athanor}, status) do
    %{
      id: id("vault"),
      athanor_id: athanor,
      name: id("entry"),
      kind: "api_key",
      destination: ~s({"hosts":["api.example.com"]}),
      status: status,
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp invitation(%{athanor: athanor}, confirmer_kind, confirmer_id) do
    %{
      id: id("pin"),
      athanor_id: athanor,
      secret_hash: id("hash"),
      user_id: "user_vocab",
      membership_id: id("mem"),
      prospective_client_id: id("pcl"),
      audience_home: "https://home.example",
      expires_at: now(),
      key_digest: id("digest"),
      confirmer_kind: confirmer_kind,
      confirmer_id: confirmer_id,
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp instance_entry(_ctx, status) do
    %{
      id: id("inst"),
      name: id("entry"),
      kind: "api_key",
      destination: ~s({"hosts":["api.example.com"]}),
      status: status,
      audience: "everyone",
      created_by: "user_vocab",
      inserted_at: now(),
      updated_at: now()
    }
  end
end
