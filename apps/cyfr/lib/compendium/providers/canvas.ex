# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Canvas do
  @moduledoc """
  The `canvas` tool: a person's canvases, each a tincture whose placement
  is `canvas`, read and written through `Compendium.Canvas`.

    * `catalog` answers what a canvas may read: the toolkit majors and
      every canvas-readable stream with its subject grammar, shape, filter
      and whether it refreshes. Shapes, never values.
    * `versions` answers a canvas's versions document (which version a
      glass opens, which one is kept, which validation last failed) and
      its revision.
    * `write` writes a new canvas version whole, its module and the
      streams it reads, after allocating its version number, and
      registers it. It never edits a version and activates nothing.
    * `activate` reports a glass's trial of a version under its frame's
      validation credential, which it spends; only a tree activates, and
      only under the canvas's current grant. Prism calls it, from outside
      any chain.
    * `restore` makes the kept version the working one again, while it
      is still installed and under today's grant. Outside any chain, as
      safe mode offers it.

  Every action runs under the caller's context, in the athanor in focus.
  """

  @behaviour Prima.Provider

  alias Sanctum.Context

  @impl true
  def service, do: "compendium"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "canvas",
          "catalog",
          "What a canvas may read",
          [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "canvas",
          "versions",
          "A canvas's versions",
          [
            Arg.new("canvas", :string,
              required: true,
              description: "versions: the canvas's name"
            )
          ],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "canvas",
          "write",
          "Write a new canvas version",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "write: the canvas's name, a component name; a new name is a new canvas"
            ),
            Arg.new("module", :string,
              required: true,
              description:
                "write: the canvas's module, the JavaScript the toolkit runs " <>
                  "(at most #{Compendium.Canvas.module_max_bytes()} bytes)"
            ),
            Arg.new("streams", :json,
              required: true,
              description:
                "write: the streams the canvas reads, [{name, subject}], from catalog's " <>
                  "streams; a feed's results name the feed as the subject"
            )
          ],
          kind: :write,
          planes: [:external, :in_chain],
          permission: :execute
        ),
        Operation.new(
          "canvas",
          "activate",
          "Report a canvas version's validation",
          [
            Arg.new("canvas", :string,
              required: true,
              description: "activate: the canvas's name"
            ),
            Arg.new("version", :string,
              required: true,
              description: "activate: the version the glass trialled"
            ),
            Arg.new("frame", :string,
              required: true,
              description: "activate: the id of the frame the version was trialled in"
            ),
            Arg.new("outcome", :string,
              required: true,
              enum: Compendium.Canvas.outcomes(),
              description: "activate: what the trial answered; only a tree activates"
            )
          ],
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "canvas",
          "restore",
          "Restore a canvas's kept version",
          [
            Arg.new("canvas", :string, required: true, description: "restore: the canvas's name")
          ],
          kind: :write,
          planes: [:external]
        )
      ],
      description:
        "Your canvases: what a canvas may read, each canvas's versions, writing a new " <>
          "version, and the validation that activates one or the way back to the kept one.",
      title: "Canvas"
    )
  end

  @impl true
  def handle("canvas", %Context{} = ctx, %{"action" => "catalog"}),
    do: Compendium.Canvas.catalog(ctx)

  def handle("canvas", %Context{} = ctx, %{"action" => "versions"} = args),
    do: Compendium.Canvas.versions(ctx, Map.get(args, "canvas"))

  def handle("canvas", %Context{} = ctx, %{"action" => "write"} = args),
    do: Compendium.Canvas.write(ctx, args)

  def handle("canvas", %Context{} = ctx, %{"action" => "activate"} = args),
    do: Compendium.Canvas.activate(ctx, args)

  def handle("canvas", %Context{} = ctx, %{"action" => "restore"} = args),
    do: Compendium.Canvas.restore(ctx, Map.get(args, "canvas"))

  def handle(_name, _ctx, _args), do: {:error, :unknown_tool}
end
