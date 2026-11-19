# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Workspace do
  @moduledoc """
  The `workspace` tool: workspace threads, the second tier of the
  person's threads. A daily thread is where the person talks to Aqua; a
  workspace thread is one Aqua opens for one piece of work, which the soul
  works in turns of that thread, pointed at by a post of the daily
  thread, and reporting back to it.

    * `open` opens one, or sends a further ask to one, from a daily
      thread: in one transaction the thread, its opening (the envelope:
      the ask, who asked, the post that asked, the daily thread's posts
      it refers to, the files it carries, copied into it, the tools it is
      narrowed to, whether its browser work is kept apart, its title), a
      pointer post on the daily thread and the `workspace_open` record
      whose delivery starts the soul's turn there
      (`Arca.TurnStorage.open_workspace/2`, `Aqua.Crew`). It answers the
      thread's id at once, and the calling turn goes on, as `crew.ask`'s
      does. A thread asked again is new work there, whatever its state.
    * `report` is the soul's there: from a turn of the workspace thread
      it reports, under that turn's fence, `done` (with what worked and
      what did not in its summary) or `needs_you` (the work waits on
      something only the person can give), with the files of the
      thread's posts it carries, which the thread becomes once nothing
      else it accepted remains to run, and the
      `workspace_report` record lands the report on the daily thread
      current when it is delivered. The host makes the other moves, and
      alone says a thread is `stopped` or in `error`
      (`Arca.TurnStorage`'s "Workspace threads").
    * `list` answers the records a view reads (`records/1`).

  ## Who calls

  `open` takes two callers, told apart by the plane the call is on, never
  by what its arguments say. In a chain (the guest plane) it is a turn of
  the soul in a daily thread, found from the lineage the gate stamps
  (`Aqua.Tape.calling_turn/2`): its person asked, its turn's opening
  message is the post that asked, and the refs and files are that daily
  thread's posts. A turn of any other agent, of a crew member or of any
  other kind of thread is refused `:not_addressable`. Outside a chain it
  is the person's own interactive session (`consent: :interactive`),
  naming a daily thread of their athanor and posts of it, the newest of
  which asked. `report` is a chain's only, from a turn of the workspace
  thread it reports; `list` is the person's or any turn's.

  Every row read or written is the caller's athanor's: a thread, a post or
  a file of another athanor is not found.
  """

  @behaviour Prima.Provider

  alias Aqua.Tape
  alias Sanctum.Context

  # The most daily-thread posts an opening refers to.
  @refs_max 20
  @ask_max 32 * 1024
  # What Aqua reports of its work; `stopped` and `error` are the host's.
  @outcomes ~w(done needs_you)

  @impl true
  def service, do: "aqua"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    file =
      Arg.new(
        nil,
        {:record,
         [
           Arg.new("message_id", :string, required: true),
           Arg.new("stored_name", :string, required: true)
         ]}
      )

    # `open` and `list` are the person's and a turn's; `report` is a
    # chain's only. Each answer is ids, states and the titles Aqua wrote,
    # the athanor's own.
    Operation.tool(
      [
        Operation.new(
          "workspace",
          "open",
          "Open workspace thread",
          [
            Arg.new("title", :string,
              description:
                "open: a short title for a new workspace thread, plain text on one line of at most #{Aqua.Crew.title_max()} characters",
              max: Aqua.Crew.title_max()
            ),
            Arg.new("ask", :string,
              required: true,
              description: "open: what the person asked, in their words (at most 32 KiB)",
              max: @ask_max
            ),
            Arg.new("workspace", :string,
              description:
                "open: an existing workspace thread to send this ask to, in place of a title"
            ),
            Arg.new("thread", :string,
              description:
                "open: the daily thread the posts are of, when the person opens one; a turn opens from its own"
            ),
            Arg.new("refs", {:array, Arg.new(nil, :string)},
              description:
                "open: up to #{@refs_max} ids of that daily thread's posts the work refers to, read as they are when the work starts"
            ),
            Arg.new("attachments", {:array, file},
              description:
                "open: files of that daily thread's posts to carry into the workspace thread, each {message_id, stored_name}"
            ),
            Arg.new("tools", {:array, Arg.new(nil, :string)},
              description:
                "open: narrow the work's tools to these (a tool, or tool.action); posting and reporting stay; omit for all"
            ),
            Arg.new("apart", :boolean,
              description: "open: keep this work's browser apart from the person's other work"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive
        ),
        Operation.new(
          "workspace",
          "report",
          "Report workspace thread",
          [
            Arg.new("outcome", :string,
              required: true,
              description:
                "report: done when the work is finished, needs_you when it waits on the person",
              enum: @outcomes
            ),
            Arg.new("summary", :string,
              required: true,
              description:
                "report: what worked and what did not, or what the person must give or decide, for the daily thread (at most 32 KiB)",
              max: @ask_max
            ),
            Arg.new("attachments", {:array, file},
              description:
                "report: files of this workspace thread's posts to carry into the report, each {message_id, stored_name}"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:in_chain]
        ),
        Operation.new("workspace", "list", "List workspace threads", [],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        )
      ],
      description:
        "Workspace threads: open one for a piece of real work from the daily thread, which shows a post pointing at it, or send a further ask to one already open; the work goes on there and its report comes back to the daily thread when it is done or needs the person. report, from a turn of a workspace thread, says it is done, with what worked and what did not, or that it needs something from the person. list names the workspace threads at work, waiting on the person or with posts not yet seen.",
      title: "Workspace threads"
    )
  end

  @impl true
  def handle("workspace", %Context{} = ctx, %{"action" => "open"} = args), do: open(ctx, args)
  def handle("workspace", %Context{} = ctx, %{"action" => "report"} = args), do: report(ctx, args)

  def handle("workspace", %Context{} = ctx, %{"action" => "list"} = args) do
    with :ok <- lister(ctx, args), {:ok, records} <- records(ctx) do
      {:ok, %{workspaces: Enum.map(records, &wire/1), count: length(records)}}
    end
  end

  def handle("workspace", _ctx, _args),
    do: {:error, {:invalid_argument, "workspace takes the action open, report or list"}}

  # ---------------------------------------------------------------------------
  # Opening
  # ---------------------------------------------------------------------------

  defp open(ctx, args) do
    with {:ok, ask} <- ask(args["ask"]),
         {:ok, title} <- Aqua.Crew.parse_title(args["title"], "workspace.open"),
         {:ok, tools} <- Aqua.Crew.parse_tools(args["tools"], "workspace.open"),
         {:ok, apart} <- apart(args["apart"]),
         {:ok, from} <- opener(ctx, args),
         {:ok, refs} <- refs(ctx, from, args["refs"]),
         {:ok, files} <- files(ctx, from.daily.id, args["attachments"]),
         {:ok, target} <- target(ctx, args["workspace"], title, from) do
      opening_id = Prima.UUID7.generate_id("msg")
      workspace_id = target[:id] || target.workspace_id
      title = target.title

      attrs =
        target
        |> Map.merge(%{
          daily_id: from.daily.id,
          turn: from.turn && Map.take(from.turn, [:id, :fence]),
          opening: %{
            id: opening_id,
            author: from.person,
            content: ask,
            payload: %{
              "ask" => ask,
              "asked_by" => from.person,
              "from" => %{"thread" => from.daily.id, "message" => from.asked},
              "refs" => refs,
              "tools" => tools,
              "apart" => apart,
              "title" => title
            }
          },
          pointer: pointer(from, workspace_id, title, opening_id),
          files: fn thread_id, message_id -> stored(ctx, thread_id, message_id, files) end,
          person_id: from.person,
          origin: from.origin
        })

      case Tape.open_workspace(ctx, attrs) do
        {:ok, %{workspace: workspace}} ->
          {:ok,
           %{
             workspace: workspace.id,
             title: workspace.title,
             state: workspace.workspace_state,
             note:
               "The work goes on in its own workspace thread; its report arrives on the daily thread as a post of its own."
           }}

        {:error, reason} ->
          _ = Aqua.Attachments.discard(ctx, workspace_id, opening_id)
          {:error, refusal(reason)}
      end
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # Who opens, from the plane the call is on: a turn of the soul in a
  # daily thread, or the person's own session naming a daily thread.
  defp opener(%Context{plane: :guest} = ctx, args) do
    with {:ok, turn} <- Tape.held_turn(ctx, args),
         true <- Prima.AgentRef.soul?(turn.agent) or {:error, :not_addressable},
         {:ok, %{kind: "daily"} = daily} <- thread(ctx, turn.thread_id),
         {:ok, origin} <- Prima.Origin.from_wire(turn.origin) do
      {:ok,
       %{
         turn: turn,
         daily: daily,
         person: turn.requested_by,
         origin: origin,
         asked: turn.message_id,
         author: Prima.Author.agent(),
         sent_by: turn.agent
       }}
    else
      {:ok, _not_daily} -> {:error, :not_addressable}
      {:error, :no_origin} -> {:error, :no_origin}
      {:error, _} = refused -> refused
    end
  end

  defp opener(%Context{user_id: user_id} = ctx, %{"thread" => thread_id} = args)
       when is_binary(user_id) and is_binary(thread_id) do
    with :ok <- Aqua.Runner.Admission.standing(ctx, ctx.athanor_id),
         {:ok, %{kind: "daily"} = daily} <- thread(ctx, thread_id),
         [_ | _] = ids <- args["refs"] || {:error, :refs_required} do
      {:ok,
       %{
         turn: nil,
         daily: daily,
         person: user_id,
         origin: ctx.origin,
         asked: List.last(ids),
         author: user_id,
         sent_by: Aqua.Runner.Admission.person()
       }}
    else
      {:ok, _not_daily} -> {:error, :not_a_daily_thread}
      [] -> {:error, :refs_required}
      {:error, _} = refused -> refused
    end
  end

  defp opener(%Context{}, _args), do: {:error, :thread_required}

  # The pointer post the daily thread shows: the opener's, naming the
  # workspace thread, its title and the opening it points at.
  defp pointer(from, workspace_id, title, opening_id) do
    %{
      author: from.author,
      sent_by: from.sent_by,
      content: title,
      payload: %{"workspace" => workspace_id, "title" => title, "opening" => opening_id}
    }
  end

  # A new thread, by its title, or an existing workspace thread of the
  # athanor, by its id.
  defp target(_ctx, nil, nil, _from),
    do: {:error, {:invalid_argument, "workspace.open takes a 'title' or a 'workspace'"}}

  defp target(_ctx, nil, title, from),
    do: {:ok, %{id: Prima.UUID7.generate_id("thread"), title: title, opened_from: from.asked}}

  defp target(ctx, workspace_id, _title, _from) when is_binary(workspace_id) do
    case thread(ctx, workspace_id) do
      {:ok, %{kind: "workspace"} = workspace} ->
        {:ok, %{workspace_id: workspace.id, title: workspace.title}}

      {:ok, _other} ->
        {:error, :not_a_workspace}

      {:error, _} = refused ->
        refused
    end
  end

  defp thread(ctx, id) do
    case Tape.thread(ctx, id) do
      {:ok, thread} -> {:ok, thread}
      {:error, :not_found} -> {:error, {:not_found, "thread", id}}
      {:error, _} = refused -> refused
    end
  end

  defp ask(ask) when is_binary(ask) do
    case String.trim(ask) do
      "" -> {:error, {:invalid_argument, "workspace.open requires a non-empty 'ask'"}}
      text when byte_size(text) > @ask_max -> {:error, :message_too_long}
      text -> {:ok, text}
    end
  end

  defp ask(_ask), do: {:error, {:invalid_argument, "workspace.open requires a non-empty 'ask'"}}

  defp apart(nil), do: {:ok, false}
  defp apart(apart) when is_boolean(apart), do: {:ok, apart}

  defp apart(_apart),
    do: {:error, {:invalid_argument, "workspace.open takes 'apart' as true or false"}}

  # The posts an opening refers to: ids of the daily thread's own posts,
  # each once, at most `@refs_max`.
  defp refs(_ctx, _from, nil), do: {:ok, []}

  defp refs(_ctx, _from, ids) when is_list(ids) and length(ids) > @refs_max,
    do: {:error, {:invalid_argument, "workspace.open takes at most #{@refs_max} refs"}}

  defp refs(ctx, %{daily: %{id: daily_id}}, ids) when is_list(ids) do
    ids = Enum.uniq(ids)

    Enum.reduce_while(ids, {:ok, ids}, fn id, ok ->
      case is_binary(id) && Tape.message(ctx, id) do
        {:ok, %{thread_id: ^daily_id}} -> {:cont, ok}
        {:error, :database_error} = refused -> {:halt, refused}
        _not_its -> {:halt, {:error, {:not_found, "post", to_string(id)}}}
      end
    end)
  end

  defp refs(_ctx, _from, _ids),
    do: {:error, {:invalid_argument, "workspace.open takes 'refs' as post ids"}}

  # The files an opening carries, read from the daily thread's posts now
  # and stored under the opening inside its transaction.
  defp files(_ctx, _thread_id, nil), do: {:ok, []}

  defp files(ctx, thread_id, files) when is_list(files) do
    case Aqua.Attachments.carried(ctx, thread_id, files) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, :not_a_post} -> {:error, {:invalid_argument, attachment_words()}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp files(_ctx, _thread_id, _files),
    do: {:error, {:invalid_argument, attachment_words()}}

  defp attachment_words,
    do: "workspace.open carries files of the daily thread's posts, each {message_id, stored_name}"

  # Called again when the opening's transaction is retried: what an
  # earlier try stored under the opening goes first.
  defp stored(ctx, thread_id, message_id, files) do
    with :ok <- Aqua.Attachments.discard(ctx, thread_id, message_id),
         do: Aqua.Attachments.copy(ctx, thread_id, message_id, files)
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp report(%Context{plane: :guest} = ctx, %{"outcome" => outcome} = args)
       when outcome in @outcomes do
    with {:ok, summary} <- summary(args["summary"]),
         {:ok, turn} <- Tape.held_turn(ctx, args),
         {:ok, attachments} <- reported_files(ctx, turn.thread_id, args["attachments"]),
         {:ok, thread} <-
           Tape.report_workspace(ctx, turn, outcome, %{summary: summary, attachments: attachments}) do
      {:ok,
       %{
         workspace: thread.id,
         state: thread.workspace_state,
         note: "The daily thread is told, as a post of its own."
       }}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp report(%Context{plane: :guest}, _args),
    do: {:error, {:invalid_argument, "workspace.report takes an 'outcome' of done or needs_you"}}

  defp report(%Context{}, _args), do: {:error, :not_in_a_turn}

  defp summary(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, {:invalid_argument, "workspace.report requires a non-empty 'summary'"}}
      text when byte_size(text) > @ask_max -> {:error, :message_too_long}
      text -> {:ok, text}
    end
  end

  defp summary(_text),
    do: {:error, {:invalid_argument, "workspace.report requires a non-empty 'summary'"}}

  # A report carries files of its own thread's posts, named now and
  # copied when it is delivered; each must be one now.
  defp reported_files(_ctx, _thread_id, nil), do: {:ok, []}

  defp reported_files(ctx, thread_id, files)
       when is_list(files) and length(files) <= 10 do
    named =
      for %{"message_id" => id, "stored_name" => name} <- files,
          do: %{"message_id" => id, "stored_name" => name}

    with true <- length(named) == length(files) or {:error, :not_a_post},
         named = Enum.uniq(named),
         {:ok, _readable} <- Aqua.Attachments.carried(ctx, thread_id, named) do
      {:ok, named}
    else
      {:error, :not_a_post} ->
        {:error,
         {:invalid_argument,
          "workspace.report carries files of this workspace thread's posts, each {message_id, stored_name}"}}

      {:error, _} = refused ->
        refused
    end
  end

  defp reported_files(_ctx, _thread_id, _files),
    do: {:error, {:invalid_argument, "workspace.report carries at most 10 files"}}

  # ---------------------------------------------------------------------------
  # The records a view reads
  # ---------------------------------------------------------------------------

  @typedoc "A workspace thread as a view reads it."
  @type entry :: %{
          id: String.t(),
          title: String.t(),
          state: String.t(),
          opened_at: DateTime.t(),
          last_activity: DateTime.t(),
          unread: non_neg_integer(),
          waits_on_you: boolean()
        }

  @doc """
  The person's workspace threads a view lists, the latest activity first:
  each one not archived that is `open` or `needs_you`, and each one whose
  work ended (`done`, `stopped`, `error`) with posts the person has not
  seen; one they have seen leaves the list by itself and is found from
  the daily thread, and one archived is found in their list's Archived
  filter.
  `waits_on_you` is whether it needs the person: Aqua reported it needs
  them.
  """
  @spec records(Context.t()) :: {:ok, [entry()]} | {:error, term()}
  def records(%Context{} = ctx) do
    actor = Context.actor(ctx)

    case Arca.ThreadStorage.list(actor, kind: "workspace", archived: false) do
      threads when is_list(threads) ->
        threads
        |> Enum.reduce_while({:ok, []}, fn thread, {:ok, acc} ->
          case record_of(actor, thread) do
            {:ok, record} -> {:cont, {:ok, [record | acc]}}
            {:error, _} = refused -> {:halt, refused}
          end
        end)
        |> case do
          {:ok, records} ->
            {:ok,
             records
             |> Enum.filter(&(&1.state in ["open", "needs_you"] or &1.unread > 0))
             |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})}

          refused ->
            refused
        end

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  @doc """
  One workspace thread of the caller's athanor as a view reads it, listed
  or not, with the daily thread's post it was `opened_from`.
  """
  @spec record(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def record(%Context{} = ctx, thread_id) when is_binary(thread_id) do
    actor = Context.actor(ctx)

    with {:ok, %{kind: "workspace"} = thread} <- Arca.ThreadStorage.get(actor, thread_id),
         {:ok, record} <- record_of(actor, thread) do
      {:ok, Map.put(record, :opened_from, thread.opened_from)}
    else
      {:ok, _other} -> {:error, :not_found}
      {:error, _} = refused -> refused
    end
  end

  # It needs the person once Aqua reported so, which its state says
  # (`needs_you`).
  defp record_of(actor, thread) do
    with {:ok, unread} <- Arca.ThreadStorage.unread(actor, thread) do
      {:ok,
       %{
         id: thread.id,
         title: thread.title,
         state: thread.workspace_state,
         opened_at: thread.inserted_at,
         last_activity: thread.last_message_at || thread.inserted_at,
         unread: unread,
         waits_on_you: thread.workspace_state == "needs_you"
       }}
    end
  end

  # The person, or a turn of the athanor: a chain with no turn behind it
  # (a key's, a webhook's, a schedule's component) lists nothing.
  defp lister(%Context{plane: :guest} = ctx, args) do
    case Tape.calling_turn(ctx, args) do
      {:ok, _turn} -> :ok
      {:error, :not_addressable} -> {:error, :not_in_a_turn}
      {:error, _} = refused -> refused
    end
  end

  defp lister(%Context{}, _args), do: :ok

  defp wire(record) do
    %{
      workspace: record.id,
      title: record.title,
      state: record.state,
      opened_at: record.opened_at,
      last_activity: record.last_activity,
      unread: record.unread,
      waits_on_you: record.waits_on_you
    }
  end

  # ---------------------------------------------------------------------------
  # Refusals
  # ---------------------------------------------------------------------------

  defp refusal(:not_addressable),
    do:
      {:invalid_argument,
       "a workspace thread is opened from a turn of the assistant in a daily thread, or by the person from a daily thread's posts"}

  defp refusal(:not_a_workspace),
    do:
      {:invalid_argument,
       "workspace.report reports the workspace thread its turn runs in, and workspace.open sends to a workspace thread"}

  defp refusal(:not_a_daily_thread),
    do: {:invalid_argument, "a workspace thread is opened from a daily thread's posts"}

  defp refusal(:thread_required),
    do: {:invalid_argument, "workspace.open names the daily thread its posts are of"}

  defp refusal(:refs_required),
    do: {:invalid_argument, "workspace.open names at least one post of that daily thread"}

  defp refusal(:reported),
    do: {:conflict, "this turn has reported its work already"}

  defp refusal({:workspace_state, state}),
    do: {:conflict, "this workspace thread is #{state}, so there is nothing to report"}

  defp refusal(:superseded), do: {:conflict, "The turn's owner changed. Retry the operation."}

  defp refusal(:not_open),
    do: {:conflict, "The turn changed while this request was running. Retry the operation."}

  defp refusal(:database_error), do: {:unavailable, "Storage"}
  defp refusal(:not_found), do: {:not_found, "thread", ""}
  defp refusal(other), do: other
end
