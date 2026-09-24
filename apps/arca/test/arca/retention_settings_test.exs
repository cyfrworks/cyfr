# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RetentionSettingsTest do
  @moduledoc """
  An athanor's retention settings row: the keys it set and nothing else,
  merged under a conditional revision so two patches of different keys
  both land, refused as corrupt when it cannot be read as written, and
  never a default in place of a store that could not answer.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.RetentionSettings
  alias Arca.Schemas.RetentionSettings, as: Row

  setup do
    athanor = "ath_settings_#{System.unique_integer([:positive])}"
    {:ok, actor: %Prima.Actor{athanor_id: athanor, user_id: "usr_settings"}, athanor: athanor}
  end

  defp row(athanor), do: Arca.Repo.one(from(r in Row, where: r.athanor_id == ^athanor))

  defp store!(athanor, settings, revision \\ 1) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Row, [
        %{
          athanor_id: athanor,
          settings: settings,
          revision: revision,
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  describe "in the sandbox" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    end

    test "a missing row is the empty patch at revision 0", %{actor: actor, athanor: athanor} do
      assert {:ok, %{patch: %{}, revision: 0}} = RetentionSettings.get(actor)
      assert row(athanor) == nil
    end

    test "a patch lands as the canonical encoding of what was set, and reads back", %{
      actor: actor,
      athanor: athanor
    } do
      assert {:ok, %{patch: %{"executions" => 5, "builds" => 3}, revision: 1}} =
               RetentionSettings.patch(actor, %{"executions" => 5, "builds" => 3})

      assert %Row{settings: ~s({"builds":3,"executions":5}), revision: 1} = row(athanor)

      assert {:ok, %{patch: %{"executions" => 20, "builds" => 3}, revision: 2}} =
               RetentionSettings.patch(actor, %{"executions" => 20})

      assert {:ok, %{patch: %{"executions" => 20, "builds" => 3}, revision: 2}} =
               RetentionSettings.get(actor)
    end

    test "a document that is not what a patch writes is corrupt", %{athanor: athanor} do
      for {settings, n} <-
            Enum.with_index([
              "not valid json {{{",
              ~s(["executions", 5]),
              ~s("executions"),
              ~s({"executions": 0}),
              ~s({"executions": -3}),
              ~s({"executions": "5"}),
              ~s({"executions": 1.5}),
              ~s({"mcp_log_days": null})
            ]) do
        estate = "#{athanor}_#{n}"
        store!(estate, settings)
        actor = %Prima.Actor{athanor_id: estate}

        assert {:error, :corrupt} = RetentionSettings.get(actor), settings
        assert {:error, :corrupt} = RetentionSettings.patch(actor, %{"builds" => 3}), settings
        assert %Row{settings: ^settings, revision: 1} = row(estate)
      end
    end

    test "a key outside the roster is ignored, and the next patch drops it", %{
      actor: actor,
      athanor: athanor
    } do
      store!(athanor, ~s({"executions": 5, "retired_kind": "anything"}))

      assert {:ok, %{patch: %{"executions" => 5}, revision: 1}} = RetentionSettings.get(actor)

      assert {:ok, %{patch: %{"executions" => 5, "builds" => 2}, revision: 2}} =
               RetentionSettings.patch(actor, %{"builds" => 2})

      assert %Row{settings: ~s({"builds":2,"executions":5})} = row(athanor)
    end

    test "a store that cannot answer is an outage, never the defaults", %{actor: actor} do
      # Dropped inside the sandbox transaction, which rolls it back.
      Arca.Repo.query!("DROP TABLE retention_settings")

      assert {:error, :database_error} = RetentionSettings.get(actor)
    end

    test "a patch against a store that cannot answer is an outage", %{actor: actor} do
      Arca.Repo.query!("DROP TABLE retention_settings")

      assert {:error, :database_error} = RetentionSettings.patch(actor, %{"executions" => 5})
    end

    test "an actor with no athanor is refused before any query" do
      for nobody <- [%Prima.Actor{}, %Prima.Actor{athanor_id: ""}, %Prima.Actor{scope: :platform}] do
        {answers, %{total: 0}} =
          Arca.Test.QueryCounter.count(fn ->
            {RetentionSettings.get(nobody), RetentionSettings.patch(nobody, %{"executions" => 5})}
          end)

        assert answers == {{:error, :no_athanor}, {:error, :no_athanor}}
      end
    end
  end

  # Two connections of their own, outside the sandbox: a patch races
  # another that lands between its read and its write. The other lands
  # from inside the racing patch's own read — the repo's query telemetry
  # runs in the process that made the query, once the query returned — so
  # the interleaving is the test's, not the scheduler's.
  describe "concurrent patches" do
    setup %{athanor: athanor} do
      on_exit(fn ->
        unboxed(fn -> Arca.Repo.delete_all(from(r in Row, where: r.athanor_id == ^athanor)) end)
      end)

      :ok
    end

    defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

    # After each read of the settings row this process makes — at most
    # `times` of them — a patch from another connection lands first.
    defp interleave(actor, times, next_patch) do
      racer = self()
      landed = :counters.new(1, [:atomics])
      handler = "retention-settings-race-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == racer and metadata[:source] == "retention_settings" and
               String.starts_with?(metadata[:query] || "", "SELECT") and
               :counters.get(landed, 1) < times do
            n = :counters.get(landed, 1) + 1
            :counters.put(landed, 1, n)

            {:ok, _} =
              Task.async(fn ->
                unboxed(fn -> RetentionSettings.patch(actor, next_patch.(n)) end)
              end)
              |> Task.await(15_000)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      landed
    end

    test "two patches of different keys both land, each raising the revision", %{
      actor: actor,
      athanor: athanor
    } do
      unboxed(fn -> store!(athanor, ~s({"mcp_log_days":14}), 4) end)
      landed = interleave(actor, 1, fn _n -> %{"builds" => 3} end)

      assert {:ok, %{patch: patch, revision: 6}} =
               unboxed(fn -> RetentionSettings.patch(actor, %{"executions" => 5}) end)

      assert :counters.get(landed, 1) == 1
      assert patch == %{"mcp_log_days" => 14, "builds" => 3, "executions" => 5}

      assert {:ok, %{patch: ^patch, revision: 6}} =
               unboxed(fn -> RetentionSettings.get(actor) end)
    end

    test "a first row another patch inserted first is merged over, not lost", %{actor: actor} do
      landed = interleave(actor, 1, fn _n -> %{"builds" => 3} end)

      assert {:ok, %{patch: patch, revision: 2}} =
               unboxed(fn -> RetentionSettings.patch(actor, %{"executions" => 5}) end)

      assert :counters.get(landed, 1) == 1
      assert patch == %{"builds" => 3, "executions" => 5}
    end

    test "a patch overtaken on every retry refuses, and writes over nothing", %{
      actor: actor,
      athanor: athanor
    } do
      unboxed(fn -> store!(athanor, ~s({"builds":1}), 1) end)
      # Four overtakings are all a patch that retries three times can
      # meet: a fifth attempt would find none, and land.
      landed = interleave(actor, 4, fn n -> %{"builds" => n + 1} end)

      assert {:error, :settings_conflict} =
               unboxed(fn -> RetentionSettings.patch(actor, %{"executions" => 5}) end)

      # One read, then three retries, each overtaken.
      assert :counters.get(landed, 1) == 4

      assert {:ok, %{patch: %{"builds" => 5} = patch, revision: 5}} =
               unboxed(fn -> RetentionSettings.get(actor) end)

      refute Map.has_key?(patch, "executions")
    end
  end
end
