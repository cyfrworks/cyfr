# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Status do
  @moduledoc """
  The stream `system.changes`: how the person's CYFR stands, for a
  canvas to show (`Cyfr.Bus.SystemStatus`), one whole status at a time.
  It declares no tool.

  The stream rides the athanor's system topic (`Cyfr.Bus.system/1`) and
  takes no subject. Its refresh is the status read now under the
  subscriber's context, which also has the watch (`Aqua.Status`) keep the
  athanor, so every later change is told live; `Aqua.Status` reads each
  field from its source.

  It lives in the assistant's domain because the brains are read there:
  the host (`Cyfr`) depends on the identity domain and storage alone, and
  names no domain above them (`Cyfr.Boundaries`), so Aqua, which reads
  every other fact below it, is the lowest owner that can read the model
  and the crew.
  """

  @behaviour Prima.Provider

  alias Prima.Canvas.Shape
  alias Sanctum.Context

  # A day: the longest a grant on the stream lives.
  @deadline_bound 86_400

  @impl true
  def service, do: "aqua"

  @impl true
  def tools, do: []

  @impl true
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "Tool", tool}}

  @doc "The stream `system.changes` (the moduledoc's)."
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "system.changes",
        topic: :system,
        projection: [
          "kind",
          "health",
          "storage_used",
          "storage_cap",
          "model_connected",
          "crew_ready",
          "crew_total",
          "version",
          "update_available"
        ],
        deadline_bound: @deadline_bound,
        shape: shape(),
        refresh: {__MODULE__, :status}
      }
    ]
  end

  @doc """
  The refresh of `system.changes`: the context's athanor's status as it
  reads now (`Aqua.Status.read/1`), which the watch keeps as told. The
  subject is none.
  """
  @spec status(Context.t(), nil) :: {:ok, [Cyfr.Bus.SystemStatus.t()]} | {:error, :no_athanor}
  def status(%Context{athanor_id: athanor_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" do
    status = Aqua.Status.read(ctx)
    :ok = Aqua.Status.watch(ctx, status)
    {:ok, [status]}
  end

  def status(%Context{}, _subject), do: {:error, :no_athanor}

  defp shape do
    count = %{"type" => "integer", "nullable" => true}

    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{
          "type" => "enum",
          "values" => Enum.map(Cyfr.Bus.SystemStatus.kinds(), &Atom.to_string/1)
        },
        "health" => %{
          "type" => "enum",
          "values" => ["ok", "degraded", "low_storage"],
          "nullable" => true
        },
        "storage_used" => count,
        "storage_cap" => count,
        "model_connected" => %{"type" => "boolean", "nullable" => true},
        "crew_ready" => count,
        "crew_total" => count,
        "version" => %{"type" => "string"},
        "update_available" => %{"type" => "boolean", "nullable" => true}
      },
      "required" => [
        "kind",
        "health",
        "storage_used",
        "storage_cap",
        "model_connected",
        "crew_ready",
        "crew_total",
        "version",
        "update_available"
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
