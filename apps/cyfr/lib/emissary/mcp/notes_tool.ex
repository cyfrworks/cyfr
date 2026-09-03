# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.NotesTool do
  @moduledoc """
  The `notes` tool: what somebody kept out of a conversation, on the wire.

  The domain is `Aqua.Notes`; this module is its door, and two gates sit on
  it on two axes. The storage root is host-only — `Arca.Storage`'s layout
  gives `notes/` no guest name — so a WASM guest cannot name it at all. And
  every action declares `consent: :interactive`: a note is kept, read and
  forgotten by a person's own session, never by a standing credential. An
  API key (a `*` key included) is refused at the registry's dispatch gate
  and does not see the tool in `tools/list`. Same two axes, same reason, as
  the `conversation` tool.

  ## Where a note lands

  Writes take no scope: `keep`, `pin` and `forget` act on the estate in
  focus — your own athanor when you are talking to your own assistant, the
  room's when you are in a room. Reads take one: `estate` (the default),
  `mine`, or `everywhere` you hold a seat.

  ## What a person may pre-answer

  `keep` may be granted standing for one conversation and no wider
  (`standing: :conversation`); `pin` never (`standing: false`), because a
  pinned page is read into every turn and each change to it deserves a
  click; `forget` is destructive and already takes no standing allow. The
  annotation is the one source for every gate that honours it.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Aqua.Notes
  alias Sanctum.Context

  @writes ~w(keep pin forget)

  @impl true
  def service, do: "notes"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    %{
      name: "notes",
      title: "Notes",
      description:
        "What was kept out of a conversation. Distinct from the transcript: erasing a " <>
          "thread does not erase what someone kept from it. A note lands in the estate " <>
          "you are working in; two pinned pages (about-you, about-us) are read into " <>
          "every turn and held short.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          # External plane only. Keeping something is a person's act, and
          # the root is host-only for the same sentence — an agent that
          # could write here would be deciding what to remember about you.
          "keep" => %{
            kind: :write,
            planes: [:external],
            consent: :interactive,
            standing: :conversation
          },
          "pin" => %{kind: :write, planes: [:external], consent: :interactive, standing: false},
          "forget" => %{kind: :destructive, planes: [:external], consent: :interactive},
          "list" => %{kind: :read, planes: [:external], consent: :interactive},
          "read" => %{kind: :read, planes: [:external], consent: :interactive},
          "search" => %{kind: :read, planes: [:external], consent: :interactive}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["keep", "pin", "list", "read", "forget", "search"]
          },
          "name" => %{
            "type" => "string",
            "description" => "What the note is called (keep, pin, read, forget)"
          },
          "content" => %{
            "type" => "string",
            "description" => "keep: what to file. pin: the page — empty content clears it"
          },
          "query" => %{
            "type" => "string",
            "description" => "search: text to find in a note's name or body"
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["estate", "mine", "everywhere"],
            "description" =>
              "Reads only: where to look — the estate in focus (default), your own " <>
                "athanor, or every estate you belong to. Writes take none; a note " <>
                "lands where you are."
          }
        },
        "required" => ["action"]
      }
    }
  end

  @impl true
  def handle("notes", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # ---------------------------------------------------------------------------

  # A write that names an estate is refused rather than obeyed or ignored:
  # the caller believed the argument meant something, and the one thing it
  # must never mean is "somewhere other than here".
  defp dispatch(_ctx, %{"action" => action, "scope" => _}) when action in @writes do
    {:error,
     {:invalid_argument,
      "#{action} takes no scope — a note lands in the estate you are working in"}}
  end

  defp dispatch(ctx, %{"action" => "keep", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.keep(ctx, name, content, provenance(args))

  defp dispatch(_ctx, %{"action" => "keep"}),
    do: {:error, {:invalid_argument, "keep requires 'name' and 'content'"}}

  defp dispatch(ctx, %{"action" => "pin", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.pin(ctx, name, content, provenance(args))

  defp dispatch(_ctx, %{"action" => "pin"}),
    do: {:error, {:invalid_argument, "pin requires 'name' and 'content' (empty content clears)"}}

  defp dispatch(ctx, %{"action" => "forget", "name" => name}) when is_binary(name),
    do: Notes.forget(ctx, name)

  defp dispatch(_ctx, %{"action" => "forget"}),
    do: {:error, {:invalid_argument, "forget requires 'name'"}}

  defp dispatch(ctx, %{"action" => "list"} = args) do
    with {:ok, notes} <- Notes.list(ctx, scope(args)) do
      {:ok, %{notes: notes, scope: scope(args)}}
    end
  end

  defp dispatch(ctx, %{"action" => "read", "name" => name} = args) when is_binary(name),
    do: Notes.read(ctx, name, scope(args))

  defp dispatch(_ctx, %{"action" => "read"}),
    do: {:error, {:invalid_argument, "read requires 'name'"}}

  defp dispatch(ctx, %{"action" => "search", "query" => query} = args) when is_binary(query) do
    with {:ok, matches} <- Notes.search(ctx, query, scope(args)) do
      {:ok, %{matches: matches, scope: scope(args)}}
    end
  end

  defp dispatch(_ctx, %{"action" => "search"}),
    do: {:error, {:invalid_argument, "search requires 'query'"}}

  defp dispatch(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "notes.#{action}"}}
  defp dispatch(_ctx, _args), do: {:error, :action_missing}

  defp scope(args), do: Map.get(args, "scope", "estate")

  # The execution a note was kept from rides in as the host-supplied
  # lineage of an in-chain call; a call from the external door has none.
  defp provenance(args),
    do: [execution: args["root_execution_id"] || args["parent_execution_id"]]
end
