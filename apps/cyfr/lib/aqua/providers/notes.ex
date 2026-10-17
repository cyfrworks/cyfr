# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Notes do
  @moduledoc """
  The `notes` tool: what somebody kept out of a thread, on the wire.

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
  the door. A running chain reads across athanors only from the person's
  own athanor (`Aqua.Notes`); a room's assistant sees the room's pile.

  ## Where a note lands

  Writes take no scope: `keep`, `pin` and `forget` act on the athanor in
  focus — your own athanor when you are talking to your own assistant, the
  room's when you are in a room. Reads take one: `athanor` (the default),
  `mine`, or `everywhere` you hold a seat.

  ## What a person may pre-answer

  `keep` may be granted standing for one thread and no wider
  (`standing: :thread`); `pin` never (`standing: false`), because a
  pinned page is read into every turn and each change to it deserves a
  click; `endorse` never either, since it makes outside material the
  person's own; `forget` is destructive and already takes no standing
  allow. The annotation is the one source for every gate that honours it.

  ## Provenance and outside material

  A note kept in a chain carries in its provenance every source the
  chain's turns read (`Aqua.Notes.chain_sources/2`) and the calling
  execution's own ledger (`Opus.sources/2`), both read from the
  host-stamped lineage, never from what the model wrote, so a turn or a
  guest that reads it later reads them too, and a component that runs no
  turn keeps what it read as a turn does: a note made from a
  disclosed vault value carries `vault_disclosed`, whatever admitted the
  keep. Of those, the outside sources make it outside material, shown
  attributed and endorsable: an approval admits the action and never
  endorses the content. Pins are not marked. `endorse` is the one
  clearing, of the outside sources only: it names the sources the note
  carries, so the card a person approves shows them, and it writes only
  while the note still carries exactly those.
  """

  @behaviour Prima.Provider

  alias Aqua.Notes
  alias Sanctum.Context

  @writes ~w(keep pin forget endorse)

  @impl true
  def service, do: "aqua"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}
    # In-chain as well as at the door: the writes are `ask` in the
    # soul's policy, so from a chain each one is a card a person
    # clicked; the reads are `auto`, bounded to the room by the
    # domain. Interactive on every action — the credential gate is
    # the same on both planes. A write answers only the name it wrote
    # (`Aqua.Notes.describe/1`), so it carries no source; a read
    # carries the notes' own provenance (`answer_sources/2`).
    Operation.tool(
      [
        Operation.new(
          "notes",
          "keep",
          "Keep notes",
          [
            Arg.new("name", :string,
              required: true,
              description: "What the note is called (keep, pin, read, forget)"
            ),
            Arg.new("content", :string,
              required: true,
              description: "keep: what to file. pin: the page — empty content clears it"
            ),
            Arg.new("thread", :string,
              description:
                "keep, pin, at the door: provenance — the thread the note was kept from. In a chain the host stamps it and this is ignored."
            ),
            Arg.new("execution", :string,
              description:
                "keep, pin, at the door: provenance — the execution the note was kept from. In a chain the host stamps it and this is ignored."
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          standing: :thread
        ),
        Operation.new(
          "notes",
          "pin",
          "Pin notes",
          [
            Arg.new("name", :string,
              required: true,
              description: "What the note is called (keep, pin, read, forget)"
            ),
            Arg.new("content", :string,
              required: true,
              description: "keep: what to file. pin: the page — empty content clears it"
            ),
            Arg.new("thread", :string,
              description:
                "keep, pin, at the door: provenance — the thread the note was kept from. In a chain the host stamps it and this is ignored."
            ),
            Arg.new("execution", :string,
              description:
                "keep, pin, at the door: provenance — the execution the note was kept from. In a chain the host stamps it and this is ignored."
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          standing: false
        ),
        Operation.new(
          "notes",
          "endorse",
          "Endorse notes",
          [
            Arg.new("name", :string,
              required: true,
              description: "What the note is called (keep, pin, read, forget)"
            ),
            Arg.new(
              "sources",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("class", :string,
                      required: true,
                      enum: Enum.map(Prima.Source.classes(), &Atom.to_string/1)
                    ),
                    Arg.new("name", :string)
                  ]}
               )},
              required: true,
              description:
                "endorse: the sources the note carries, as a read answered them — cleared only while the note carries exactly these"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          standing: false
        ),
        Operation.new(
          "notes",
          "list",
          "List notes",
          [
            Arg.new("scope", :string,
              description:
                "Reads only: where to look — the athanor in focus (default), your own athanor, or every athanor you belong to. Writes take none; a note lands where you are.",
              enum: ["athanor", "mine", "everywhere"]
            ),
            Arg.new("limit", :integer,
              description: "list, search: how many to answer at most (default 100).",
              min: 1,
              max: 500
            ),
            Arg.new("after", :string,
              description: "list, search: the `next` cursor a previous page answered."
            )
          ],
          kind: :read,
          sources: {:answer, {__MODULE__, :answer_sources}},
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "notes",
          "read",
          "Read notes",
          [
            Arg.new("name", :string,
              required: true,
              description: "What the note is called (keep, pin, read, forget)"
            ),
            Arg.new("scope", :string,
              description:
                "Reads only: where to look — the athanor in focus (default), your own athanor, or every athanor you belong to. Writes take none; a note lands where you are.",
              enum: ["athanor", "mine", "everywhere"]
            ),
            Arg.new("athanor_id", :string,
              description:
                "read: the athanor a search answered for the note — reads it there, under your own seat."
            )
          ],
          kind: :read,
          sources: {:answer, {__MODULE__, :answer_sources}},
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "notes",
          "forget",
          "Forget notes",
          [
            Arg.new("name", :string,
              required: true,
              description: "What the note is called (keep, pin, read, forget)"
            )
          ],
          kind: :destructive,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive
        ),
        Operation.new(
          "notes",
          "search",
          "Search notes",
          [
            Arg.new("query", :string,
              required: true,
              description: "search: text to find in a note's name or body"
            ),
            Arg.new("scope", :string,
              description:
                "Reads only: where to look — the athanor in focus (default), your own athanor, or every athanor you belong to. Writes take none; a note lands where you are.",
              enum: ["athanor", "mine", "everywhere"]
            ),
            Arg.new("limit", :integer,
              description: "list, search: how many to answer at most (default 100).",
              min: 1,
              max: 500
            ),
            Arg.new("after", :string,
              description: "list, search: the `next` cursor a previous page answered."
            )
          ],
          kind: :read,
          sources: {:answer, {__MODULE__, :answer_sources}},
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        )
      ],
      description:
        "What was kept out of a thread. Distinct from the transcript: erasing a thread does not erase what someone kept from it. A note lands in the athanor you are working in; two pinned pages (about-you, about-us) are read into every turn and held short.",
      title: "Notes"
    )
  end

  @doc """
  What a notes read's answer carries (its operations' `sources:`
  declaration, `Prima.Operation.answer_sources/3`): the filed note it read,
  with each note's own provenance as it was written — an outside source
  keeps its name, and a note carrying vault-disclosed material keeps that
  class (`Aqua.Notes.sources_of_answer/1`).
  """
  @spec answer_sources(Prima.Actor.t() | nil, term()) :: [Prima.Source.t()]
  def answer_sources(_actor, answer),
    do: Prima.Source.set([Prima.Source.new(:filed) | Aqua.Notes.sources_of_answer({:ok, answer})])

  @impl true
  def handle("notes", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # ---------------------------------------------------------------------------

  # A write that names an athanor is refused rather than obeyed or ignored:
  # the caller believed the argument meant something, and the one thing it
  # must never mean is "somewhere other than here".
  defp dispatch(_ctx, %{"action" => action, "scope" => _}) when action in @writes do
    {:error,
     {:invalid_argument,
      "#{action} takes no scope — a note lands in the athanor you are working in"}}
  end

  defp dispatch(ctx, %{"action" => "keep", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.keep(ctx, name, content, provenance(args, ctx))

  defp dispatch(_ctx, %{"action" => "keep"}),
    do: {:error, {:invalid_argument, "keep requires 'name' and 'content'"}}

  # A pinned page is set one card at a time and carries no sources: the
  # person who approved it made it theirs.
  defp dispatch(ctx, %{"action" => "pin", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.pin(ctx, name, content, Keyword.delete(provenance(args, ctx), :sources))

  defp dispatch(_ctx, %{"action" => "pin"}),
    do: {:error, {:invalid_argument, "pin requires 'name' and 'content' (empty content clears)"}}

  defp dispatch(ctx, %{"action" => "forget", "name" => name}) when is_binary(name),
    do: Notes.forget(ctx, name)

  defp dispatch(ctx, %{"action" => "endorse", "name" => name, "sources" => sources})
       when is_binary(name) and is_list(sources),
       do: Notes.endorse(ctx, name, sources)

  defp dispatch(_ctx, %{"action" => "endorse"}),
    do: {:error, {:invalid_argument, "endorse requires 'name' and 'sources'"}}

  defp dispatch(_ctx, %{"action" => "forget"}),
    do: {:error, {:invalid_argument, "forget requires 'name'"}}

  defp dispatch(ctx, %{"action" => "list"} = args) do
    with {:ok, page} <- Notes.list(ctx, scope(args), page(args)) do
      {:ok, Map.put(page, :scope, scope(args))}
    end
  end

  defp dispatch(ctx, %{"action" => "read", "name" => name} = args) when is_binary(name) do
    with {:ok, note} <-
           Notes.read(ctx, name, scope(args),
             athanor_id: args["athanor_id"],
             root_execution_id: args["root_execution_id"]
           ),
         do: {:ok, wire_sources(note)}
  end

  defp dispatch(_ctx, %{"action" => "read"}),
    do: {:error, {:invalid_argument, "read requires 'name'"}}

  defp dispatch(ctx, %{"action" => "search", "query" => query} = args) when is_binary(query) do
    with {:ok, %{notes: matches} = page} <- Notes.search(ctx, query, scope(args), page(args)) do
      {:ok,
       page
       |> Map.delete(:notes)
       |> Map.merge(%{matches: Enum.map(matches, &wire_sources/1), scope: scope(args)})}
    end
  end

  defp dispatch(_ctx, %{"action" => "search"}),
    do: {:error, {:invalid_argument, "search requires 'query'"}}

  defp dispatch(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "notes.#{action}"}}
  defp dispatch(_ctx, _args), do: {:error, :action_missing}

  defp scope(args), do: Map.get(args, "scope", "athanor")

  # A note's sources on the wire are their canonical JSON objects.
  defp wire_sources(%{sources: sources} = note),
    do: %{note | sources: Prima.Source.to_json_list(sources)}

  defp page(args), do: [limit: args["limit"], after: args["after"]]

  # Where a note was kept from. In a chain the registry stamps the
  # execution and the thread onto the call as host-only keys
  # (the gate's lineage), and those are the only
  # provenance read there — a value the model put under `thread` or
  # `execution` is ignored, never recorded. The note carries every source
  # the chain's turns read and the calling execution's own ledger, so a
  # component that runs no turn keeps what it read too. At the door a
  # person says what they choose to.
  defp provenance(args, %Context{plane: :guest} = ctx) do
    [
      thread: args["thread_id"],
      execution: args["root_execution_id"] || args["parent_execution_id"],
      sources:
        Prima.Source.union(
          Notes.chain_sources(ctx, args["root_execution_id"]),
          caller_sources(ctx, args["parent_execution_id"])
        )
    ]
  end

  defp provenance(args, _ctx) do
    [thread: args["thread"], execution: args["execution"]]
  end

  # The ledger of the execution that called (`Opus.sources/2`), the
  # lineage's `parent_execution_id`, which the gate admits a call in a
  # chain only with, read as the call keeps the note. That execution is
  # running, so a row it no longer finds, or a ledger that cannot be
  # read, is one unnamed outside source, never none.
  defp caller_sources(ctx, execution_id) when is_binary(execution_id) do
    case Opus.sources(ctx, execution_id) do
      {:ok, sources} -> sources
      {:error, _unread} -> [Prima.Source.outside(nil)]
    end
  end

  defp caller_sources(_ctx, _none), do: []
end
