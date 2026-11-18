# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QuestionDeclarationHoldTest do
  @moduledoc """
  A standing answer is written only while, inside its own write, an
  installed release is held that declares its action under the digest it
  stores (`Arca.ComponentStorage.hold_declaring/5`, in
  `Arca.Questions.put_standing/3`'s `verify`), on connections of their
  own: inside the sandbox one shared connection would serialize the two
  writers the test is about. A removal that comes while the answer is
  being written waits for it, so the cleanup after the removal finds the
  answer; a removal that committed first leaves nothing to hold, and the
  answer is refused and rolled back.

  PostgreSQL only: SQLite takes its one write lock at each transaction's
  start (`Arca.Repo.locking_transaction/2`), so the two never interleave
  there; each sees what the other committed.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ComponentStorage, Questions}
  alias Arca.Schemas.{Component, QuestionAnswer}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag timeout: 60_000

  @athanor Arca.Test.Actor.athanor_id()
  @person "usr_release_hold"

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend! do
    %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  @shown %{name: "delete_table", title: "delete a table"}

  setup do
    name = "held-#{System.unique_integer([:positive])}"
    actor = %Prima.Actor{athanor_id: @athanor, user_id: @person, scope: :athanor}
    unboxed(fn -> release!(name, "1.0.0", "delete a table") end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          from(a in QuestionAnswer, where: a.athanor_id == ^@athanor and a.name == ^name)
        )

        Arca.Repo.delete_all(
          from(c in Component, where: c.athanor_id == ^@athanor and c.name == ^name)
        )
      end)
    end)

    %{actor: actor, name: name}
  end

  # A catalyst release of `name` at `version` that declares
  # `delete_table` titled `title`.
  defp release!(name, version, title) do
    Arca.Repo.insert!(%Component{
      id: "cmp_#{name}_#{version}_#{System.unique_integer([:positive])}",
      name: name,
      version: version,
      component_type: "catalyst",
      publisher: "acme",
      athanor_id: @athanor,
      digest: "sha256:" <> String.duplicate("b", 64),
      release_digest: "sha256:" <> String.duplicate("c", 64),
      source: "filesystem",
      manifest:
        Jason.encode!(%{
          "name" => name,
          "type" => "catalyst",
          "version" => version,
          "publisher" => "acme",
          "asks" => [%{"name" => "delete_table", "title" => title}]
        })
    })
  end

  defp standing(name) do
    %{
      publisher: "acme",
      name: name,
      action: "delete_table",
      declaration_digest: Prima.Manifest.Asks.digest(@shown),
      caller: "any",
      effect: "allow",
      until: nil
    }
  end

  defp held(actor, name),
    do: fn ->
      ComponentStorage.hold_declaring(
        actor,
        "acme",
        name,
        "delete_table",
        Prima.Manifest.Asks.digest(@shown)
      )
    end

  test "a removal that comes while the answer is written waits for it, and its cleanup finds it",
       %{actor: actor, name: name} do
    test = self()

    writing =
      Task.async(fn ->
        unboxed(fn ->
          Questions.put_standing(actor, standing(name),
            verify: fn ->
              with :ok <- held(actor, name).() do
                send(test, :held)

                receive do
                  :commit -> :ok
                after
                  30_000 -> {:error, :timeout}
                end
              end
            end
          )
        end)
      end)

    assert_receive :held, 5_000

    removing =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:removing, backend!()})
          ComponentStorage.delete_component(actor, name, "1.0.0", "acme", "catalyst")
        end)
      end)

    assert_receive {:removing, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend, ["components"])

    send(writing.pid, :commit)
    assert {:ok, %{name: ^name}} = Task.await(writing, 10_000)
    assert :ok = Task.await(removing, 10_000)

    # The cleanup that follows a removal finds the answer the write left.
    assert {:ok, 1} = unboxed(fn -> Questions.delete_component(actor, "acme", name) end)
  end

  test "a removal that committed first leaves nothing to hold, and the answer is refused",
       %{actor: actor, name: name} do
    assert :ok =
             unboxed(fn ->
               ComponentStorage.delete_component(actor, name, "1.0.0", "acme", "catalyst")
             end)

    assert {:error, :not_found} =
             unboxed(fn ->
               Questions.put_standing(actor, standing(name), verify: held(actor, name))
             end)

    assert {:ok, []} = unboxed(fn -> Questions.standing(actor, @person, "acme", name) end)
  end

  test "a release published again under the same version in other words holds nothing",
       %{actor: actor, name: name} do
    :ok =
      unboxed(fn ->
        ComponentStorage.delete_component(actor, name, "1.0.0", "acme", "catalyst")
      end)

    unboxed(fn -> release!(name, "1.0.0", "delete every table") end)

    assert {:error, :not_found} =
             unboxed(fn ->
               Questions.put_standing(actor, standing(name), verify: held(actor, name))
             end)

    assert {:ok, []} = unboxed(fn -> Questions.standing(actor, @person, "acme", name) end)
  end

  test "of several installed releases, one declaring the words is enough",
       %{actor: actor, name: name} do
    unboxed(fn ->
      release!(name, "2.0.0", "delete every table")
      release!(name, "3.0.0", "drop a table")
    end)

    assert {:ok, %{name: ^name}} =
             unboxed(fn ->
               Questions.put_standing(actor, standing(name), verify: held(actor, name))
             end)

    # The one declaring them gone, the others declare other words.
    :ok =
      unboxed(fn ->
        ComponentStorage.delete_component(actor, name, "1.0.0", "acme", "catalyst")
      end)

    assert {:error, :not_found} = unboxed(fn -> held(actor, name).() end)
  end
end
