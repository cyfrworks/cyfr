# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultDefaultsTest do
  use ExUnit.Case, async: false

  require Arca.Repo.Errors
  require Ecto.Query

  alias Arca.Test.QueryCounter
  alias Arca.VaultDefaults

  @destination ~s({"hosts":["api.openai.com"],"scheme":"https"})

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {:ok,
     actor: Arca.Test.Actor.local(),
     other: Prima.Actor.in_athanor("ath_other"),
     platform: Arca.Test.Actor.platform()}
  end

  defp entry!(actor, hint \\ "openai.com") do
    {:ok, entry} =
      Arca.VaultStorage.put(actor, %{
        name: "entry-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: hint,
        sealed_payload: "sealed",
        destination: @destination
      })

    entry
  end

  defp instance!(platform) do
    {:ok, entry} =
      Arca.InstanceEntries.put(platform, %{
        name: "instance-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "openai.com",
        destination:
          ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
        sealed_payload: "sealed",
        binding_digest: "sha256:i0",
        audience: "everyone",
        created_by: "usr_admin"
      })

    entry
  end

  defp rows(athanor, hint) do
    Arca.Repo.all(
      Ecto.Query.from(d in Arca.Schemas.VaultDefault,
        where: d.athanor_id == ^athanor and d.provider_hint == ^hint
      )
    )
  end

  test "a second default for a provider is one row: the upsert moves it", %{actor: actor} do
    first = entry!(actor)
    second = entry!(actor)

    # The first entry of the provider became its default when it was put.
    assert {:ok, %{vault_entry_id: id}} = VaultDefaults.get(actor, "openai.com")
    assert id == first.id

    assert {:ok, %{vault_entry_id: moved, instance_entry_id: nil}} =
             VaultDefaults.set(actor, "openai.com", %{vault_entry_id: second.id})

    assert moved == second.id
    assert [row] = rows(actor.athanor_id, "openai.com")
    assert row.vault_entry_id == second.id
  end

  test "an instance entry may be a default, and moving back clears it", %{
    actor: actor,
    platform: platform
  } do
    own = entry!(actor)
    instance = instance!(platform)

    assert {:ok, %{instance_entry_id: iid, vault_entry_id: nil}} =
             VaultDefaults.set(actor, "openai.com", %{instance_entry_id: instance.id})

    assert iid == instance.id

    assert {:ok, %{vault_entry_id: vid, instance_entry_id: nil}} =
             VaultDefaults.set(actor, "openai.com", %{vault_entry_id: own.id})

    assert vid == own.id
    assert [_one] = rows(actor.athanor_id, "openai.com")
  end

  test "a default naming both, or neither, or an entry of another athanor, is refused",
       %{actor: actor, other: other, platform: platform} do
    own = entry!(actor)
    theirs = entry!(other)
    instance = instance!(platform)

    QueryCounter.assert_queries(0, fn ->
      assert {:error, :invalid_target} =
               VaultDefaults.set(actor, "openai.com", %{
                 vault_entry_id: own.id,
                 instance_entry_id: instance.id
               })

      assert {:error, :invalid_target} = VaultDefaults.set(actor, "openai.com", %{})
    end)

    assert {:error, :not_found} =
             VaultDefaults.set(actor, "openai.com", %{vault_entry_id: theirs.id})

    assert {:error, :not_found} =
             VaultDefaults.set(actor, "openai.com", %{instance_entry_id: "ine_missing"})

    # The default the athanor had stands.
    assert {:ok, %{vault_entry_id: id}} = VaultDefaults.get(actor, "openai.com")
    assert id == own.id
  end

  test "the composite key refuses another athanor's entry written around the store",
       %{actor: actor, other: other} do
    theirs = entry!(other)
    now = DateTime.utc_now()

    row = %{
      id: "vdf_raw",
      athanor_id: actor.athanor_id,
      provider_hint: "openai.com",
      vault_entry_id: theirs.id,
      instance_entry_id: nil,
      inserted_at: now,
      updated_at: now
    }

    assert :refused = raw_insert(row)
    assert :refused = raw_insert(%{row | vault_entry_id: nil, provider_hint: "x"})
  end

  test "a tombstoned entry is not a default to set", %{actor: actor} do
    entry = entry!(actor, "anthropic.com")
    :ok = Arca.VaultStorage.tombstone(actor, entry.id)

    assert {:error, :not_found} =
             VaultDefaults.set(actor, "anthropic.com", %{vault_entry_id: entry.id})

    assert {:error, :not_found} = VaultDefaults.get(actor, "anthropic.com")
  end

  test "two athanors choose independently, and clear/2 removes one's", %{
    actor: actor,
    other: other
  } do
    mine = entry!(actor)
    theirs = entry!(other)

    assert {:ok, %{vault_entry_id: m}} = VaultDefaults.get(actor, "openai.com")
    assert {:ok, %{vault_entry_id: t}} = VaultDefaults.get(other, "openai.com")
    assert {m, t} == {mine.id, theirs.id}

    assert :ok = VaultDefaults.clear(actor, "openai.com")
    assert {:error, :not_found} = VaultDefaults.get(actor, "openai.com")
    assert {:ok, %{vault_entry_id: ^t}} = VaultDefaults.get(other, "openai.com")
    assert :ok = VaultDefaults.clear(actor, "openai.com")
  end

  test "an actor with no athanor is refused before any query" do
    nobody = %Prima.Actor{athanor_id: nil}

    QueryCounter.assert_queries(0, fn ->
      assert {:error, :no_athanor} = VaultDefaults.get(nobody, "openai.com")
      assert {:error, :no_athanor} = VaultDefaults.list(nobody)

      assert {:error, :no_athanor} =
               VaultDefaults.set(nobody, "openai.com", %{vault_entry_id: "vlt_x"})

      assert {:error, :no_athanor} = VaultDefaults.clear(nobody, "openai.com")
    end)
  end

  defp raw_insert(row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(Arca.Schemas.VaultDefault, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end
end

defmodule Arca.VaultDefaultsRaceTest do
  @moduledoc """
  Two writers setting one provider's default on connections of their own:
  the upsert never leaves two rows, whichever lands last.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    athanor = "ath_defaults_race_#{System.unique_integer([:positive])}"
    on_exit(fn -> unboxed(fn -> Arca.TenantTables.delete_all_for(actor(athanor)) end) end)
    {:ok, athanor: athanor}
  end

  test "two racing sets leave one default", %{athanor: athanor} do
    [a, b] =
      unboxed(fn ->
        for _ <- 1..2 do
          {:ok, entry} =
            Arca.VaultStorage.put(actor(athanor), %{
              name: "entry-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "race.example",
              sealed_payload: "sealed",
              destination: ~s({"hosts":["race.example"],"scheme":"https"})
            })

          entry
        end
      end)

    results =
      for entry <- [a, b] do
        Task.async(fn ->
          unboxed(fn ->
            Arca.VaultDefaults.set(actor(athanor), "race.example", %{vault_entry_id: entry.id})
          end)
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    rows =
      unboxed(fn ->
        Arca.Repo.all(
          Ecto.Query.from(d in Arca.Schemas.VaultDefault,
            where: d.athanor_id == ^athanor and d.provider_hint == "race.example"
          )
        )
      end)

    assert [row] = rows
    assert row.vault_entry_id in [a.id, b.id]
  end

  defp actor(athanor), do: Prima.Actor.in_athanor(athanor)
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
