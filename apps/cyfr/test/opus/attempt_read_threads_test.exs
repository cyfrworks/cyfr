# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttemptReadThreadsTest do
  @moduledoc """
  A storage read of a `data/` object joins the read threads its settled
  generation was written with into the run before the runner is
  answered, so a run that reads what another wrote holds the threads
  whose posts the bytes carry.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Prima.Authority
  alias Prima.Authority.Blob.Edge

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  defp read_threads(fixture) do
    {:ok, threads} =
      Arca.Execution.read_threads(
        Prima.Actor.in_athanor(fixture.athanor_id),
        fixture.execution_id
      )

    threads
  end

  defp storage_root! do
    dir =
      Path.join(System.tmp_dir!(), "attempt_read_threads_#{System.unique_integer([:positive])}")

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

  test "a read of a guest object joins the read threads it was written with, and one written with none joins none" do
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
    :ok = Arca.put(actor, ["data", "clean.txt"], "mine")
    :ok = Arca.put(actor, ["data", "region.txt"], "eu-west", threads: ["thr_region"])

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/clean.txt"
             })

    assert read_threads(fixture) == []

    assert %{"ok" => %{"content" => _}} =
             AttemptFixtures.call(fixture, "storage", %{
               "action" => "read",
               "path" => "data/region.txt"
             })

    assert read_threads(fixture) == ["thr_region"]
  end
end
