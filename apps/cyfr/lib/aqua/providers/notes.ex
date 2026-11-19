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
  note at all: run as its member's mode decides, inside the chain under
  the turn's authority. Of the writes, `pin` is the about-you page and
  `workspace` the notes of the workspace thread the turn runs in, which
  the lineage names and no argument does. A turn's
  `pin` names the revision of the page it read, and one the person changed
  since is refused, so a turn never writes over what it did not read.
  Whether a write comes from a turn is read from the lineage the gate
  stamped: a `pin` or a `workspace` in a chain, and a `keep` whose lineage
  names the turn's thread, writes only while the turn the lineage names
  holds its fence, asked again where the write commits; a turn that ended,
  was superseded or is not found writes nothing. Only the person's own
  call at the door writes with no turn, and a `keep` from a component's
  chain, which names no thread, keeps with that execution's ledger. The
  consent class keeps its surface half there — only an `:oidc` session's
  chain gets through — so the same formula started by a key or a schedule
  is refused exactly as at the door.

  ## Where a note lands

  Reads and writes take no scope: every action acts on the athanor in
  focus, the person's own.

  ## Provenance and outside material

  A note kept in a chain carries in its provenance every source the
  chain's turns read (`Aqua.Notes.chain_sources/2`) and the calling
  execution's own ledger (`Opus.sources/2`), both read from the
  host-stamped lineage, never from what the model wrote, so a turn or a
  guest that reads it later reads them too, and a component that runs no
  turn keeps what it read as a turn does: a note made from a
  disclosed vault value carries `vault_disclosed`, whatever admitted the
  keep. A page `pin` or `workspace` writes in a chain
  keeps them the same way, is kept by Aqua (`Prima.Author.agent/0`) and
  names the thread it was written in. A thread source is left out: what
  a note holds outlives the thread it was kept from, so reading a note
  never makes a turn one that read that thread. The person's own
  write of the pinned page, on
  the Aqua page, carries no sources: what they wrote is theirs.
  """

  @behaviour Prima.Provider

  alias Aqua.Notes
  alias Sanctum.Context

  @impl true
  def service, do: "aqua"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}
    # In-chain as well as at the door: from a chain each action runs as
    # the member's mode decides, and the reads are bounded to the athanor
    # by the domain. `workspace` is a chain's alone: the turn
    # names its thread. Interactive on every action — the credential
    # gate is the same on both planes. A write answers only the name it wrote
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
              bulk: true,
              description: "keep: what to file. pin: the page — empty content clears it"
            ),
            Arg.new("thread", :string,
              description:
                "keep, pin, at the external entry: provenance — the thread the note was kept from. In a chain the host stamps it and this is ignored."
            ),
            Arg.new("execution", :string,
              description:
                "keep, pin, at the external entry: provenance — the execution the note was kept from. In a chain the host stamps it and this is ignored."
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive
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
              bulk: true,
              description: "keep: what to file. pin: the page — empty content clears it"
            ),
            Arg.new("thread", :string,
              description:
                "keep, pin, at the external entry: provenance — the thread the note was kept from. In a chain the host stamps it and this is ignored."
            ),
            Arg.new("execution", :string,
              description:
                "keep, pin, at the external entry: provenance — the execution the note was kept from. In a chain the host stamps it and this is ignored."
            ),
            Arg.new("revision", :integer,
              min: 0,
              description:
                "pin: the revision the page stood at when it was read (read answers it, and a turn's Notes section shows it); a page written since is refused and left as it is. A turn always names it."
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive
        ),
        Operation.new(
          "notes",
          "workspace",
          "Write workspace thread notes",
          [
            Arg.new("content", :string,
              required: true,
              bulk: true,
              description:
                "workspace: the notes of the workspace thread this turn runs in, whole — empty content clears them"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:in_chain],
          consent: :interactive
        ),
        Operation.new(
          "notes",
          "list",
          "List notes",
          [
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
        "What was kept out of a thread. Distinct from the transcript: erasing a thread does not erase what someone kept from it. A note lands in the athanor you are working in; the pinned page (about-you) is read into every turn and held short. A workspace thread's notes are its own, read into its every turn, and go with it.",
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

  # What a turn's pin is told when the page is not the one it read, and
  # when it names no revision at all.
  @page_moved "The about-you page changed since this turn read it, so nothing was written. " <>
                "Read it again with notes.read and write it whole over the revision that " <>
                "answers, keeping what the person wrote."
  @turn_moved "The turn's owner changed. Retry the operation."
  @page_unread "notes.pin in a turn names, as revision, the revision of the page it read: " <>
                 "the one the Notes section shows beside the page, or notes.read answers; " <>
                 "0 when none is pinned."

  @impl true
  def handle("notes", %Context{} = ctx, args), do: dispatch(ctx, args)

  # ---------------------------------------------------------------------------

  # A note a turn keeps is written only while that turn holds its fence;
  # one a component's chain keeps, whose lineage names no turn, as before.
  defp dispatch(
         %Context{plane: :guest} = ctx,
         %{"action" => "keep", "name" => name, "content" => content} = args
       )
       when is_binary(name) and is_binary(content) do
    with {:ok, verify} <- keep_hold(ctx, args) do
      ctx
      |> Notes.keep(name, content, provenance(args, ctx), verify: verify)
      |> written_in_turn()
    end
  end

  defp dispatch(ctx, %{"action" => "keep", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.keep(ctx, name, content, provenance(args, ctx))

  # The pinned page, whole: in a chain Aqua's, with the sources the
  # chain read, written only over the revision the turn read, so a page
  # the person changed since is never written over by a turn that did not
  # read it; at the door the person's, with none. A `revision` writes only
  # over the page as it was read.
  defp dispatch(
         %Context{plane: :guest} = ctx,
         %{"action" => "pin", "name" => name, "content" => content} = args
       )
       when is_binary(name) and is_binary(content) do
    with {:ok, revision} <- revision_read(args),
         {:ok, verify} <- turn_hold(ctx, args) do
      ctx
      |> Notes.pin(name, content, provenance(args, ctx), revision: revision, verify: verify)
      |> pinned_in_turn()
    end
  end

  defp dispatch(ctx, %{"action" => "pin", "name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content),
       do: Notes.pin(ctx, name, content, provenance(args, ctx), revision: args["revision"])

  # The notes of the workspace thread the calling turn runs in, held by
  # the holder that made the call: the lineage names the turn, and the
  # turn the thread.
  defp dispatch(
         %Context{plane: :guest} = ctx,
         %{"action" => "workspace", "content" => content} = args
       )
       when is_binary(content) do
    case Aqua.Tape.held_turn(ctx, args) do
      {:ok, turn} ->
        Notes.workspace(ctx, turn, content, provenance(args, ctx))

      {:error, :not_addressable} ->
        {:error, :not_in_a_turn}

      {:error, :superseded} ->
        {:error, {:conflict, "The turn's owner changed. Retry the operation."}}

      {:error, _} ->
        {:error, {:unavailable, "Notes"}}
    end
  end

  defp dispatch(_ctx, %{"action" => "workspace"}), do: {:error, :not_in_a_turn}

  defp dispatch(ctx, %{"action" => "forget", "name" => name}) when is_binary(name),
    do: Notes.forget(ctx, name)

  defp dispatch(ctx, %{"action" => "list"} = args), do: Notes.list(ctx, page(args))

  defp dispatch(ctx, %{"action" => "read", "name" => name} = args) when is_binary(name) do
    with {:ok, note} <- Notes.read(ctx, name, root_execution_id: args["root_execution_id"]),
         do: {:ok, wire_sources(note)}
  end

  defp dispatch(ctx, %{"action" => "search", "query" => query} = args) when is_binary(query) do
    with {:ok, %{notes: matches} = page} <- Notes.search(ctx, query, page(args)) do
      {:ok, page |> Map.delete(:notes) |> Map.put(:matches, Enum.map(matches, &wire_sources/1))}
    end
  end

  # A note's sources on the wire are their canonical JSON objects.
  defp wire_sources(%{sources: sources} = note),
    do: %{note | sources: Prima.Source.to_json_list(sources)}

  defp page(args), do: [limit: args["limit"], after: args["after"]]

  # A turn's pin names the revision it read.
  defp revision_read(%{"revision" => revision}) when is_integer(revision) and revision >= 0,
    do: {:ok, revision}

  defp revision_read(_args), do: {:error, {:invalid_argument, @page_unread}}

  # The owner check a write in a chain is published under, decided as
  # `thread.post` and `workspace.report` decide it: the turn the lineage
  # names, held by the holder that made the call (`Aqua.Tape.held_turn/2`),
  # whose fence is asked again where the publication commits
  # (`Aqua.Tape.hold/2`). A call no open turn answers for, one whose turn
  # ended, was superseded or is not found, or a chain with no turn,
  # writes nothing: only a call at the door, the person's own, writes with
  # no turn.
  defp turn_hold(ctx, args) do
    case Aqua.Tape.held_turn(ctx, args) do
      {:ok, turn} -> {:ok, fn -> Aqua.Tape.hold(ctx, turn) end}
      {:error, :not_addressable} -> {:error, :not_in_a_turn}
      {:error, :superseded} -> {:error, {:conflict, @turn_moved}}
      {:error, _unread} -> {:error, {:unavailable, "Notes"}}
    end
  end

  # A keep's: a turn's chain, which the gate stamps with the turn's thread
  # (`Aqua.Loop.Binding`), as a pin's; a component's chain, whose lineage
  # names no thread, keeps as before, with its execution's ledger.
  defp keep_hold(ctx, %{"thread_id" => thread_id} = args) when is_binary(thread_id),
    do: turn_hold(ctx, args)

  defp keep_hold(_ctx, _args), do: {:ok, nil}

  defp pinned_in_turn({:error, {:conflict, _}}), do: {:error, {:conflict, @page_moved}}
  defp pinned_in_turn(answered), do: written_in_turn(answered)

  # A write whose turn lost its fence, or ended, before it committed.
  defp written_in_turn({:error, {:declined, :superseded}}), do: {:error, {:conflict, @turn_moved}}

  defp written_in_turn({:error, {:declined, :not_open}}),
    do: {:error, {:conflict, "The turn ended while this was being written; nothing was written."}}

  defp written_in_turn(answered), do: answered

  # Where a note was kept from. In a chain the registry stamps the
  # execution and the thread onto the call as host-only keys
  # (the gate's lineage), and those are the only
  # provenance read there — a value the model put under `thread` or
  # `execution` is ignored, never recorded. The note carries every source
  # the chain's turns read and the calling execution's own ledger, so a
  # component that runs no turn keeps what it read too. At the door a
  # person says what they choose to.
  # What a turn writes — a kept note, the pinned page or a workspace
  # thread's notes — is kept by Aqua; a note a component's chain keeps,
  # whose lineage names no thread, by the person it runs for.
  defp provenance(args, %Context{plane: :guest} = ctx) do
    [
      thread: args["thread_id"],
      execution: args["root_execution_id"] || args["parent_execution_id"],
      sources:
        Prima.Source.material(
          Prima.Source.union(
            Notes.chain_sources(ctx, args["root_execution_id"]),
            caller_sources(ctx, args["parent_execution_id"])
          )
        )
    ] ++
      if(args["action"] in ["pin", "workspace"] or is_binary(args["thread_id"]),
        do: [kept_by: Prima.Author.agent()],
        else: []
      )
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
