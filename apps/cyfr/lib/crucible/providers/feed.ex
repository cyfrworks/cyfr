# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Providers.Feed do
  @moduledoc """
  The `feed` tool and the two streams a canvas reads.

    * `bind` binds one component operation, its fixed arguments, an
      interval and labelled actions as a feed of the caller's athanor
      (`Crucible.Feeds.bind/2`). The operation's declared result shape is
      the shape of the `data` of its 2xx `{status, data}` envelope, and the
      binding copies it. It is external in kind, so the assistant always
      asks before it binds one.
    * `list` answers the athanor's live feeds: binding ids, names, labels,
      references, operations, intervals, result shapes, actions and the
      revision and time of the last accepted result. Never the arguments
      or a result's value.
    * `remove` removes a feed by its binding id (`Crucible.Feeds.remove/2`).
    * `press` presses one of a feed's actions by its binding id
      (`Crucible.Feeds.press/3`). It is external only: Prism calls it from
      a person's press of a declared control on the visible canvas, and a
      canvas's code has no verb that binds, changes or refreshes a feed.

  The streams (`streams/0`) are canvas-readable, each declaring a shape:

    * `feed.results` rides the athanor's one feeds topic, and its subject
      is a feed's name, which filters the payloads delivered (`filter:
      "feed"`) rather than naming a topic. Its refresh is the feed's last
      accepted envelope (`Crucible.Feeds.latest/2`).
    * `runs.changes` rides the athanor's executions topic, and takes no
      subject. Its refresh is the athanor's newest runs (`recent_runs/2`).
  """

  @behaviour Prima.Provider

  alias Crucible.Feeds
  alias Prima.Canvas.Shape
  alias Sanctum.Context

  # The newest runs a `runs.changes` subscriber is handed first.
  @recent_runs 20

  # A day: the longest a grant on either stream lives.
  @deadline_bound 86_400

  @impl true
  def service, do: "crucible"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    binding =
      Arg.new("binding", :string,
        required: true,
        description: "remove, press: the feed's binding id, as bind and list answer it"
      )

    Operation.tool(
      [
        Operation.new(
          "feed",
          "bind",
          "Bind a feed",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "bind: the feed's name, unique among the athanor's live feeds; a canvas reads " <>
                  "the feed by it"
            ),
            Arg.new("label", :string, required: true, description: "bind: the feed's label"),
            Arg.new("reference", :string,
              required: true,
              description:
                "bind: the catalyst or formula, versionless; its installed version is pinned"
            ),
            Arg.new("profile_id", :string,
              required: true,
              description:
                "bind: the profile the feed runs under; its grant must admit runs on a schedule"
            ),
            Arg.new("operation", :string,
              required: true,
              description:
                "bind: the operation the feed runs, one the component's manifest declares a " <>
                  "result shape for: the shape of the data of its 2xx {status, data} envelope"
            ),
            Arg.new("args", :json,
              required: true,
              description: "bind: the operation's fixed arguments, a JSON object"
            ),
            Arg.new("interval_minutes", :integer,
              required: true,
              description:
                "bind: how often the feed runs, in minutes: " <>
                  Enum.map_join(Prima.Feed.intervals(), ", ", &Integer.to_string/1)
            ),
            Arg.new("actions", :json,
              required: true,
              description:
                "bind: up to #{Prima.Feed.Binding.max_actions()} labelled actions a canvas may " <>
                  "show as controls, [{name, label, kind}]: a refresh reruns the feed; a run " <>
                  "runs its own operation and args and publishes nothing"
            )
          ],
          kind: :external,
          planes: [:external, :in_chain],
          permission: :execute
        ),
        Operation.new(
          "feed",
          "list",
          "List feeds",
          [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "feed",
          "remove",
          "Remove a feed",
          [binding],
          kind: :write,
          planes: [:external, :in_chain],
          permission: :execute
        ),
        Operation.new(
          "feed",
          "press",
          "Press a feed's action",
          [
            binding,
            Arg.new("action_name", :string,
              required: true,
              description: "press: the name of one of the feed's actions"
            )
          ],
          kind: :execute,
          planes: [:external],
          permission: :execute
        )
      ],
      description:
        "Your athanor's feeds: one component operation run on an interval, whose result a " <>
          "canvas reads by the feed's name. Bind, list and remove feeds, or press a feed's " <>
          "declared action.",
      title: "Feed"
    )
  end

  @impl true
  def handle("feed", %Context{} = ctx, %{"action" => "bind"} = args),
    do: Feeds.bind(ctx, args)

  def handle("feed", %Context{} = ctx, %{"action" => "list"}) do
    case Feeds.list(ctx) do
      {:ok, feeds} -> {:ok, %{feeds: Enum.map(feeds, &listed/1)}}
      {:error, :database_error} -> {:error, {:unavailable, "Feeds"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle("feed", %Context{} = ctx, %{"action" => "remove", "binding" => binding}),
    do: Feeds.remove(ctx, binding)

  def handle("feed", %Context{} = ctx, %{
        "action" => "press",
        "binding" => binding,
        "action_name" => action
      }),
      do: Feeds.press(ctx, binding, action)

  def handle(_name, _ctx, _args), do: {:error, :unknown_tool}

  @doc """
  The streams a canvas reads: `feed.results` and `runs.changes`, each with
  its shape and refresh (the moduledoc's).
  """
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "feed.results",
        topic: :feeds,
        projection: ["binding", "feed", "revision", "at", "result", "label", "actions"],
        subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
        deadline_bound: @deadline_bound,
        shape: feed_results_shape(),
        refresh: {Feeds, :latest},
        filter: "feed"
      },
      %Prima.Provider.Stream{
        name: "runs.changes",
        topic: :executions,
        projection: [
          "kind",
          "execution_id",
          "parent_execution_id",
          "reference",
          "component_type",
          "duration_ms",
          "error"
        ],
        deadline_bound: @deadline_bound,
        shape: runs_changes_shape(),
        refresh: {__MODULE__, :recent_runs}
      }
    ]
  end

  @doc """
  The refresh of `runs.changes`: the caller's athanor's #{@recent_runs}
  newest runs, read as the runs page reads them (`Crucible.Record.list/2`,
  scoped to the athanor), oldest first, each as the change it last made.
  A running or paused run reads as `started`; a run whose state is
  unknown is left out. An error is in the live payload's form, `class`
  and `message`: the record keeps its sentence as the message, and no
  class, so `class` is nil. The subject is none.
  """
  @spec recent_runs(Context.t(), nil) :: {:ok, [map()]} | {:error, term()}
  def recent_runs(%Context{athanor_id: athanor_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" do
    with {:ok, records} <- Crucible.Record.list(ctx, limit: @recent_runs) do
      {:ok, records |> Enum.flat_map(&run_change/1) |> Enum.reverse()}
    end
  end

  def recent_runs(%Context{}, _subject), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------

  # A feed as `list` answers it: never its arguments, an action's
  # arguments or a result's value.
  defp listed(%{binding_id: id, binding: binding} = feed) do
    %{
      binding: id,
      feed: binding.name,
      label: binding.label,
      reference: binding.reference,
      operation: binding.operation,
      interval_minutes: binding.interval_minutes,
      result_shape: binding.result_shape,
      actions:
        Enum.map(binding.actions, fn action ->
          %{name: action.name, label: action.label, kind: Atom.to_string(action.kind)}
        end),
      revision: feed.feed_result_seq,
      at: feed.feed_result_at && DateTime.to_iso8601(feed.feed_result_at)
    }
  end

  defp run_change(%Crucible.Record{status: status} = record)
       when status in [:running, :paused, :completed, :failed, :cancelled] do
    [
      %{
        "kind" => change_kind(status),
        "execution_id" => record.id,
        "parent_execution_id" => record.parent_execution_id,
        "reference" => record.reference,
        "component_type" => record.component_type && to_string(record.component_type),
        "duration_ms" => record.duration_ms,
        "error" => run_error(record.error)
      }
    ]
  end

  defp run_change(_unknown), do: []

  # The live payload's form of an error (`Cyfr.Bus.Execution`): its class
  # and its sentence. A record keeps the sentence alone, so its class is
  # unknown here.
  defp run_error(nil), do: nil
  defp run_error(message) when is_binary(message), do: %{"class" => nil, "message" => message}

  defp change_kind(status) when status in [:running, :paused], do: "started"
  defp change_kind(status), do: Atom.to_string(status)

  defp feed_results_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "binding" => %{"type" => "string", "max" => 64},
        "feed" => %{"type" => "string", "max" => 48},
        "revision" => %{"type" => "integer"},
        "at" => %{"type" => "time"},
        "result" => %{"type" => "json"},
        "label" => %{"type" => "string", "max" => 80},
        "actions" => %{
          "type" => "list",
          "max" => 8,
          "of" => %{
            "type" => "object",
            "fields" => %{
              "name" => %{"type" => "string", "max" => 48},
              "label" => %{"type" => "string", "max" => 40}
            },
            "required" => ["name", "label"]
          }
        }
      },
      "required" => ["binding", "feed", "revision", "at", "result", "label", "actions"]
    })
  end

  defp runs_changes_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["started", "completed", "failed", "cancelled"]},
        "execution_id" => %{"type" => "string"},
        "parent_execution_id" => %{"type" => "string", "nullable" => true},
        "reference" => %{"type" => "string"},
        "component_type" => %{"type" => "string", "nullable" => true},
        "duration_ms" => %{"type" => "integer", "nullable" => true},
        "error" => %{"type" => "json", "nullable" => true}
      },
      "required" => [
        "kind",
        "execution_id",
        "parent_execution_id",
        "reference",
        "component_type",
        "duration_ms",
        "error"
      ]
    })
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Shape.validate(shape)
    normalized
  end
end
