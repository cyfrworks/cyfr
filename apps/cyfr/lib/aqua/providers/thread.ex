# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Thread do
  @moduledoc """
  Chat on the wire: the `thread` tool, and the `crew` tool beside it.

  Exposes Aqua thread addressing, queuing and history to MCP clients
  through the thread runner.

  `thread.post` is the one action of `thread` a running turn writes with:
  a post into the thread its turn runs in, under its fence, with text, the
  files it hands (stored under the post's own row first), links, which
  are shown and never fetched, and a screenshot the same attempt of the
  turn took (`Aqua.Attachments.drafted/3`), copied into the post with
  the sources of the page it shows. The lineage the gate stamps names the
  thread and the turn; no argument does.

  ## Recall

  `thread.search` and `thread.events` are the two a turn reads with, as
  the person does at the door: a search finds past posts of the
  athanor's daily and workspace threads by a plain substring of their
  text, case folded, the same on both adapters
  (`Arca.ThreadStorage.search/3`), and answers each as a pointer (its
  thread, the day or the title, the post, its `seq`, who wrote it, when,
  and 240 bytes around the match); `events` then reads that thread
  after a `seq`, in a turn fifty posts at most. A crew member's thread is
  neither searched nor read, and another athanor's is not found. A turn
  reads only while the person's Aqua holds it, the holder that made the
  call: before a read answers, what it carries joins the turn's sources
  under the turn's fence (`Aqua.Tape.join_read/5`): each thread whose
  posts it answers or that those posts carry (a pointer's or a report's
  workspace thread, an opening's daily thread), what the posts carry (a
  report's kept sources, a copied file's), and the sources of the turns
  that wrote them. So deleting a thread a turn read finds that turn, and
  blanks the read's result (`Arca.ThreadStorage.delete/3`); a thread
  deleted before the join is not answered.

  `crew` is the second tool this provider serves: `ask` and `list`, the
  soul's hand-off to a crew member from inside its turn (`Aqua.Crew`).
  `threads` is the third: `list` and `read`, the person's shared threads
  as their own Aqua reads them when a question needs it, under the
  person's own seat (`Sanctum.SharedThreads.listed/1`,
  `Aqua.RoomExcerpt`), and only from an open turn of that person's Aqua
  (`Aqua.Tape.calling_turn/2`, the rule `crew` keeps too): a component's
  run that holds the grant reads nothing, refused `:not_in_a_turn`. Both
  are in a chain only, and neither writes: a line reaches a shared thread
  only when the person says it aloud. The
  provider's `service/0` is `"aqua"` for all three, so `system.status`
  and the request log's `routed_to` read one label.

  Every turn-shaped action here **wraps `Aqua.Runner`** — there
  is no second implementation of a turn, and no path that starts one
  without the runner's gates. The rest wrap the domain verbs the console
  itself uses: `today` is `Aqua.Day.current/1`, the person's daily thread
  of today, made when there is none (how a headless client gets an id at
  all), `list` is `Arca.ThreadStorage`, and `aloud` is
  `Aqua.Aloud.post/4` with every rule decided there. A `send` that names
  no thread, or names a daily thread, joins the daily thread current when
  it is accepted (`Aqua.Day`).

  It lives beside the runner because the assistant owns its providers,
  as every domain does. `Aqua.ToolSeamTest` keeps the other arrow
  pointing one way — the assistant dispatches through the gate only at
  `Aqua.Ops` — and the Boundary compiler keeps it from naming `Emissary`.

  ## Starting turns

  Start chat turns through the runner so the turn pins the profile it
  runs under. Direct execution of the agent formula does not establish
  this thread state.

  ## Two gates, on different axes

    * **Plane.** `Sanctum.Gate.call_external/4` refuses a
      `:guest` context outright, and these actions but `post`, `search`
      and `events` declare `planes: [:external]` so they never appear
      in-chain. A running agent cannot speak or post into a thread but
      its own, and reads only its own athanor's daily and
      workspace threads — never other people's.
    * **Surface.** Every action declares `consent: :interactive`, which the
      registry's dispatch gate holds to
      `Sanctum.Consent.Authz.authorize_interactive/1` — `:oidc` and nothing
      else, so **no API key can drive somebody's chat, a `*` key included**.
      A standing credential is exactly the thing that should not be able to
      speak as a person; the plane gate says nothing about this axis.
      Declared on the annotation rather than checked in the handler so the
      three surfaces that read it cannot drift: dispatch refuses,
      `tools/list` hides the tool from a caller who would be refused, and
      the refusal renders as the typed `consent_class_required` code
      instead of a generic tool error.

  ## Streams

  Two streams a canvas reads ride beside the tools (`streams/0`), each
  with its shape and refresh:

    * `threads.changes` is one person's list of threads, on their own
      topic, so its subject is the grant holder's own id, which the gate
      binds: their athanor's daily and workspace threads, each saying
      whether it is archived, and the active shared threads they sit in
      (`Aqua.ThreadList`).
    * `activity.changes` is the athanor's crew at work, a job's start and
      end, and takes no subject (`Aqua.Crew.Activity`). It is declared
      here, beside the `crew` tool, as the assistant's one provider.
  """

  @behaviour Prima.Provider

  # The most lines one `aloud` may carry: each one copies bytes into the
  # shared thread, so a call moves a slice, never a thread.
  @aloud_max 50

  alias Aqua.{Runner, Tape}
  alias Sanctum.Context

  @impl true
  def service, do: "aqua"

  # Three tools, one service. The service label is the provider's, so
  # `system.status` and the request log's `routed_to` read one label for
  # both; a tool name and a service name are already different things
  # (`Opus.Provider` answers `"opus"`, `Emissary.External.Provider`
  # answers `"emissary"`).
  @impl true
  def tools, do: [definition(), crew_definition(), threads_definition()]

  # A day: the longest a grant on either stream lives.
  @deadline_bound 86_400

  # Fifteen minutes: how long a picture of either stream stands before it
  # is read again. Each change is announced, so a read only mends one the
  # bus lost.
  @stale_after 900

  @doc """
  The streams a canvas reads: `threads.changes` and `activity.changes`,
  each with its shape and refresh (the moduledoc's).
  """
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "threads.changes",
        topic: :threads,
        projection:
          ["kind", "id", "title", "people", "last_activity", "waits_on_you", "unread", "archived"] ++
            Prima.Provider.Stream.delivery_fields(),
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(threads_shape()),
        refresh: {Aqua.ThreadList, :listed},
        key: "id",
        removal: "removed",
        stale_after: @stale_after
      },
      %Prima.Provider.Stream{
        name: "activity.changes",
        topic: :crew_activity,
        projection:
          ["kind", "id", "member", "asked_by", "title", "since", "status"] ++
            Prima.Provider.Stream.delivery_fields(),
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(activity_shape()),
        refresh: {Aqua.Crew.Activity, :open},
        key: "id",
        removal: "ended",
        stale_after: @stale_after
      }
    ]
  end

  # A removal carries its kind and id alone, so every other field is
  # nullable. A title is at most the 200 characters either store keeps.
  defp threads_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{
          "type" => "enum",
          "values" => Enum.map(Cyfr.Bus.ThreadListed.kinds(), &Atom.to_string/1)
        },
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string", "max" => 200, "nullable" => true},
        "people" => %{
          "type" => "list",
          "max" => 1000,
          "nullable" => true,
          "of" => %{"type" => "string", "max" => 4096}
        },
        "last_activity" => %{"type" => "time", "nullable" => true},
        "waits_on_you" => %{"type" => "boolean", "nullable" => true},
        "unread" => %{"type" => "integer", "nullable" => true},
        "archived" => %{"type" => "boolean", "nullable" => true}
      },
      "required" => [
        "kind",
        "id",
        "title",
        "people",
        "last_activity",
        "waits_on_you",
        "unread",
        "archived"
      ]
    })
  end

  defp activity_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["started", "ended"]},
        "id" => %{"type" => "string"},
        "member" => %{"type" => "string"},
        "asked_by" => %{"type" => "string", "max" => 4096, "nullable" => true},
        "title" => %{"type" => "string", "max" => Aqua.Crew.title_max(), "nullable" => true},
        "since" => %{"type" => "time", "nullable" => true},
        "status" => %{"type" => "enum", "values" => Prima.TurnState.statuses()}
      },
      "required" => ["kind", "id", "member", "asked_by", "title", "since", "status"]
    })
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Prima.Canvas.Shape.validate(shape)
    normalized
  end

  # The bounds of a read: a search's query in bytes, the posts it
  # answers, a snippet's bytes, and the rows a turn's read of a thread
  # answers in one page.
  @query_max 200
  @search_max 20
  @snippet_max 240
  @read_page_max 50

  # The most links one post shows.
  @links_max 20
  @url_max 2048
  @link_title_max 200

  @doc false
  def definition do
    alias Prima.{Arg, Operation}
    # `:external` on every action but `post`, `search` and `events`: a
    # running agent must not speak or post but into its own thread, and
    # `post` reaches only that one, named by the lineage; `search` and
    # `events` read, for the person and for a turn of theirs, the
    # athanor's daily and workspace threads. And `:interactive` on every
    # action but `post`: only a person's own session, or its chain, may
    # speak or read as them — never a standing credential.
    # Advisory: maxLength counts graphemes; the governing bound is
    # the runner's 32 KiB byte check, which every sender passes
    # through (the console included).
    Operation.tool(
      [
        Operation.new("thread", "today", "Today's thread", [],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("thread", "list", "List thread", [],
          kind: :read,
          sources: [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside],
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "get",
          "Get thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            )
          ],
          kind: :read,
          sources: [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside],
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "send",
          "Send thread",
          [
            Arg.new("thread", :string,
              description:
                "send: a workspace thread or a crew member's thread; with none, or a daily thread, the send joins today's daily thread"
            ),
            Arg.new("message", :string,
              required: true,
              description: "send: the text to say (at most 32 KiB of text)",
              max: 32768
            ),
            Arg.new("agent", :string,
              description: "send: the agent to address when the text names none"
            ),
            Arg.new(
              "attachments",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("stored_name", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("size", :integer, required: true)
                  ]}
               )},
              description: "send: the refs `attach` answered for this message id"
            ),
            Arg.new("client_id", :string,
              description:
                "send: the sender's own id for this send, so a retry answers the same message"
            ),
            Arg.new("id", :string,
              description:
                "send: a pre-minted message id (mint one, attach the files under it, then send)"
            ),
            Arg.new("model", :string, description: "send: a model override for this turn"),
            Arg.new(
              "room",
              {:record,
               [
                 Arg.new("shared_thread_id", :string, required: true),
                 Arg.new("title", :string)
               ]},
              description:
                "send: the shared thread the sender has open beside this thread (shared_thread_id, title); its newest lines are read under the sender's seat for this one turn, never stored"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "attach",
          "Attach thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description: "attach: the message the files belong to"
            ),
            Arg.new(
              "files",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("data", :string, required: true, bulk: true)
                  ]}
               )},
              required: true,
              description: "attach: the files as {filename, media_type, data} with base64 data"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "discard",
          "Discard thread attachments",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description:
                "discard: the unsent message whose files this session attached, which go"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "stop",
          "Stop thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "restart_for_consent",
          "Restart for consent thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            ),
            Arg.new("profile_id", :string,
              nullable: true,
              description: "restart_for_consent: the profile the consent was granted on"
            ),
            Arg.new("revision", :integer,
              nullable: true,
              description: "restart_for_consent: the consent revision granted"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "events",
          "Events thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            ),
            Arg.new("after_seq", :integer,
              description:
                "events: replay messages after this seq. Omit to start from the beginning."
            ),
            Arg.new("limit", :integer,
              description:
                "events: rows per page (default and ceiling 500; in a turn, posts only, at most #{@read_page_max}). Page by passing the returned cursor as after_seq."
            )
          ],
          kind: :read,
          sources: {:answer, {__MODULE__, :read_sources}},
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "thread",
          "search",
          "Search threads",
          [
            Arg.new("q", :string,
              required: true,
              max: @query_max,
              description:
                "search: the words to find in past posts of the daily and workspace threads, matched as written, case ignored (at most #{@query_max} bytes)"
            ),
            Arg.new("limit", :integer,
              min: 1,
              max: @search_max,
              description:
                "search: how many posts to answer at most (default and ceiling #{@search_max})"
            ),
            Arg.new("before", :string,
              description: "search: the next a previous answer gave, for older posts"
            )
          ],
          kind: :read,
          sources: {:answer, {__MODULE__, :read_sources}},
          planes: [:external, :in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "thread",
          "aloud",
          "Aloud thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            ),
            Arg.new("message_ids", {:array, Arg.new(nil, :string)},
              required: true,
              description:
                "aloud: your own messages to copy, in any order — or your assistant's replies to you in your own athanor"
            ),
            Arg.new("target_thread", :string,
              required: true,
              description: "aloud: the shared thread (sth_…) to say them in, which you sit in"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "archive",
          "Archive thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "post",
          "Post in thread",
          [
            Arg.new("text", :string,
              description: "post: the post's text (at most 32 KiB)",
              max: 32768
            ),
            Arg.new(
              "files",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("data", :string, required: true, bulk: true)
                  ]}
               )},
              description:
                "post: files the post carries, as {filename, media_type, data} with base64 data"
            ),
            Arg.new(
              "links",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("url", :string, required: true),
                    Arg.new("title", :string)
                  ]}
               )},
              description: "post: links the post shows, each {url, title}; never fetched"
            ),
            Arg.new("screenshot", :string,
              max: 64,
              description:
                "post: the message_id a browser.screenshot of this turn answered; the post shows that picture"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:in_chain]
        ),
        Operation.new(
          "thread",
          "delete",
          "Delete thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except today and list)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Talk to an agent: find today's thread or list threads, send a message, follow the reply, stop a turn, archive a thread (a daily or workspace thread goes behind the list's Archived filter until new work there, nothing else changing; a crew member's thread is retired, which stops its work there), and say one of your own private lines aloud into a shared thread you sit in; a running turn posts into its own thread, with files and links. A send with no thread joins today's daily thread and starts a turn of the athanor's assistant, or with @<name> asks that crew member, who works in a thread of its own under it and replies there; a send in a crew member's thread speaks to that member. A send may carry a pre-minted id with files attached under it, a model, an agent, the sender's own client id, and the shared thread open beside it. Wraps the same runner and the same verbs the console drives, with the same gates — this is not a second way to run an agent.",
      title: "Threads"
    )
  end

  @doc false
  def crew_definition do
    alias Prima.{Arg, Operation}
    # In a chain only: the soul's turn hands a job to a crew member, and a
    # person's own ask is an `@name` in `thread.send`. The answer is the
    # request's id and the roster the athanor's own files hold, so
    # neither carries outside material.
    Operation.tool(
      [
        Operation.new(
          "crew",
          "ask",
          "Ask crew",
          [
            Arg.new("member", :string,
              required: true,
              description: "ask: the crew member to hand the job to (crew.list names them)"
            ),
            Arg.new("task", :string,
              required: true,
              description:
                "ask: the job, with everything the member needs to do it (at most 32 KiB)",
              max: 32768
            ),
            Arg.new("title", :string,
              description:
                "ask: a short title for the job, plain text on one line of at most #{Aqua.Crew.title_max()} characters, that a desktop shows for it; omit for none",
              max: Aqua.Crew.title_max()
            ),
            Arg.new("tools", {:array, Arg.new(nil, :string)},
              description:
                "ask: narrow the member's tools for this job to these (a tool, or tool.action); omit for all it holds"
            ),
            Arg.new("options", {:map, Arg.new(nil, :json)},
              description: "ask: options for the member's brain, those it declares"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:in_chain]
        ),
        Operation.new("crew", "list", "List crew", [],
          kind: :read,
          sources: [],
          planes: [:in_chain],
          recovery: :replay_safe
        )
      ],
      description:
        "Hand a job to a crew member: ask sends it, and the member works it in a thread of its own under this one and replies here when it is done, failed or stopped, or when it needs the person; nothing waits for the reply, which arrives as a message of its own. list names the members whose brain is ready, with what each is good at and what to avoid.",
      title: "Crew"
    )
  end

  @doc false
  def threads_definition do
    alias Prima.{Arg, Operation}
    # In a chain only, and read only. What other people said there is
    # theirs, not the athanor's own records, so it carries an outside
    # source into the turn that reads it.
    Operation.tool(
      [
        Operation.new("threads", "list", "List threads", [],
          kind: :read,
          sources: [:outside],
          planes: [:in_chain],
          recovery: :replay_safe
        ),
        Operation.new(
          "threads",
          "read",
          "Read thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "read: the thread's id, as threads.list names it"
            )
          ],
          kind: :read,
          sources: [:outside],
          planes: [:in_chain],
          recovery: :replay_safe
        )
      ],
      description:
        "Read the person's shared threads, the ones they sit in with other people: list names each with its people, when it last moved and how many of its messages the person has not seen; read gives a thread's newest lines, each by who said it, with those the person has not seen marked (unread). Reading marks nothing read and writes nothing. Read a thread only when the person's question needs it.",
      title: "Shared threads"
    )
  end

  @impl true
  def handle("thread", %Context{} = ctx, %{"action" => "post"} = args), do: post(ctx, args)
  def handle("thread", %Context{} = ctx, %{"action" => "search"} = args), do: search(ctx, args)

  def handle("thread", %Context{plane: :guest} = ctx, %{"action" => "events"} = args),
    do: read_thread(ctx, args)

  def handle("thread", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle("crew", %Context{} = ctx, %{"action" => "ask"} = args), do: Aqua.Crew.ask(ctx, args)

  def handle("crew", %Context{} = ctx, %{"action" => "list"} = args),
    do: Aqua.Crew.list(ctx, args)

  def handle("crew", _ctx, _args),
    do: {:error, {:invalid_argument, "crew takes the action ask or list"}}

  def handle("threads", %Context{} = ctx, %{"action" => "list"} = args),
    do: shared_threads(ctx, args)

  def handle("threads", %Context{} = ctx, %{"action" => "read", "thread" => id} = args)
      when is_binary(id),
      do: shared_thread(ctx, id, args)

  def handle("threads", _ctx, _args),
    do: {:error, {:invalid_argument, "threads takes the action list, or read with a thread"}}

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  # The interactive-surface gate is NOT here: it is the `consent:
  # :interactive` declaration on every action, enforced by the registry
  # before the handler runs.

  # `today` and `list` name no thread — they are how a headless client
  # gets an id in the first place, which is what makes this the same
  # surface the console has rather than one that assumes it.
  defp dispatch(ctx, %{"action" => "today"}) do
    case Aqua.Day.current(ctx) do
      {:ok, thread} ->
        Aqua.ThreadList.changed(ctx, thread.id)
        {:ok, render_thread(thread)}

      {:error, reason} ->
        {:error, refusal(reason, nil)}
    end
  end

  defp dispatch(ctx, %{"action" => "list"}) do
    case Arca.ThreadStorage.list(Sanctum.Context.actor(ctx)) do
      rows when is_list(rows) ->
        {:ok, %{threads: Enum.map(rows, &render_thread/1), count: length(rows)}}

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  # A send joins the daily thread current when it is accepted: one that
  # names no thread, or names a daily thread, of today or another day. Its
  # files are stored under the thread they were attached to, so a send
  # that carries files names that thread: a crew member's, or a daily
  # thread that is still today's. One whose day has turned since is
  # refused and leaves nothing behind: no row, no new day's thread, and
  # none of the files this caller stored under the message, so a message
  # never names files another thread holds.
  defp dispatch(ctx, %{"action" => "send"} = args) do
    case sends_to(ctx, args["thread"], args["attachments"] || []) do
      {:ok, id} ->
        act("send", ctx, id, args)

      {:error, :day_turned} ->
        _ = discard_files(ctx, args)
        {:error, refusal(:day_turned, args["thread"])}

      {:error, reason} ->
        {:error, refusal(reason, args["thread"])}
    end
  end

  defp dispatch(ctx, %{"action" => action, "thread" => id} = args)
       when is_binary(id) and id != "" do
    act(action, ctx, id, args)
  end

  defp dispatch(_ctx, _args),
    do: {:error, {:invalid_argument, "thread requires an 'action' and a 'thread'"}}

  defp sends_to(ctx, id, files) when is_binary(id) and id != "" do
    case Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id) do
      {:ok, %{kind: "daily", day: day}} when files != [] ->
        if day == Aqua.Day.today(ctx), do: {:ok, id}, else: {:error, :day_turned}

      {:ok, %{kind: "daily"}} ->
        today_id(ctx)

      {:ok, %{id: id}} ->
        {:ok, id}

      {:error, _} = refused ->
        refused
    end
  end

  defp sends_to(_ctx, _none, [_ | _]), do: {:error, :files_need_thread}
  defp sends_to(ctx, _none, []), do: today_id(ctx)

  # What this caller's own session stored under the refused message, and
  # nothing anyone else stored (`Aqua.Attachments.discard_unsent/3`).
  defp discard_files(ctx, %{"thread" => thread_id, "id" => message_id})
       when is_binary(thread_id) and is_binary(message_id),
       do: Aqua.Attachments.discard_unsent(ctx, thread_id, message_id)

  defp discard_files(_ctx, _args), do: :ok

  defp today_id(ctx) do
    with {:ok, thread} <- Aqua.Day.current(ctx), do: {:ok, thread.id}
  end

  # The whole send envelope: the text, a pre-minted id and the refs
  # attached under it, the agent and model, the sender's client id, and
  # the shared thread open beside it — read server-side under the
  # sender's seat into the text the turn reads beside the task
  # (`Aqua.Loop.Turn`), never stored. The gate has cast every argument
  # against the declaration, so only an empty send is refused here.
  defp act("send", ctx, id, args) do
    text = args["message"]
    attachments = args["attachments"] || []

    if String.trim(text) == "" and attachments == [] do
      {:error, {:invalid_argument, "send requires a non-empty 'message'"}}
    else
      message_id =
        case args["id"] do
          mid when is_binary(mid) and mid != "" -> mid
          _ -> Prima.UUID7.generate_id("msg")
        end

      opts =
        [id: message_id, attachments: attachments]
        |> put_opt(:client_id, args["client_id"])
        |> put_opt(:model, args["model"])
        |> put_opt(:agent, args["agent"])
        |> put_opt(:room, args["room"])

      case Runner.send_message(ctx, id, text, opts) do
        {:ok, accepted} -> {:ok, accepted |> Map.merge(waiting(ctx, id)) |> Map.put(:thread, id)}
        {:error, reason} -> {:error, refusal(reason, id)}
      end
    end
  end

  defp act("get", ctx, id, _args) do
    with {:ok, thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id) do
      {:ok, Map.merge(render_thread(thread), waiting(ctx, id))}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # The files a message carries are written under its id before the
  # send names them, so the bytes are the sender's own write.
  defp act("attach", ctx, id, %{"message_id" => message_id, "files" => files})
       when is_binary(message_id) and is_list(files) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         {:ok, decoded} <- decode_files(files),
         {:ok, refs} <- Aqua.Attachments.store(ctx, id, message_id, decoded) do
      {:ok, %{message_id: message_id, attachments: refs}}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "thread", id}}

      {:error, {:invalid_argument, _} = reason} ->
        {:error, reason}

      {:error, reason} when reason in [:message_sent, :attachment_exists, :database_error] ->
        {:error, attachment_refusal(reason)}

      {:error, reason} ->
        {:error, {:invalid_argument, "attach refused: " <> Sanctum.Refusals.render(reason)}}
    end
  end

  # A send refused after its files were stored, or a held one given up:
  # the files this caller's own session stored under the message go, and
  # nothing anyone else stored (`Aqua.Attachments.discard_unsent/3`).
  defp act("discard", ctx, id, %{"message_id" => message_id}) when is_binary(message_id) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         {:ok, names} <- Aqua.Attachments.discard_unsent(ctx, id, message_id) do
      {:ok, %{message_id: message_id, discarded: names}}
    else
      {:error, :not_found} -> {:error, {:not_found, "thread", id}}
      {:error, reason} -> {:error, attachment_refusal(reason)}
    end
  end

  defp act("restart_for_consent", ctx, id, args) do
    result = %{profile_id: args["profile_id"], revision: args["revision"]}

    case Runner.restart_for_consent(ctx, id, result) do
      :ok -> {:ok, %{restart_prompted: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # A thread is deleted whole — its rows and its blobs, and a room's crew
  # threads with it, their open turns cancelled and the runtime still
  # holding them stopped after — and never under a running turn.
  defp act("delete", ctx, id, _args) do
    cond do
      Runner.turn_running?(ctx, id) ->
        {:error, {:conflict, "a turn is running in this thread — stop it first"}}

      true ->
        case Tape.delete_thread(ctx, id) do
          # The rows are gone either way; a runner that cannot stop its
          # work retires with it.
          {:ok, %{cancelled: cancelled}} ->
            _ = Runner.stop_cancelled(cancelled)
            {:ok, %{deleted: true, thread: id}}

          {:error, :not_found} ->
            {:error, {:not_found, "thread", id}}

          {:error, reason} ->
            {:error, refusal(reason, id)}
        end
    end
  end

  # A daily or a workspace thread is archived: behind the list's Archived
  # filter, with nothing else about it changed, and never while work
  # remains in it. A crew member's thread is retired: it admits nothing
  # more, its open turns end cancelled with their replies in the
  # retirement's own transaction, the runtime still holding them is
  # stopped after, and the next request to the member opens a new one.
  defp act("archive", ctx, id, _args) do
    case Tape.archive(ctx, id) do
      {:ok, archived} ->
        {:ok, Map.put(render_thread(archived), :archived, true)}

      {:error, :not_a_room} ->
        retire(ctx, id)

      {:error, :working} ->
        {:error, {:conflict, "this thread is still working — archive it once nothing runs in it"}}

      {:error, reason} ->
        {:error, refusal(reason, id)}
    end
  end

  defp act("stop", ctx, id, _args) do
    case Runner.stop_turn(ctx, id) do
      :ok -> {:ok, %{stopped: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # The durable truth of a thread is `messages.seq`, so replay is a
  # cursor over rows. Deliberately NOT `Opus.events_since/3`:
  # that is keyed by execution id and carries a turn's in-flight tool
  # deltas, which are the runner's business. A client that reconnects wants
  # what was SAID, and the final rows are enough.
  defp act("events", ctx, id, args) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id) do
      case Arca.ThreadStorage.messages(Sanctum.Context.actor(ctx), id, message_opts(args)) do
        rows when is_list(rows) ->
          rows = Enum.map(rows, &render/1)
          {:ok, %{thread: id, messages: rows, cursor: cursor(rows)}}

        {:error, _} ->
          {:error, {:unavailable, "Storage"}}
      end
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # Saying your own lines aloud into a shared thread you sit in. Everything
  # that matters is decided in `Aqua.Aloud.post/4` — the source athanor's
  # owner, the target's seat, author-only, byte-copied attachments —
  # this wraps it exactly as every other action wraps the runner.
  defp act("aloud", ctx, id, %{"message_ids" => ids, "target_thread" => target_thread})
       when is_list(ids) and is_binary(target_thread) do
    # Bounded in number too: every selected message copies bytes into
    # the shared thread.
    if length(ids) > @aloud_max,
      do: {:error, {:invalid_argument, "aloud takes at most #{@aloud_max} messages at a time"}},
      else: say_aloud(ctx, id, ids, target_thread)
  end

  defp say_aloud(ctx, id, ids, target_thread) do
    case Aqua.Aloud.post(ctx, id, ids, target_thread) do
      {:ok, rows} ->
        {:ok, %{said_aloud: length(rows), target_thread: target_thread}}

      {:error, :not_a_member} ->
        {:error, {:invalid_argument, "aloud reads only threads of your own athanor"}}

      {:error, :not_the_author} ->
        {:error,
         {:invalid_argument,
          "only your own lines can be said aloud — or your own assistant's, from your own athanor"}}

      {:error, :same_thread} ->
        {:error, {:invalid_argument, "that line is already in this thread"}}

      {:error, :nothing_to_say} ->
        {:error, {:invalid_argument, "aloud requires at least one message id"}}

      {:error, :not_found} ->
        {:error, {:invalid_argument, "the selected messages could not be found"}}

      {:error, :attachment_missing} ->
        {:error,
         {:invalid_argument,
          "an attachment on the selected lines is missing — nothing was said aloud"}}

      {:error, reason} ->
        {:error, refusal(reason, id)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp attachment_refusal(:message_sent),
    do: {:conflict, "That message was sent; its attachments stay as they are"}

  defp attachment_refusal(:attachment_exists),
    do:
      {:conflict,
       "A file of that name is already under that message; discard the message's files " <>
         "(thread.discard) first to replace it"}

  defp attachment_refusal(:database_error), do: {:unavailable, "Storage"}

  defp decode_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"filename" => name, "media_type" => media, "data" => data}, {:ok, acc}
      when is_binary(name) and is_binary(media) and is_binary(data) ->
        case Base.decode64(data) do
          {:ok, bytes} ->
            {:cont,
             {:ok, acc ++ [%{"filename" => name, "media_type" => media, "bytes" => bytes}]}}

          :error ->
            {:halt, {:error, {:invalid_argument, "attach: '#{name}' is not base64"}}}
        end

      _, _ ->
        {:halt,
         {:error, {:invalid_argument, "attach: each file needs filename, media_type and data"}}}
    end)
  end

  # What a client is told after speaking: whether a turn runs and how
  # many wait behind it. The message is already accepted by the time this
  # runs, so a faulty status read degrades to "not running, nothing
  # queued" rather than turning the accepted send into an error.
  defp waiting(ctx, id) do
    live =
      case Runner.state(id, ctx.athanor_id) do
        %{} = state -> state
        _ -> %{}
      end

    %{
      sent: true,
      running: live[:running] || false,
      queued: live[:queued] || 0
    }
  end

  @events_page_max 500

  defp message_opts(args) do
    opts =
      case args["after_seq"] do
        seq when is_integer(seq) -> [after_seq: seq]
        _ -> []
      end

    # Bounded like the console's read: an un-cursored `events` on a
    # long-lived thread must not load every row. The cursor pages.
    case args["limit"] do
      n when is_integer(n) and n > 0 -> [{:limit, min(n, @events_page_max)} | opts]
      _ -> [{:limit, @events_page_max} | opts]
    end
  end

  # Runner and storage refusals, translated to the typed vocabulary at the
  # boundary: an atom is the runner's business, and rendered raw it
  # collapses to a generic "the tool call failed". `translate/2`'s
  # catch-all passes anything it does not name through untouched, a
  # reason already in the vocabulary included; what it does name is this
  # domain's spelling and wins over a shared one — `:unavailable` here is
  # the thread store, not the storage-unit outcome `Prima.Refusal` maps.
  # A crew member's thread `thread.archive` names is retired.
  defp retire(ctx, id) do
    with {:ok, %{thread: retired, cancelled: cancelled}} <- Tape.retire(ctx, id),
         :ok <- Runner.stop_cancelled(cancelled) do
      {:ok, Map.put(render_thread(retired), :retired, true)}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp refusal(reason, id), do: translate(reason, id)

  defp translate(:not_found, id), do: {:not_found, "thread", id}

  defp translate(:empty, _id), do: {:invalid_argument, "send requires a non-empty 'message'"}

  defp translate(:day_turned, _id),
    do:
      {:conflict,
       "The day has turned since these files were attached. Attach them again and send."}

  defp translate(:files_need_thread, _id),
    do: {:invalid_argument, "A send with files names the thread they were attached to."}

  defp translate(:unavailable, _id), do: {:unavailable, "Threads"}
  defp translate(:database_error, _id), do: {:unavailable, "Storage"}

  defp translate(:superseded, _id),
    do: {:conflict, "The turn's owner changed. Retry the operation."}

  defp translate(:not_open, _id),
    do: {:conflict, "The turn changed while this request was running. Retry the operation."}

  defp translate(:workers_not_stopped, _id),
    do: {:timeout, "Some workers have not stopped yet. Retry Stop."}

  defp translate(:workers_unavailable, _id), do: {:unavailable, "Worker coordination"}

  # An unmapped reason stays as it is — the router logs it and answers
  # generically, which is the visible cue that a new refusal needs a row
  # above.
  defp translate(other, _id), do: other

  # ---------------------------------------------------------------------------
  # A turn's post
  # ---------------------------------------------------------------------------

  # Into the thread the turn runs in, which the lineage names, under the
  # turn's fence: its files stored under the post's own id first, and
  # discarded when the post is not written. A chain with no turn behind it
  # posts nothing.
  defp post(%Context{plane: :guest} = ctx, args) do
    text = String.trim(args["text"] || "")
    shot = args["screenshot"]

    with {:ok, files} <- decode_files(args["files"] || []),
         {:ok, links} <- links(args["links"]),
         :ok <- something(text, files ++ List.wrap(shot), links),
         {:ok, turn} <- calling(ctx, args),
         {:ok, drafted} <- drafted(ctx, turn, shot) do
      id = Prima.UUID7.generate_id("msg")

      with {:ok, refs} <- Aqua.Attachments.copy(ctx, turn.thread_id, id, files ++ drafted),
           {:ok, row} <-
             Tape.post(ctx, turn, %{id: id, content: text, payload: posted(refs, links)}) do
        # Published: the draft's own bytes go, the post keeps its copy.
        drop_draft(ctx, turn, shot)
        {:ok, %{posted: row.id, thread: turn.thread_id, seq: row.seq, files: length(refs)}}
      else
        {:error, reason} ->
          _ = Aqua.Attachments.discard(ctx, turn.thread_id, id)
          release_draft(ctx, turn, shot)
          {:error, post_refusal(reason)}
      end
    end
  end

  defp post(%Context{}, _args), do: {:error, :not_in_a_turn}

  # The screenshot this attempt of the turn took and has not posted,
  # claimed for this post (`Aqua.Attachments.drafted/3`).
  defp drafted(_ctx, _turn, nil), do: {:ok, []}

  defp drafted(ctx, turn, shot) do
    case Aqua.Attachments.drafted(ctx, turn, shot) do
      {:ok, file} -> {:ok, [file]}
      {:error, :not_a_draft} -> {:error, {:invalid_argument, not_a_draft()}}
      {:error, reason} -> {:error, post_refusal(reason)}
    end
  end

  defp drop_draft(_ctx, _turn, nil), do: :ok
  defp drop_draft(ctx, turn, shot), do: _ = Aqua.Attachments.discard(ctx, turn.thread_id, shot)

  defp release_draft(_ctx, _turn, nil), do: :ok
  defp release_draft(ctx, turn, shot), do: Aqua.Attachments.release(ctx, turn.thread_id, shot)

  @doc false
  def not_a_draft,
    do:
      "That screenshot is not one this turn took and has not posted yet; take the screenshot again and post the message id it answers."

  defp calling(ctx, args) do
    case Tape.held_turn(ctx, args) do
      {:ok, turn} -> {:ok, turn}
      {:error, :not_addressable} -> {:error, :not_in_a_turn}
      {:error, reason} -> {:error, post_refusal(reason)}
    end
  end

  defp something("", [], []),
    do:
      {:error, {:invalid_argument, "post requires a 'text', 'files', 'links' or a 'screenshot'"}}

  defp something(text, _files, _links) when byte_size(text) > 32 * 1024,
    do: {:error, :message_too_long}

  defp something(_text, _files, _links), do: :ok

  # A post the turn wrote through `post`: the model reads it from its own
  # call (`Aqua.Loop.Request`), never twice.
  defp posted(refs, links) do
    %{"post" => true}
    |> then(fn p -> if refs == [], do: p, else: Map.put(p, "attachments", refs) end)
    |> then(fn p -> if links == [], do: p, else: Map.put(p, "links", links) end)
  end

  # A link is an http or https address with a host, shown and never
  # fetched, with a title of plain text.
  defp links(nil), do: {:ok, []}

  defp links(links) when is_list(links) and length(links) > @links_max,
    do: {:error, {:invalid_argument, "post shows at most #{@links_max} links"}}

  defp links(links) when is_list(links) do
    Enum.reduce_while(links, {:ok, []}, fn link, {:ok, acc} ->
      case link(link) do
        {:ok, link} -> {:cont, {:ok, acc ++ [link]}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  defp links(_links), do: {:error, {:invalid_argument, "post takes 'links' as {url, title}"}}

  defp link(%{"url" => url} = link) when is_binary(url) and byte_size(url) <= @url_max do
    title = String.trim(link["title"] || "")

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{"url" => url, "title" => String.slice(title, 0, @link_title_max)}}

      _ ->
        {:error, {:invalid_argument, "post shows only http and https links"}}
    end
  end

  defp link(_link), do: {:error, {:invalid_argument, "post takes 'links' as {url, title}"}}

  defp post_refusal(reason)
       when reason in [:too_many_attachments, :attachment_too_large, :storage_full],
       do: {:invalid_argument, "post refused: " <> Sanctum.Refusals.render(reason)}

  defp post_refusal(reason), do: refusal(reason, nil)

  # ---------------------------------------------------------------------------
  # Recall: searching past posts, and a turn's read of a thread
  # ---------------------------------------------------------------------------

  @doc """
  What a read's answer carries (`search` and `events`, their `sources:`
  declaration, `Prima.Operation.answer_sources/3`): the sources the read
  joined into its turn before it answered (`Aqua.Tape.join_read/5`), each
  thread it carries posts of among them, which the answer names. An answer
  that names none, the person's own read at the door, is an unnamed
  outside source, never the athanor's own.
  """
  @spec read_sources(Prima.Actor.t() | nil, term()) :: [Prima.Source.t()]
  def read_sources(_actor, %{sources: sources}) when is_list(sources),
    do: sources |> Enum.map(&Prima.Source.from_json/1) |> Prima.Source.set()

  def read_sources(_actor, _answer), do: [Prima.Source.outside(nil)]

  # Past posts of the athanor's daily and workspace threads, newest first,
  # each as a pointer to open with `events`. From a turn, the posts it
  # answers join the turn's sources first, under its fence, and only the
  # posts of threads that still stand then are answered.
  defp search(ctx, args) do
    with {:ok, needle} <- query(args["q"]),
         {:ok, reader} <- recall_reader(ctx, args),
         {:ok, found} <-
           storage(
             Arca.ThreadStorage.search(Sanctum.Context.actor(ctx), needle,
               limit: min(args["limit"] || @search_max, @search_max),
               before: args["before"]
             ),
             "before",
             args["before"]
           ),
         {:ok, posts, sources} <- joined(ctx, reader, found.posts, & &1.message) do
      results = Enum.map(posts, &pointer(&1, needle))
      {:ok, with_sources(%{results: results, count: length(results), next: found.next}, sources)}
    end
  end

  # A turn's read of one daily or workspace thread of its athanor: its
  # posts after `after_seq`, at most fifty, joined into the turn's sources
  # before they are answered. A crew member's thread, or one of another
  # athanor, is not found.
  defp read_thread(ctx, %{"thread" => id} = args) when is_binary(id) and id != "" do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, reader} <- recall_reader(ctx, args),
         {:ok, %{kind: kind}} when kind in ["daily", "workspace"] <-
           Arca.ThreadStorage.get(actor, id),
         rows when is_list(rows) <- Arca.ThreadStorage.messages(actor, id, read_opts(args)),
         {:ok, rows, sources} <- joined(ctx, reader, rows, & &1) do
      rows = Enum.map(rows, &render/1)
      {:ok, with_sources(%{thread: id, messages: rows, cursor: cursor(rows)}, sources)}
    else
      {:ok, %{}} -> {:error, {:not_found, "thread", id}}
      {:error, :not_found} -> {:error, {:not_found, "thread", id}}
      {:error, {_kind, _detail} = refusal} -> {:error, refusal}
      {:error, {_kind, _a, _b} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp read_thread(_ctx, _args),
    do: {:error, {:invalid_argument, "events requires a 'thread'"}}

  defp read_opts(args) do
    after_seq = if is_integer(args["after_seq"]), do: [after_seq: args["after_seq"]], else: []

    limit =
      case args["limit"] do
        n when is_integer(n) and n > 0 -> min(n, @read_page_max)
        _ -> @read_page_max
      end

    [{:limit, limit}, {:posts, true} | after_seq]
  end

  defp query(q) when is_binary(q) do
    cond do
      byte_size(q) > @query_max ->
        {:error, {:invalid_argument, "search takes a query of at most #{@query_max} bytes"}}

      String.trim(q) == "" ->
        {:error, {:invalid_argument, "search needs a query"}}

      true ->
        {:ok, String.trim(q)}
    end
  end

  defp query(_q), do: {:error, {:invalid_argument, "search needs a query"}}

  # Who reads: the person at the door, or in a chain the open turn of the
  # person's Aqua the lineage names, held by the holder that made the call.
  defp recall_reader(%Context{plane: :guest, user_id: user_id} = ctx, args)
       when is_binary(user_id) do
    case Tape.held_turn(ctx, args) do
      {:ok, %{requested_by: ^user_id} = turn} -> {:ok, {:turn, turn}}
      {:ok, _someone_else} -> {:error, :not_in_a_turn}
      {:error, :not_addressable} -> {:error, :not_in_a_turn}
      {:error, reason} -> {:error, refusal(reason, nil)}
    end
  end

  defp recall_reader(%Context{plane: :guest}, _args), do: {:error, :not_in_a_turn}
  defp recall_reader(%Context{}, _args), do: {:ok, :person}

  # The rows a read answers, and the sources it carries. The person's read
  # joins nothing. A turn's joins, under its fence, every thread whose
  # posts the rows are or carry, what the rows carry, and the turns that
  # wrote them (`Aqua.Tape.join_read/5`); a row of a thread or carrying one
  # that no longer stands is not answered.
  defp joined(_ctx, :person, items, _row), do: {:ok, items, nil}

  defp joined(ctx, {:turn, turn}, items, row) do
    rows = Enum.map(items, row)
    carried = Tape.carried_sources(rows)
    threads = Enum.uniq(Enum.map(rows, & &1.thread_id) ++ Prima.Source.threads(carried))

    case Tape.join_read(
           ctx,
           turn,
           threads,
           Prima.Source.material(carried),
           Tape.writing_turns(rows)
         ) do
      {:ok, %{threads: standing, sources: sources}} ->
        kept =
          Enum.filter(items, fn item ->
            row = row.(item)
            needs = [row.thread_id | Prima.Source.threads(Tape.carried_sources([row]))]
            Enum.all?(needs, &(&1 in standing))
          end)

        {:ok, kept, sources}

      {:error, reason} ->
        {:error, refusal(reason, nil)}
    end
  end

  defp with_sources(answer, nil), do: answer

  defp with_sources(answer, sources),
    do: Map.put(answer, :sources, Prima.Source.to_json_list(sources))

  defp storage({:ok, _} = ok, _arg, _value), do: ok

  defp storage({:error, :not_found}, arg, value),
    do: {:error, {:invalid_argument, "#{arg} '#{value}' is not a post of this athanor"}}

  defp storage({:error, _}, _arg, _value), do: {:error, {:unavailable, "Storage"}}

  # One post a search found: where it is, who wrote it, and the text
  # around the match.
  defp pointer(%{message: message, thread: thread}, needle) do
    %{
      thread: thread.id,
      kind: thread.kind,
      message: message.id,
      seq: message.seq,
      by: message.sent_by,
      at: message.inserted_at,
      snippet: snippet(message.content || "", needle)
    }
    |> Map.merge(if thread.kind == "daily", do: %{day: thread.day}, else: %{title: thread.title})
  end

  @doc """
  The text of `content` around the first place it holds `needle`, case
  folded as the search folds it: whole characters only, on one line, at
  most #{@snippet_max} bytes, an ellipsis where text was left out.
  """
  @spec snippet(String.t(), String.t()) :: String.t()
  def snippet(content, needle) when is_binary(content) and is_binary(needle) do
    graphemes = content |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.graphemes()
    at = match_at(graphemes, String.downcase(needle))
    from = max(at - 40, 0)
    lead = if from > 0, do: "…", else: ""
    window(Enum.drop(graphemes, from), lead, byte_size(lead))
  end

  # The index of the grapheme the first match begins in, 0 for none.
  defp match_at(graphemes, needle) do
    lowered = Enum.map(graphemes, &String.downcase/1)

    case :binary.match(IO.iodata_to_binary(lowered), needle) do
      {offset, _} ->
        lowered
        |> Enum.scan(0, &(byte_size(&1) + &2))
        |> Enum.find_index(&(&1 > offset))
        |> Kernel.||(0)

      :nomatch ->
        0
    end
  end

  # Graphemes from the start until the bound, leaving room for a closing
  # ellipsis when any are left out.
  defp window(graphemes, lead, used) do
    total = graphemes |> Enum.map(&byte_size/1) |> Enum.sum()

    if used + total <= @snippet_max do
      lead <> Enum.join(graphemes)
    else
      room = @snippet_max - used - byte_size("…")

      {taken, _} =
        Enum.reduce_while(graphemes, {[], 0}, fn g, {acc, size} ->
          if size + byte_size(g) <= room,
            do: {:cont, {[g | acc], size + byte_size(g)}},
            else: {:halt, {acc, size}}
        end)

      lead <> (taken |> Enum.reverse() |> Enum.join()) <> "…"
    end
  end

  # ---------------------------------------------------------------------------
  # Shared threads, read for the person
  # ---------------------------------------------------------------------------

  # From a turn of the person's own Aqua, and under their own seat: the
  # threads they sit in, and only those. A chain with no open turn behind
  # it, such as a component's run started by a key, a webhook or a
  # schedule, reads none; the turn's person is the caller's.
  defp shared_threads(ctx, args) do
    with {:ok, user_id} <- reader(ctx, args),
         {:ok, listed} <- Sanctum.SharedThreads.listed(user_id) do
      threads =
        for entry <- listed do
          %{
            id: entry.id,
            title: entry.title,
            people: entry.people,
            last_activity: entry.last_activity,
            unread: entry.unread
          }
        end

      {:ok, %{threads: threads, count: length(threads)}}
    end
  end

  # A thread the person's list of threads does not name, one they hold no
  # seat in or one archived, answers as a missing one does.
  defp shared_thread(ctx, id, args) do
    with {:ok, _user_id} <- reader(ctx, args),
         {:ok, %{text: text, unread: unread}} <-
           Aqua.RoomExcerpt.read_marked(ctx, %{shared_thread_id: id}) do
      {:ok, %{thread: id, unread: unread, text: text}}
    end
  end

  defp reader(%Context{user_id: user_id} = ctx, args) when is_binary(user_id) do
    case Aqua.Tape.calling_turn(ctx, args) do
      {:ok, %{requested_by: ^user_id}} -> {:ok, user_id}
      {:ok, _someone_else} -> {:error, :not_in_a_turn}
      {:error, :not_addressable} -> {:error, :not_in_a_turn}
      {:error, _} = refused -> refused
    end
  end

  defp reader(_ctx, _args), do: {:error, :not_in_a_turn}

  defp render_thread(thread) do
    %{
      id: thread.id,
      title: thread.title,
      kind: thread.kind,
      day: thread.day,
      parent_id: thread.parent_id,
      agent: if(thread.kind == "crew", do: thread.agent),
      archived_at: thread.archived_at,
      retired_at: thread.retired_at,
      created_by: thread.created_by,
      last_message_at: thread.last_message_at,
      at: thread.inserted_at
    }
  end

  defp cursor([]), do: nil
  defp cursor(rows), do: rows |> List.last() |> Map.get(:seq)

  defp render(msg) do
    %{
      id: msg.id,
      seq: msg.seq,
      author: msg.author,
      kind: msg.kind,
      content: msg.content,
      status: msg.status,
      at: msg.inserted_at
    }
  end
end
