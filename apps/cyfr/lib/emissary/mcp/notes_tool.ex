# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.NotesTool do
  @moduledoc """
  The `notes` tool: what somebody kept out of a conversation, on the wire.

  The domain is `Aqua.Notes`; this module is its door, and two gates sit on
  it on two axes. The storage root is host-only — `Arca.Storage`'s layout
  gives `notes/` no guest name — so a WASM guest cannot name it as a path.
  And every action declares `consent: :interactive`: a note is kept, read
  and forgotten by a person's own session, never by a standing credential.
  An API key (a `*` key included) is refused at the registry's dispatch
  gate and does not see the tool in `tools/list`.

  The actions are reachable in-chain too, which is how an agent keeps a
  note at all: it proposes, a person clicks, and the approved call runs
  inside the chain under the turn's authority. The consent class keeps its
  surface half there — only an `:oidc` session's chain gets through — so
  the same formula started by a key or a schedule is refused exactly as at
  the door. A running chain reads across estates only from the person's
  own athanor (`Aqua.Notes`); a room's assistant sees the room's pile.

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

  @behaviour Cyfr.Ops.Provider

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
          # In-chain as well as at the door: the writes are `ask` in the
          # soul's policy, so from a chain each one is a card a person
          # clicked; the reads are `auto`, bounded to the room by the
          # domain. Interactive on every action — the credential gate is
          # the same on both planes.
          "keep" => %{
            kind: :write,
            planes: [:external, :in_chain],
            consent: :interactive,
            standing: :conversation
          },
          "pin" => %{
            kind: :write,
            planes: [:external, :in_chain],
            consent: :interactive,
            standing: false
          },
          "forget" => %{
            kind: :destructive,
            planes: [:external, :in_chain],
            consent: :interactive
          },
          "list" => %{
            kind: :read,
            planes: [:external, :in_chain],
            consent: :interactive,
            recovery: :replay_safe
          },
          "read" => %{
            kind: :read,
            planes: [:external, :in_chain],
            consent: :interactive,
            recovery: :replay_safe
          },
          "search" => %{
            kind: :read,
            planes: [:external, :in_chain],
            consent: :interactive,
            recovery: :replay_safe
          }
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
          },
          "athanor_id" => %{
            "type" => "string",
            "description" =>
              "read: the estate a search answered for the note — reads it there, " <>
                "under your own seat."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => Notes.page_max(),
            "description" => "list, search: how many to answer at most (default 100)."
          },
          "after" => %{
            "type" => "string",
            "description" => "list, search: the `next` cursor a previous page answered."
          },
          "conversation" => %{
            "type" => "string",
            "description" =>
              "keep, pin, at the door: provenance — the conversation the note was kept " <>
                "from. In a chain the host stamps it and this is ignored."
          },
          "execution" => %{
            "type" => "string",
            "description" =>
              "keep, pin, at the door: provenance — the execution the note was kept from. " <>
                "In a chain the host stamps it and this is ignored."
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
       do: Notes.keep(ctx, name, content, provenance(args, ctx))

  defp dispatch(_ctx, %{"action" => "keep"}),
    do: {:error, {:invalid_argument, "keep requires 'name' and 'content'"}}

  defp dispatch(ctx, %{"action" => "pin", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.pin(ctx, name, content, provenance(args, ctx))

  defp dispatch(_ctx, %{"action" => "pin"}),
    do: {:error, {:invalid_argument, "pin requires 'name' and 'content' (empty content clears)"}}

  defp dispatch(ctx, %{"action" => "forget", "name" => name}) when is_binary(name),
    do: Notes.forget(ctx, name)

  defp dispatch(_ctx, %{"action" => "forget"}),
    do: {:error, {:invalid_argument, "forget requires 'name'"}}

  defp dispatch(ctx, %{"action" => "list"} = args) do
    with {:ok, page} <- Notes.list(ctx, scope(args), page(args)) do
      {:ok, Map.put(page, :scope, scope(args))}
    end
  end

  defp dispatch(ctx, %{"action" => "read", "name" => name} = args) when is_binary(name),
    do: Notes.read(ctx, name, scope(args), athanor_id: args["athanor_id"])

  defp dispatch(_ctx, %{"action" => "read"}),
    do: {:error, {:invalid_argument, "read requires 'name'"}}

  defp dispatch(ctx, %{"action" => "search", "query" => query} = args) when is_binary(query) do
    with {:ok, %{notes: matches} = page} <- Notes.search(ctx, query, scope(args), page(args)) do
      {:ok, page |> Map.delete(:notes) |> Map.merge(%{matches: matches, scope: scope(args)})}
    end
  end

  defp dispatch(_ctx, %{"action" => "search"}),
    do: {:error, {:invalid_argument, "search requires 'query'"}}

  defp dispatch(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "notes.#{action}"}}
  defp dispatch(_ctx, _args), do: {:error, :action_missing}

  defp scope(args), do: Map.get(args, "scope", "estate")

  defp page(args), do: [limit: args["limit"], after: args["after"]]

  # Where a note was kept from. In a chain the registry stamps the
  # execution and the conversation onto the call as host-only keys
  # (`Cyfr.Ops.Catalog`'s lineage), and those are the only
  # provenance read there — a value the model put under `conversation` or
  # `execution` is ignored, never recorded. At the door a person says
  # what they choose to.
  defp provenance(args, %Context{plane: :guest}) do
    [
      conversation: args["conversation_id"],
      execution: args["root_execution_id"] || args["parent_execution_id"]
    ]
  end

  defp provenance(args, _ctx) do
    [conversation: args["conversation"], execution: args["execution"]]
  end
end
