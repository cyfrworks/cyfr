# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Probe do
  @moduledoc """
  The probe providers tests plant in the operation table.

  Each is a provider as the table loads one — `tools/0` declaring its
  operations, `handle/3` answering them — planted for one block with
  `Grimoire.Catalog.with_providers/2`, which rebuilds the table with the
  configured providers and the probes, runs the block, and puts the table
  back. A test that plants one runs `async: false`: the table is the
  member's, and a concurrent test would see the probe.
  """
end

defmodule Grimoire.Probe.Crashing do
  @moduledoc """
  Fails the way a real provider would: by raising or exiting rather than
  returning an error tuple, or raising the refusal a tenant gate raises.
  """
  @behaviour Prima.Provider

  alias Prima.Operation

  @tool "crash_barrier_test_tool"

  @doc "The probe's tool name."
  def tool, do: @tool

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool(
        for action <- ~w(raise exit unauthorized ok) do
          Operation.new(@tool, action, "Crash barrier probe", [],
            kind: if(action == "ok", do: :read, else: :execute),
            planes: [:external]
          )
        end
      )
    ]
  end

  @impl true
  def handle(_tool, _ctx, %{"action" => "raise"}), do: raise("boom from provider")
  def handle(_tool, _ctx, %{"action" => "exit"}), do: exit(:provider_exit)

  def handle(_tool, _ctx, %{"action" => "unauthorized"}),
    do: raise(Sanctum.UnauthorizedError, reason: :missing_tenant)

  def handle(_tool, _ctx, _args), do: {:ok, %{"ok" => true}}
end

defmodule Grimoire.Probe.Blocking do
  @moduledoc """
  Stays in flight. It announces its own pid to the process registered as
  `:catalog_blocking_observer` first, so a test can assert on the
  dispatcher's bookkeeping while the call is provably still running.
  Asked to, it answers at once with the process it ran on, crashes, or
  raises the refusal a handler's tenant gate raises.
  """
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @tool "cancellation_test_tool"

  @doc "The probe's tool name."
  def tool, do: @tool

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new(
          @tool,
          "block",
          "Cancellation probe",
          [
            Arg.new("crash", :boolean),
            Arg.new("refuse", :boolean),
            Arg.new("release", :boolean)
          ],
          kind: :execute,
          planes: [:external]
        )
      ])
    ]
  end

  @impl true
  def handle(_tool, _ctx, %{"crash" => true}), do: raise("boom from provider")

  def handle(_tool, _ctx, %{"refuse" => true}),
    do: raise(Sanctum.UnauthorizedError, reason: :missing_tenant)

  def handle(_tool, _ctx, %{"release" => true}), do: {:ok, %{ran_on: self()}}

  def handle(_tool, _ctx, _args) do
    send(:catalog_blocking_observer, {:handler_running, self()})
    Process.sleep(:infinity)
  end
end

defmodule Grimoire.Probe.Typed do
  @moduledoc """
  Echoes the arguments the gate cast, on both planes, for the typed
  argument contract: arrays of records, bounds, patterns, enums, and one
  action gated by a permission.
  """
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new(
          "typed_probe",
          "echo",
          "Echo declared values",
          [
            Arg.new(
              "values",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("count", :integer, required: true, min: 0, max: 2)
                  ]}
               )},
              required: true,
              min: 1,
              max: 2
            ),
            Arg.new("label", :string, nullable: true, min: 1, max: 3, pattern: "^[a-z]+$"),
            Arg.new("enabled", :boolean),
            Arg.new("mode", :string, enum: ["auto", "ask"])
          ],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new("typed_probe", "empty", "No arguments", [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "typed_probe",
          "admin_echo",
          "Gated echo",
          [Arg.new("secret", :string, required: true)],
          kind: :read,
          planes: [:external, :in_chain],
          permission: :admin
        )
      ])
    ]
  end

  @impl true
  def handle(_name, _ctx, args), do: {:ok, args}
end

defmodule Grimoire.Probe.TypedChanged do
  @moduledoc """
  `Grimoire.Probe.Typed` with its `empty` action changed to require an
  `id`: the same tool declared again, so a test can see the table derive
  its views from the declarations it was built with.
  """
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [%{operations: [echo, empty, _admin]} = typed] = Grimoire.Probe.Typed.tools()
    changed = %{empty | args: [Arg.new("id", :string, required: true)]}
    [Operation.tool([echo, changed], description: typed.description)]
  end

  @impl true
  def handle(_name, _ctx, args), do: {:ok, args}
