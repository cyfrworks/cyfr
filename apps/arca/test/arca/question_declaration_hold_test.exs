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
  being written waits for it and deletes the answer with the last
  release; an answer that comes while a removal is under way waits for
  it, and is refused and rolled back. Every write and deletion of a
  component's answers, and every removal of its releases, takes the
  component's lock first (`Arca.Questions.lock_component!/3`), so two
  removals, a removal and a deny for any caller, a removal and a
  forget, and two writes of one component run one at a time, and none
  deadlocks.

  Each actor below runs on a connection of its own and may pause after
  a statement it names; `state!/2` reads whether it paused there, waits
  on a lock, or is done.

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

  # An actor: `fun` run on a connection of its own, pausing once after
  # each statement a `pauses` predicate accepts, until the test sends it
  # `{:go, point}`. It tells the test its backend, each pause and its
  # result.
  defp actor!(tag, pauses, fun) do
    test = self()

    for {point, _accepts?} <- pauses,
        do: on_exit(fn -> :telemetry.detach({__MODULE__, tag, point}) end)

    Task.async(fn ->
      unboxed(fn ->
        me = self()
        send(test, {:backend, tag, backend!()})

        for {point, accepts?} <- pauses do
          handler = {__MODULE__, tag, point}

          :ok =
            :telemetry.attach(
              handler,
              [:arca, :repo, :query],
              fn _event, _measurements, meta, _config ->
                if self() == me and accepts?.(meta.query) do
                  :telemetry.detach(handler)
                  send(test, {:paused, tag, point})

                  receive do
                    {:go, ^point} -> :ok
                  after
                    30_000 -> :ok
                  end
                end
              end,
              nil
            )
        end

        result = fun.()
        send(test, {:done, tag, result})
        result
      end)
    end)
  end

  defp go(task, point), do: send(task.pid, {:go, point})

  # Where the actor `tag` (backend `backend`) stands, within five seconds:
  # `{:paused, point}`, `{:lock_wait, event}` or `{:done, result}`.
  defp state!(tag, backend, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    receive do
      {:paused, ^tag, point} -> {:paused, point}
      {:done, ^tag, result} -> {:done, result}
    after
      20 ->
        case unboxed(fn ->
               Arca.Repo.query!(
                 "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
                 [backend]
               )
             end) do
          %{rows: [["Lock", event]]} ->
            {:lock_wait, event}

          _running ->
            if System.monotonic_time(:millisecond) > deadline,
              do: flunk("#{tag} neither paused, waited on a lock nor finished"),
              else: state!(tag, backend, deadline)
        end
    end
  end

  defp backend_of!(tag) do
    assert_receive {:backend, ^tag, backend}, 5_000
    backend
  end

  # Every later pause of the actors let go at once, until each is done:
  # their results by tag.
  defp drive!(tasks) do
    for {tag, task} <- tasks, into: %{} do
      {tag, finish!(tag, task)}
    end
  end

  # The task's own reply, which `state!/2` never takes.
  defp finish!(tag, %Task{ref: ref} = task) do
    receive do
      {:paused, ^tag, point} ->
        go(task, point)
        finish!(tag, task)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      15_000 -> flunk("#{tag} did not finish")
    end
  end

  defp reads_components?(query), do: query =~ ~r/\ASELECT .* FROM "components"/s
  defp deletes_components?(query), do: String.starts_with?(query, ~s(DELETE FROM "components"))
  defp writes_answer?(query), do: String.starts_with?(query, ~s(INSERT INTO "question_answers"))
  defp deletes_answers?(query), do: String.starts_with?(query, ~s(DELETE FROM "question_answers"))

  defp catalysts(name) do
    unboxed(fn ->
      Arca.Repo.all(
        from(c in Component,
          where: c.athanor_id == ^@athanor and c.name == ^name,
          select: c.version
        )
      )
    end)
  end

  defp answers(actor, name) do
    {:ok, rows} = unboxed(fn -> Questions.standing(actor, @person, "acme", name) end)
    Enum.map(rows, &{&1.caller, &1.effect})
  end

  defp put!(actor, name, attrs),
    do:
      {:ok, _} =
        unboxed(fn ->
          Questions.put_standing(actor, Map.merge(standing(name), attrs),
            verify: held(actor, name)
          )
        end)

  defp remove(actor, name, version),
    do: fn -> ComponentStorage.delete_component(actor, name, version, "acme", "catalyst") end

  test "a removal that comes while the answer is written waits for it, and deletes it",
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
    Arca.Test.LockWait.await_lock_wait!(backend, [], event: "advisory")

    send(writing.pid, :commit)
    assert {:ok, %{name: ^name}} = Task.await(writing, 10_000)
    assert :ok = Task.await(removing, 10_000)

    # The removal of the last release deleted the answer the write left.
    assert {:ok, []} = unboxed(fn -> Questions.standing(actor, @person, "acme", name) end)
  end

  test "an answer that comes while a removal is under way waits for it, and is refused",
       %{actor: actor, name: name} do
    test = self()

    # An answer of the same identity already stands, so the second write
    # replaces a row the removal deletes.
    assert {:ok, _} =
             unboxed(fn ->
               Questions.put_standing(actor, standing(name), verify: held(actor, name))
             end)

    handler = {__MODULE__, :removing}
    on_exit(fn -> :telemetry.detach(handler) end)

    removing =
      Task.async(fn ->
        unboxed(fn ->
          remover = self()

          # Held inside its transaction once the release is deleted.
          :ok =
            :telemetry.attach(
              handler,
              [:arca, :repo, :query],
              fn _event, _measurements, meta, _config ->
                if self() == remover and
                     String.starts_with?(meta.query, ~s(DELETE FROM "components")) do
                  :telemetry.detach(handler)
                  send(test, :deleted)

                  receive do
                    :commit -> :ok
                  after
                    30_000 -> :ok
                  end
                end
              end,
              nil
            )

          ComponentStorage.delete_component(actor, name, "1.0.0", "acme", "catalyst")
        end)
      end)

    assert_receive :deleted, 5_000

    writing =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:writing, backend!()})
          Questions.put_standing(actor, standing(name), verify: held(actor, name))
        end)
      end)

    assert_receive {:writing, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend)

    send(removing.pid, :commit)
    assert :ok = Task.await(removing, 10_000)
    assert {:error, :not_found} = Task.await(writing, 10_000)
    assert {:ok, []} = unboxed(fn -> Questions.standing(actor, @person, "acme", name) end)
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

  test "two removals at once, with an allow granted between, leave no release and no allow",
       %{actor: actor, name: name} do
    unboxed(fn -> release!(name, "2.0.0", "delete a table") end)
    pauses = [read: &reads_components?/1, deleted: &deletes_components?/1]

    first = actor!(:first, pauses, remove(actor, name, "1.0.0"))
    first_backend = backend_of!(:first)
    assert {:paused, :read} = state!(:first, first_backend)

    second = actor!(:second, pauses, remove(actor, name, "2.0.0"))
    second_backend = backend_of!(:second)
    second_at = state!(:second, second_backend)

    granting =
      actor!(:grant, [], fn ->
        Questions.put_standing(actor, standing(name), verify: held(actor, name))
      end)

    granted_at = state!(:grant, backend_of!(:grant))

    # Each removal as far as it goes: both delete their version before
    # either asks what remains, where nothing holds them apart.
    go(first, :read)
    assert {:paused, :deleted} = state!(:first, first_backend)

    if second_at == {:paused, :read} do
      go(second, :read)
      assert {:paused, :deleted} = state!(:second, second_backend)
      go(second, :deleted)
    end

    go(first, :deleted)
    results = drive!(first: first, second: second, grant: granting)

    assert %{first: :ok, second: :ok} = results
    assert catalysts(name) == []
    assert answers(actor, name) == []

    # They ran one at a time: the second removal and the grant waited for
    # the first's lock.
    assert second_at == {:lock_wait, "advisory"}
    assert granted_at == {:lock_wait, "advisory"}
  end

  describe "a removal and a deny for any caller" do
    setup %{actor: actor, name: name} do
      put!(actor, name, %{caller: "key:key_1"})
      put!(actor, name, %{})
      :ok
    end

    test "the deny first: the removal waits, then deletes it and the release",
         %{actor: actor, name: name} do
      denying =
        actor!(:deny, [written: &writes_answer?/1], fn ->
          Questions.put_standing(actor, Map.put(standing(name), :effect, "deny"),
            verify: held(actor, name)
          )
        end)

      deny_backend = backend_of!(:deny)
      assert {:paused, :written} = state!(:deny, deny_backend)

      removing = actor!(:remove, [], remove(actor, name, "1.0.0"))
      removal_at = state!(:remove, backend_of!(:remove))

      go(denying, :written)
      results = drive!(deny: denying, remove: removing)

      assert %{deny: {:ok, %{effect: "deny"}}, remove: :ok} = results
      assert catalysts(name) == []
      assert answers(actor, name) == []
      assert removal_at == {:lock_wait, "advisory"}
    end

    test "the removal first: the deny waits, then is refused",
         %{actor: actor, name: name} do
      removing = actor!(:remove, [deleted: &deletes_components?/1], remove(actor, name, "1.0.0"))
      removal_backend = backend_of!(:remove)
      assert {:paused, :deleted} = state!(:remove, removal_backend)

      denying =
        actor!(:deny, [], fn ->
          Questions.put_standing(actor, Map.put(standing(name), :effect, "deny"),
            verify: held(actor, name)
          )
        end)

      deny_at = state!(:deny, backend_of!(:deny))

      go(removing, :deleted)
      results = drive!(remove: removing, deny: denying)

      assert %{remove: :ok, deny: {:error, :not_found}} = results
      assert catalysts(name) == []
      assert answers(actor, name) == []
      assert deny_at == {:lock_wait, "advisory"}
    end
  end

  test "a forget that comes while a removal is under way waits for it, and finds the answer gone",
       %{actor: actor, name: name} do
    {:ok, %{id: id}} =
      unboxed(fn -> Questions.put_standing(actor, standing(name), verify: held(actor, name)) end)

    removing = actor!(:remove, [deleted: &deletes_components?/1], remove(actor, name, "1.0.0"))
    removal_backend = backend_of!(:remove)
    assert {:paused, :deleted} = state!(:remove, removal_backend)

    forgetting = actor!(:forget, [], fn -> Questions.delete_standing(actor, id) end)
    forget_at = state!(:forget, backend_of!(:forget))

    go(removing, :deleted)
    results = drive!(remove: removing, forget: forgetting)

    assert %{remove: :ok, forget: {:error, :not_found}} = results
    assert answers(actor, name) == []
    assert forget_at == {:lock_wait, "advisory"}
  end

  test "two writes of one component's answers for different callers run one at a time",
       %{actor: actor, name: name} do
    put!(actor, name, %{caller: "key:key_1", effect: "deny"})

    # A deny for any caller, paused once it has deleted the allows for
    # single callers it found, before it commits.
    denying =
      actor!(:deny, [swept: &deletes_answers?/1], fn ->
        Questions.put_standing(actor, Map.put(standing(name), :effect, "deny"),
          verify: held(actor, name)
        )
      end)

    deny_backend = backend_of!(:deny)
    assert {:paused, :swept} = state!(:deny, deny_backend)

    # An allow for one caller, replacing its deny, while the deny is open.
    allowing =
      actor!(:allow, [], fn ->
        Questions.put_standing(actor, Map.put(standing(name), :caller, "key:key_1"),
          verify: held(actor, name)
        )
      end)

    allow_at = state!(:allow, backend_of!(:allow))

    go(denying, :swept)
    results = drive!(deny: denying, allow: allowing)
    assert %{deny: {:ok, _}, allow: {:ok, _}} = results

    # An allow that committed before the deny for any caller is one the
    # deny deleted; only one written after it stands.
    if match?({:done, _}, allow_at),
      do: assert(answers(actor, name) == [{"any", "deny"}]),
      else: assert(Enum.sort(answers(actor, name)) == [{"any", "deny"}, {"key:key_1", "allow"}])

    assert allow_at == {:lock_wait, "advisory"}
  end
end
