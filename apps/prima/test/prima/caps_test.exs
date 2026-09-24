# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CapsTest.Stub do
  @moduledoc false
  @behaviour Prima.Caps

  @ceiling 3
  @bytes 100

  @impl true
  def check_counted(actor, key, count) do
    send(self(), {:check_counted, actor, key})

    case count.() do
      {:ok, current} when current < @ceiling -> :ok
      {:ok, _current} -> {:error, {:limit_reached, key, @ceiling}}
      {:error, _reason} -> {:error, {:cap_unverifiable, key}}
    end
  end

  @impl true
  def check_storage(actor, incoming) do
    send(self(), {:check_storage, actor, incoming})

    if incoming > @bytes,
      do: {:error, {:limit_reached, :athanor_storage_bytes, @bytes}},
      else: :ok
  end
end

defmodule Prima.CapsTest.Partial do
  @moduledoc false
  def check_storage(_actor, _incoming), do: :ok
end

defmodule Prima.CapsTest do
  @moduledoc """
  The cap port: the ceilings Arca asks about without naming the tenancy
  domain above it. The port is installed once at boot and asked
  actor-first; an uninstalled port raises where it was asked rather than
  reading as a server with no caps.

  The port owns a `:persistent_term`, so these tests are synchronous and
  leave it as they found it.
  """
  use ExUnit.Case, async: false

  alias Prima.Actor
  alias Prima.Caps
  alias Prima.Caps.NotInstalledError
  alias Prima.CapsTest.Partial
  alias Prima.CapsTest.Stub

  @actor %Actor{athanor_id: "ath_01a09fee", user_id: "usr_01a09fee", authenticated: true}

  setup do
    installed =
      try do
        {:installed, Caps.impl()}
      rescue
        NotInstalledError -> :none
      end

    on_exit(fn ->
      case installed do
        {:installed, module} -> Caps.install!(module)
        :none -> Caps.reset()
      end
    end)

    :ok
  end

  describe "impl/0 before the boot write" do
    test "raises its named error, saying what is missing" do
      Caps.reset()

      error = assert_raise NotInstalledError, fn -> Caps.impl() end

      assert error.message =~ "Prima.Caps.install!/1"
      assert error.message =~ "no installed implementation"
    end

    test "every check refuses through it — an uninstalled port is not a cap that is off" do
      Caps.reset()

      assert_raise NotInstalledError, fn ->
        Caps.check_counted(@actor, :max_athanors, fn -> {:ok, 0} end)
      end

      assert_raise NotInstalledError, fn -> Caps.check_storage(@actor, 1) end
    end
  end

  describe "install!/1" do
    test "writes the implementation impl/0 reads" do
      assert Stub == Caps.install!(Stub)
      assert Caps.impl() == Stub
    end

    test "refuses a module that does not answer both questions" do
      Caps.reset()

      for module <- [Partial, Prima.Actor, Prima.CapsTest.NoSuchModule] do
        assert_raise ArgumentError, ~r/does not implement Prima.Caps/, fn ->
          Caps.install!(module)
        end
      end

      # A refused install leaves the port uninstalled, not half-wired.
      assert_raise NotInstalledError, fn -> Caps.impl() end
    end
  end

  describe "check_counted/3" do
    setup do
      Caps.install!(Stub)
      :ok
    end

    test "passes the actor and the key through, and counts only what it is given" do
      assert :ok = Caps.check_counted(@actor, :max_threads_per_athanor, fn -> {:ok, 1} end)
      assert_received {:check_counted, actor, :max_threads_per_athanor}
      assert actor == @actor
    end

    test "carries the ceiling and the unanswerable count back unchanged" do
      assert {:error, {:limit_reached, :max_athanors, 3}} =
               Caps.check_counted(@actor, :max_athanors, fn -> {:ok, 3} end)

      assert {:error, {:cap_unverifiable, :max_athanors}} =
               Caps.check_counted(@actor, :max_athanors, fn -> {:error, :database_error} end)
    end

    test "takes the actor first, and only a key it knows" do
      counter = fn -> {:ok, 0} end

      # A bare athanor id, a key outside the vocabulary, a count that
      # cannot be run. `apply/3` keeps the deliberate misuse out of the
      # compiler's inference: the refusal under test is the run-time guard.
      for args <- [
            ["ath_01a09fee", :max_athanors, counter],
            [@actor, :max_widgets, counter],
            [@actor, :max_athanors, 0]
          ] do
        assert_raise FunctionClauseError, fn -> apply(Caps, :check_counted, args) end
      end
    end
  end

  describe "check_storage/2" do
    setup do
      Caps.install!(Stub)
      :ok
    end

    test "passes the actor and the incoming bytes through" do
      assert :ok = Caps.check_storage(@actor, 50)
      assert_received {:check_storage, actor, 50}
      assert actor == @actor

      assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
               Caps.check_storage(@actor, 101)
    end

    test "takes the actor first, and a byte count that is a count" do
      for args <- [["ath_01a09fee", 50], [@actor, -1], [@actor, "50"]] do
        assert_raise FunctionClauseError, fn -> apply(Caps, :check_storage, args) end
      end
    end

    test "the server's own actor is asked like any other caller" do
      assert :ok = Caps.check_storage(Actor.system(), 1)
      assert_received {:check_storage, system, 1}
      assert system.system
      assert system.scope == :platform
    end
  end

  test "keys/0 is the shared vocabulary, one atom per ceiling" do
    assert Caps.keys() == [
             :max_athanors,
             :max_groups_per_person,
             :max_pairs_per_person,
             :max_members_per_group,
             :max_threads_per_athanor,
             :mint_per_hour,
             :athanor_storage_bytes
           ]

    assert Enum.uniq(Caps.keys()) == Caps.keys()
  end
end
