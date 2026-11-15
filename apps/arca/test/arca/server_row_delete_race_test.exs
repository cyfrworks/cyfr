# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ServerRowDeleteRaceTest do
  @moduledoc """
  A row's delete and a revision that stands on the row, under real
  concurrency, on connections of their own: inside the sandbox one shared
  connection would serialize the two writers the test is about.

  The delete takes the row first, then finds the profiles whose heads
  stand on it, locks them and reads each one's current head again under
  the lock; a revision that grants the row's tools takes the row, shared,
  before its profile. So a head that moved off the row while the delete
  waited for its profile is not blocked; a grant committed while the
  delete waited for the row is found and blocked; and a grant that comes
  after the delete took the row waits for it and is refused, the row gone.

  PostgreSQL only: SQLite takes its one write lock at each transaction's
  start (`Arca.Repo.locking_transaction/2`), so the delete and the
  revision never interleave there; each sees what the other committed.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ConsentStorage
  alias Arca.Test.Writers
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  setup do
    actor = Arca.Test.Actor.local()
    tag = System.unique_integer([:positive])
    row_name = "race-#{tag}"

    row =
      unboxed(fn ->
        Arca.Repo.insert!(%Arca.Schemas.McpServer{
          id: Prima.UUID7.generate_id("mcp"),
          name: row_name,
          transport: "program",
          mark: "mcp",
          home: "scratch",
          enabled: true,
          epoch: 1,
          revision: 0,
          config_json: ~s({"command":"server","env":{}}),
          athanor_id: actor.athanor_id,
          created_by: actor.user_id
        })
      end)

    profiles = for label <- ["moved", "late", "refused"], do: "prof_race_#{label}_#{tag}"
    on_exit(fn -> unboxed(fn -> clean!(actor.athanor_id, profiles, row.id) end) end)

    {:ok, actor: actor, row: row, profiles: profiles, tag: tag}
  end

  test "a head that moved off the row while the delete waited for its profile is not blocked",
       %{actor: actor, row: row, profiles: [profile | _], tag: tag} do
    test = self()
    granted = granted!(actor, profile, tag, row.name)

    # The revision that moves the head off the row holds the profile.
    moving =
      Task.async(fn ->
        unboxed(fn ->
          ConsentStorage.insert_revision(revision(actor, profile, 2, policy(nil)), [], granted,
            verify: fn ->
              send(test, :holding)

              receive do
                :commit -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :holding, 5_000

    deleting = Task.async(fn -> unboxed(fn -> delete(actor, row, test) end) end)
    assert_receive {:backend, pid}, 5_000
    waits_on_lock!(pid, deleting)

    send(moving.pid, :commit)
    assert {:ok, _} = Task.await(moving, 10_000)
    assert {:ok, _} = Task.await(deleting, 10_000)

    assert %{status: "active"} = profile!(actor, profile)
  end

  test "a grant of the row's tools committed while the delete waited for the row is blocked",
       %{actor: actor, row: row, profiles: [_moved, profile | _], tag: tag} do
    test = self()
    head = granted!(actor, profile, tag, nil)

    granting =
      Task.async(fn ->
        unboxed(fn ->
          ConsentStorage.insert_revision(revision(actor, profile, 2, policy(row.name)), [], head,
            verify: fn ->
              send(test, :holding)

              receive do
                :commit -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :holding, 5_000

    deleting = Task.async(fn -> unboxed(fn -> delete(actor, row, test) end) end)
    assert_receive {:backend, pid}, 5_000
    waits_on_lock!(pid, deleting)

    send(granting.pid, :commit)
    assert {:ok, _} = Task.await(granting, 10_000)
    assert {:ok, _} = Task.await(deleting, 10_000)

    assert %{status: "needs_consent"} = profile!(actor, profile)
  end

  test "a grant of the row's tools that comes after the delete took the row is refused",
       %{actor: actor, row: row, profiles: [_moved, _late, profile], tag: tag} do
    test = self()
    head = granted!(actor, profile, tag, nil)

    deleting =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            {:ok, _} = Arca.McpServerStorage.delete(actor, row.name, %{id: row.id, epoch: 1})
            send(test, :deleted)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :deleted, 5_000

    granting =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:backend, backend_pid()})

          ConsentStorage.insert_revision(
            revision(actor, profile, 2, policy(row.name)),
            [],
            head
          )
        end)
      end)

    assert_receive {:backend, pid}, 5_000
    waits_on_lock!(pid, granting)

    send(deleting.pid, :commit)
    assert {:ok, :ok} = Task.await(deleting, 10_000)
    assert {:error, {:tool_server_not_found, name}} = Task.await(granting, 10_000)
    assert name == row.name

    assert %{status: "active", head_consent_id: ^head} = profile!(actor, profile)
  end

  # The delete as the provider makes it, after naming its connection.
  defp delete(actor, row, test) do
    send(test, {:backend, backend_pid()})
    Arca.McpServerStorage.delete(actor, row.name, %{id: row.id, epoch: 1})
  end

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # The connection `pid` waits for a lock another transaction holds: the
  # one ordering the case is about. A writer that finished instead never
  # waited, which the case's assertions then show.
  defp waits_on_lock!(pid, task, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    %{rows: [[waiting]]} =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
          [pid]
        )
      end)

    cond do
      waiting > 0 ->
        :ok

      Process.alive?(task.pid) and System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        waits_on_lock!(pid, task, deadline)

      true ->
        :finished
    end
  end

  # A profile whose first head grants the tools of `server` (nil for none).
  defp granted!(actor, profile, tag, server) do
    unboxed(fn ->
      {:ok, _} =
        Writers.put_profile(%{
          id: profile,
          athanor_id: actor.athanor_id,
          source_ref: "reagent:local.race-#{tag}",
          kind: "owner",
          label: "default",
          status: "active"
        })

      {:ok, consent} =
        ConsentStorage.insert_revision(revision(actor, profile, 1, policy(server)), [], nil)

      consent.id
    end)
  end

  defp revision(actor, profile, revision, policy) do
    %{
      athanor_id: actor.athanor_id,
      profile_id: profile,
      revision: revision,
      scope: "versionless",
      pinned_version: "",
      invoke_mode: "open_inert",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.Digest.sha256(policy),
      resolved_policy: policy,
      activation: "{}",
      granted_by: "test",
      granted_via: "bootstrap"
    }
  end

  defp policy(server) do
    edge =
      if server,
        do: %{
          "tool_servers" => [
            %{
              "server_digest" => "sha256:granted",
              "server_name" => server,
              "tool_patterns" => ["*"],
              "record" => %{"address" => "server", "env" => [], "folder" => "scratch"}
            }
          ]
        },
        else: %{}

    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        "reagent:local.race" => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => edge}
        }
      }
    })
  end

  defp profile!(actor, profile) do
    unboxed(fn ->
      {:ok, row} = Arca.ProfileStorage.get(actor, profile)
      row
    end)
  end

  defp clean!(athanor_id, profiles, row_id) do
    Arca.Repo.update_all(
      from(p in Arca.Schemas.Profile, where: p.athanor_id == ^athanor_id and p.id in ^profiles),
      set: [head_consent_id: nil]
    )

    consents =
      from(c in Arca.Schemas.Consent,
        where: c.athanor_id == ^athanor_id and c.profile_id in ^profiles,
        select: c.id
      )

    Arca.Repo.delete_all(
      from(r in Arca.Schemas.ConsentVaultRef, where: r.consent_id in subquery(consents))
    )

    Arca.Repo.delete_all(
      from(c in Arca.Schemas.Consent,
        where: c.athanor_id == ^athanor_id and c.profile_id in ^profiles
      )
    )

    Arca.Repo.delete_all(
      from(p in Arca.Schemas.Profile, where: p.athanor_id == ^athanor_id and p.id in ^profiles)
    )

    Arca.Repo.delete_all(
      from(s in Arca.Schemas.McpServer, where: s.athanor_id == ^athanor_id and s.id == ^row_id)
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
