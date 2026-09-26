# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ProviderTest do
  @moduledoc """
  A provider's stream declarations: read through `Prima.Provider.streams/1`
  (none when it exports none), refused at the read when malformed, found
  by name among every provider's, and a subject admitted only by the
  stream's grammar whole. Beside them, what a stream grant forwards.
  """

  use ExUnit.Case, async: true

  alias Prima.Provider
  alias Prima.Provider.Stream, as: ProviderStream

  @deltas %ProviderStream{
    name: "executions.deltas",
    topic: :execution_events,
    projection: ["seq", "delta"],
    subject: ~S"\Aexec_[A-Za-z0-9-]{1,64}\z",
    deadline_bound: 600
  }

  defmodule Streaming do
    @moduledoc false
    def streams do
      [
        %Prima.Provider.Stream{
          name: "executions.deltas",
          topic: :execution_events,
          projection: ["seq", "delta"],
          subject: ~S"\Aexec_[A-Za-z0-9-]{1,64}\z",
          deadline_bound: 600
        },
        %Prima.Provider.Stream{
          name: "builds.progress",
          topic: :builds,
          projection: ["build_id", "status"],
          deadline_bound: 300
        }
      ]
    end
  end

  defmodule Silent do
    @moduledoc false
    def service, do: "silent"
  end

  defmodule Twice do
    @moduledoc false
    def streams,
      do:
        List.duplicate(
          %Prima.Provider.Stream{name: "a.b", topic: :x, projection: ["f"], deadline_bound: 1},
          2
        )
  end

  defmodule Unanchored do
    @moduledoc false
    def streams,
      do: [
        %Prima.Provider.Stream{
          name: "a.b",
          topic: :x,
          projection: ["f"],
          subject: "exec_.*",
          deadline_bound: 1
        }
      ]
  end

  test "a provider that exports no streams declares none" do
    assert Provider.streams(Silent) == []
  end

  test "a provider's declared streams are read whole" do
    assert [%ProviderStream{name: "executions.deltas"}, %ProviderStream{name: "builds.progress"}] =
             Provider.streams(Streaming)
  end

  test "a malformed declaration raises at the read, so the boot refuses it" do
    assert_raise ArgumentError, ~r/twice/, fn -> Provider.streams(Twice) end
    assert_raise ArgumentError, ~r/well-formed/, fn -> Provider.streams(Unanchored) end
  end

  test "a stream is well formed only with every field in its grammar" do
    assert ProviderStream.valid?(@deltas)
    refute ProviderStream.valid?(%{@deltas | name: "deltas"})
    refute ProviderStream.valid?(%{@deltas | topic: nil})
    refute ProviderStream.valid?(%{@deltas | topic: "execution_events"})
    refute ProviderStream.valid?(%{@deltas | projection: []})
    refute ProviderStream.valid?(%{@deltas | projection: ["seq", "seq"]})
    refute ProviderStream.valid?(%{@deltas | subject: ~S"\A(\z"})
    refute ProviderStream.valid?(%{@deltas | deadline_bound: 0})
    refute ProviderStream.valid?(%{name: "executions.deltas"})
  end

  test "a stream no provider declares is refused by name" do
    declared = Provider.streams(Streaming) ++ Provider.streams(Silent)

    assert {:ok, %ProviderStream{topic: :builds}} =
             Provider.fetch_stream(declared, "builds.progress")

    assert {:error, :undeclared_stream} = Provider.fetch_stream(declared, "vault.entries")
  end

  test "a subject is admitted only by the stream's grammar, whole" do
    assert ProviderStream.admits?(@deltas, "exec_01a09fee")
    refute ProviderStream.admits?(@deltas, "xexec_01a09fee")
    refute ProviderStream.admits?(@deltas, "exec_1 extra")
    refute ProviderStream.admits?(@deltas, nil)

    none = %{@deltas | subject: nil}
    assert ProviderStream.admits?(none, nil)
    refute ProviderStream.admits?(none, "exec_1")
  end

  test "a grant forwards its projection's fields and nothing else, and ends at its deadline" do
    now = ~U[2026-09-26 12:00:00Z]

    grant = %Prima.StreamGrant{
      topic: :execution_events,
      projection: ["seq", "delta"],
      subject: "exec_1",
      deadline: DateTime.add(now, 60, :second),
      grant_id: "sgr_1"
    }

    assert Prima.StreamGrant.project(grant, %{seq: 3, delta: "x", credential: "secret"}) ==
             %{"seq" => 3, "delta" => "x"}

    assert Prima.StreamGrant.project(grant, %{"seq" => 4}) == %{"seq" => 4}
    refute Prima.StreamGrant.expired?(grant, now)
    assert Prima.StreamGrant.expired?(grant, DateTime.add(now, 60, :second))
  end
end