end

defmodule Grimoire.Probe.Ingress do
  @moduledoc """
  Records exactly what it was handed, so a test can tell "refused before
  dispatch" from "the handler coped": the provider runs in a task, not
  the test process, so the signal goes to the process registered as
  `:ingress_probe_observer`.
  """
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new("ingress_probe", "echo", "Echo", [Arg.new("id", :string)],
          kind: :read,
          planes: [:external]
        )
      ]),
      Operation.tool([
        Operation.new("ingress_probe_bare", "echo", "Echo", [], kind: :read, planes: [:external])
      ])
    ]
  end

  @impl true
  def handle("ingress_probe", _ctx, %{"action" => "echo"} = args) do
    send(:ingress_probe_observer, {:reached_handler, args})
    {:ok, %{ok: true}}
  end

  def handle(_tool, _ctx, _args), do: {:error, "unknown action"}
end

defmodule Grimoire.Probe.List do
  @moduledoc """
  Answers each list shape a console page meets: a list under a key, a
  bare list, a map with no list, and a refusal sentence.
  """
  @behaviour Prima.Provider

  alias Prima.Operation

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool(
        for action <- ~w(wrapped bare shapeless refused) do
          Operation.new("helper_list_probe", action, "List probe", [],
            kind: :read,
            planes: [:external]
          )
        end
      )
    ]
  end

  @impl true
  def handle("helper_list_probe", _ctx, %{"action" => "wrapped"}),
    do: {:ok, %{items: [%{id: 1}]}}

  def handle("helper_list_probe", _ctx, %{"action" => "bare"}), do: {:ok, [%{id: 2}]}
  def handle("helper_list_probe", _ctx, %{"action" => "shapeless"}), do: {:ok, %{count: 3}}
  def handle("helper_list_probe", _ctx, %{"action" => "refused"}), do: {:error, "Not allowed."}
end

defmodule Grimoire.Probe.Input do
  @moduledoc """
  Answers the input the gate handed its handler, on both planes: as an
  `:actor` provider (`Grimoire.Probe.Input.Actor`, tool `actor_probe`) or
  a `:context` one (`Grimoire.Probe.Input.Context`, tool
  `context_probe`).
  """

  alias Prima.Operation

  @doc "The one `peek` action a probe named `name` declares."
  def tool(name) do
    Operation.tool([
      Operation.new(name, "peek", "Answer the handler's input", [],
        kind: :read,
        planes: [:external, :in_chain]
      )
    ])
  end
end

defmodule Grimoire.Probe.Input.Actor do
  @moduledoc false
  @behaviour Prima.Provider

  @impl true
  def service, do: "probe"

  @impl true
  def context_kind, do: :actor

  @impl true
  def tools, do: [Grimoire.Probe.Input.tool("actor_probe")]

  @impl true
  def handle(_name, input, _args), do: {:ok, %{input: input}}
end

defmodule Grimoire.Probe.Input.Context do
  @moduledoc false
  @behaviour Prima.Provider

  @impl true
  def service, do: "probe"

  @impl true
  def tools, do: [Grimoire.Probe.Input.tool("context_probe")]

  @impl true
  def handle(_name, input, _args), do: {:ok, %{input: input}}
end

defmodule Grimoire.Probe.Refusing do
  @moduledoc """
  Refuses from inside its handler, in the vocabulary the gate refuses in:
  an argument the handler judged (`invalid`) and a permission the handler
  checked (`forbidden`) — so a test can tell the tool's own refusal from
  the gate's refusal of the same class. `n` is a declared integer, for the
  gate's own argument refusal.
  """
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool(
        for action <- ~w(invalid forbidden) do
          Operation.new(
            "refusing_probe",
            action,
            "Refuse from the handler",
            [
              Arg.new("n", :integer)
            ],
            kind: :read,
            planes: [:external]
          )
        end
      )
    ]
  end

  @impl true
  def handle(_tool, _ctx, %{"action" => "invalid"}),
    do: {:error, {:invalid_argument, "the handler refused this argument"}}

  def handle(_tool, _ctx, %{"action" => "forbidden"}),
    do: {:error, {:missing_permission, :admin}}
end
