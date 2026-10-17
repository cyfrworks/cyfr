# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptLedgerTest do
  @moduledoc """
  What an attempt hands its guest joins the run's source ledger before the
  runner is answered (`Opus.Ledger.join/3`): an entry's disclosed fields
  and a dispensed token as vault-disclosed material; a storage read, a
  listing and an existence check as material read through the storage
  grant, a `data/` object carrying no recorded sources of its own and so
  outside too. The bare scope listing carries nothing.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Prima.Authority
  alias Prima.Authority.Blob.Edge
  alias Prima.Source

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  defp ledger(fixture) do
    {:ok, sources} =
      Arca.Execution.sources(Prima.Actor.in_athanor(fixture.athanor_id), fixture.execution_id)

    sources
  end

  defp storage_root! do
    dir = Path.join(System.tmp_dir!(), "attempt_ledger_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:arca, :base_path, previous),
        else: Application.delete_env(:arca, :base_path)
    end)

    File.mkdir_p!(dir)
    Application.put_env(:arca, :base_path, dir)
  end

  test "an attach that discloses an entry's fields holds vault_disclosed before the runner has them" do
    fixture =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        vault: %{kind: "api_key", fields: %{"KEY" => "k"}}
      )

    assert ledger(fixture) == [Source.new(:vault_disclosed)]

    plain = AttemptFixtures.attached!(ctx: Sanctum.TestContext.local(:api))
    assert ledger(plain) == []
  end

  test "a dispensed token holds vault_disclosed before it is answered" do
    fixture =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        vault: %{kind: "oauth", oauth: %{"access_token" => "ya29.tok"}}
      )

    assert ledger(fixture) == []

    assert %{"ok" => "ya29.tok"} =
             AttemptFixtures.call(fixture, "oauth_token", %{"provider" => "google"})

    assert ledger(fixture) == [Source.new(:vault_disclosed)]
  end

  test "a read of a guest object joins the files grant and the sources it was written with, never an unnamed outside source" do
    storage_root!()

    fixture =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        authority: %{
          Authority.zero()
          | resources: %Edge{storage: %{paths: ["*"], actions: ["read", "list", "exists"]}}
        }
      )

    actor = Sanctum.Context.actor(fixture.ctx)
    :ok = Arca.put(actor, ["data", "clean.txt"], "mine", sources: [])
    :ok = Arca.put(actor, ["data", "region.txt"], "eu-west", sources: [Source.new(:filed)])

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/clean.txt"
             })

    assert ledger(fixture) == [Source.new(:files_by_grant)]

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/region.txt"
             })

    assert ledger(fixture) == [Source.new(:filed), Source.new(:files_by_grant)]
  end

  test "a listing and an existence check join the files grant and outside material, since names record no sources; the bare scope listing joins nothing" do
    storage_root!()

    fixture =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        authority: %{
          Authority.zero()
          | resources: %Edge{storage: %{paths: ["*"], actions: ["read", "list", "exists"]}}
        }
      )

    :ok = Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "a.txt"], "a")

    assert %{"ok" => %{"files" => _}} =
             AttemptFixtures.call(fixture, "storage", %{"action" => "list", "path" => ""})

    assert ledger(fixture) == []

    assert %{"ok" => %{"exists" => true}} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "exists",
               "path" => "data/a.txt"
             })

    assert ledger(fixture) == [Source.new(:files_by_grant), Source.outside(nil)]

    other =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        authority: %{
          Authority.zero()
          | resources: %Edge{storage: %{paths: ["*"], actions: ["read", "list", "exists"]}}
        }
      )

    assert %{"ok" => %{"files" => ["a.txt"]}} =
             AttemptFixtures.call(other, "storage", %{"action" => "list", "path" => "data/"})

    assert ledger(other) == [Source.new(:files_by_grant), Source.outside(nil)]
  end
end
