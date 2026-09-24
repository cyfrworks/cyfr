# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StoredJsonTest do
  @moduledoc """
  Each owner of a stored JSON column keeps its own answer for a column
  that is absent, empty or does not decode, and says so in one line naming
  itself, the column and its size — never the column's bytes, which may
  carry a credential.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  # Unterminated, and carrying what a stored column may carry.
  @corrupt ~s({"token": "sk-live-7c1e0b9a4d2f")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # The owner's one line for `field`, and nothing of the column's bytes.
  defp assert_logged(log, owner, field) do
    assert log =~
             "[#{owner}] stored #{field} is not valid JSON (#{byte_size(@corrupt)} bytes)"

    refute log =~ "sk-live"
  end

  test "Arca.ThreadStorage reads a gate's payload and resolution as a map" do
    alias Arca.ThreadStorage

    assert ThreadStorage.payload(%{payload: nil}) == %{}
    assert ThreadStorage.payload(%{payload: ""}) == %{}
    assert ThreadStorage.payload(%{payload: ~s({"a":1})}) == %{"a" => 1}
    assert ThreadStorage.payload(%{payload: "[1]"}) == %{}

    log = capture_log(fn -> assert ThreadStorage.payload(%{payload: @corrupt}) == %{} end)
    assert_logged(log, "Arca.ThreadStorage", "payload")

    log = capture_log(fn -> assert ThreadStorage.resolution(%{resolution: @corrupt}) == %{} end)
    assert_logged(log, "Arca.ThreadStorage", "resolution")
  end

  test "Arca.Providers.Records reads a corrupt audit column as corruption", %{ctx: ctx} do
    exec = "exec_stored_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Execution, [
        %{
          id: exec,
          athanor_id: ctx.athanor_id,
          user_id: ctx.user_id,
          reference: "reagent:local.stored:0.1.0",
          status: "completed",
          started_at: DateTime.utc_now(),
          input: @corrupt,
          output: ~s({"ok":true}),
          host_policy: ""
        }
      ])

    corrupt = %{"_decode_error" => "stored snapshot was not valid JSON"}

    log =
      capture_log(fn ->
        assert {:ok, record} =
                 Arca.Providers.Records.handle("record", Sanctum.Context.actor(ctx), %{
                   "action" => "get",
                   "id" => exec
                 })

        assert record.input == corrupt
        assert record.output == %{"ok" => true}
        assert record.host_policy == corrupt
      end)

    assert_logged(log, "Arca.Providers.Records", "input")
  end

  test "Cyfr.Schedules.Provider renders a corrupt or empty column as null", %{ctx: ctx} do
    id = "sched_stored_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.CronSchedule, [
        %{
          id: id,
          user_id: ctx.user_id,
          name: id,
          cron_expression: "0 * * * *",
          reference: "reagent:local.stored:0.1.0",
          input: @corrupt,
          metadata: "",
          status: "active",
          athanor_id: ctx.athanor_id,
          profile_id: "prof_stored",
          concurrency: "forbid",
          created_at: now,
          updated_at: now
        }
      ])

    log =
      capture_log(fn ->
        assert {:ok, schedule} =
                 Cyfr.Schedules.Provider.handle("schedule", ctx, %{
                   "action" => "get",
                   "schedule_id" => id
                 })

        assert schedule.input == nil
        assert schedule.metadata == nil
      end)

    assert_logged(log, "Cyfr.Schedules.Provider", "input")
  end

  test "Cyfr.Schedules.Scheduler reads corrupt schedule metadata as a run nobody asked to keep" do
    alias Cyfr.Schedules.Scheduler

    for metadata <- [nil, "", ~s({"keep_outcome": false}), "[true]"] do
      assert Scheduler.keep_outcome(metadata) == {false, nil}
    end

    assert Scheduler.keep_outcome(~s({"keep_outcome": true, "note_name": "n"})) == {true, "n"}
    assert Scheduler.keep_outcome(~s({"keep_outcome": true, "note_name": ""})) == {true, nil}

    log = capture_log(fn -> assert Scheduler.keep_outcome(@corrupt) == {false, nil} end)
    assert_logged(log, "Cyfr.Schedules.Scheduler", "metadata")
  end

  test "Sanctum.ApiKey lists a corrupt scope as none and a corrupt allowlist as absent" do
    ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    name = "stored-json-#{System.unique_integer([:positive])}"
    {:ok, _} = Sanctum.ApiKey.create(ctx, %{name: name, ip_allowlist: ["203.0.113.0/24"]})

    Arca.Repo.update_all(from(k in Arca.Schemas.ApiKey, where: k.name == ^name),
      set: [scope: @corrupt, ip_allowlist: @corrupt]
    )

    log =
      capture_log(fn ->
        {:ok, keys} = Sanctum.ApiKey.list(ctx)
        key = Enum.find(keys, &(&1.name == name))
        assert key.scope == []
        assert key.ip_allowlist == nil
      end)

    assert_logged(log, "Sanctum.ApiKey", "scope")
    assert_logged(log, "Sanctum.ApiKey", "ip_allowlist")
  end

  test "Sanctum.Caller refuses a retained key context whose allowlist does not read" do
    ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    name = "stored-json-#{System.unique_integer([:positive])}"

    {:ok, %{api_key: raw}} =
      Sanctum.ApiKey.create(ctx, %{name: name, type: :service, ip_allowlist: ["127.0.0.1"]})

    {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")

    Arca.Repo.update_all(from(k in Arca.Schemas.ApiKey, where: k.name == ^name),
      set: [ip_allowlist: @corrupt]
    )

    # A corrupt allowlist is a corrupt security row, not an absent
    # restriction: the retained context no longer stands, from the admitted
    # address or any other.
    log =
      capture_log(fn ->
        for ip <- ["127.0.0.1", "203.0.113.7"] do
          assert {:error, :unauthenticated} =
                   Sanctum.Caller.revalidate_session(%{key_ctx | client_ip: ip})
        end
      end)

    assert_logged(log, "Sanctum.Caller", "ip_allowlist")
  end

  test "Sanctum.Vault and Sanctum.VaultReader read a corrupt binding column as empty", %{
    ctx: ctx
  } do
    {:ok, view} =
      Sanctum.Vault.create(ctx, %{
        name: "stored-json",
        kind: "api_key",
        fields: %{"token" => "t0k3n-value"}
      })

    Arca.Repo.update_all(from(e in Arca.Schemas.VaultEntry, where: e.id == ^view.id),
      set: [field_names: @corrupt, oauth_scopes: ""]
    )

    log =
      capture_log(fn ->
        {:ok, listed} = Sanctum.Vault.list(ctx)
        entry = Enum.find(listed, &(&1.id == view.id))
        assert entry.field_names == []
        assert entry.oauth_scopes == []
      end)

    assert_logged(log, "Sanctum.Vault", "field_names")

    empty = %{provider_hint: nil, field_names: nil, oauth_endpoints: nil, oauth_scopes: nil}
    corrupt = %{empty | field_names: @corrupt, oauth_endpoints: @corrupt}

    log =
      capture_log(fn ->
        assert Sanctum.VaultReader.binding_digest(corrupt) ==
                 Sanctum.VaultReader.binding_digest(empty)
      end)

    assert_logged(log, "Sanctum.VaultReader", "field_names")
    assert_logged(log, "Sanctum.VaultReader", "oauth_endpoints")
  end
end
