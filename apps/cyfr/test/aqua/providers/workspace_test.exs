# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.WorkspaceTest.DyingCopy do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A report's copy (`Aqua.Crew` names a report's row `msg_rpt_…`): the
  # hook the delivering process holds runs before the bytes are written,
  # and the try dies once they are, as a node that goes down
  # mid-delivery does.
  def put(actor, path, content) do
    if Enum.any?(path, &String.starts_with?(&1, "msg_rpt_")) do
      if hook = Process.get(:before_report_copy), do: hook.()
      :ok = Arca.Adapters.Local.put(actor, path, content)
      raise "the node went down mid-delivery"
    else
      Arca.Adapters.Local.put(actor, path, content)
    end
  end
end

defmodule Aqua.Providers.WorkspaceTest.LostDatabase do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A copy whose bytes say so is written, and then the database is lost,
  # as a connection dropped while an opening's transaction still runs:
  # the transaction is rolled back with the copy already on disk. The
  # path written is told to the writing process.
  def put(actor, path, content) do
    :ok = Arca.Adapters.Local.put(actor, path, content)

    if content == "the database goes once this is copied" do
      send(self(), {:copied, path})
      raise DBConnection.ConnectionError, "the database went away mid-opening"
    end

    :ok
  end
end

defmodule Aqua.Providers.WorkspaceTest do
  @moduledoc """
  Workspace threads: opened from a daily thread in one transaction with
  their pointer and the record that starts the soul's turn there, reporting
  back to the daily thread current when the report is delivered, every
  move of their state in the transaction of the write that moves it, and
  forgotten with everything other threads kept of them. The crew's
  delivery consumer is off in the suite (`:crew_delivery_enabled`), so
  each case drains by hand, as its wake and its tick do.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Crew, Runner, Tape}
  alias Aqua.Providers.Workspace
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedWorker

  @model "catalyst:local.claude"
  @west "Etc/GMT+12"
  @east "Etc/GMT-14"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    ctx = person!()
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, %{provisioned_at: %DateTime{}}} = provisioned(ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, daily} = Arca.Test.Days.thread(actor(ctx))
    {:ok, ctx: ctx, daily: daily}
  end

  defp person! do
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)
    Process.put({__MODULE__, :athanor, ctx.athanor_id}, athanor)
    ctx
  end

  defp provisioned(ctx),
    do: Sanctum.Provisioning.provision(Process.get({__MODULE__, :athanor, ctx.athanor_id}), ctx)

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp actor(ctx), do: Sanctum.Context.actor(ctx)
  defp rows(ctx, thread_id), do: Threads.messages(actor(ctx), thread_id)
  defp thread(ctx, id), do: elem(Threads.get(actor(ctx), id), 1)
  defp drain(ctx), do: Crew.drain(ctx.athanor_id)

  defp records(ctx, kind) do
    {:ok, records} = Arca.Outbox.pending(actor(ctx), "crew_delivery", kind)
    records
  end

  defp await_status(ctx, turn_id, status) do
    wait_until(
      fn -> match?({:ok, %{status: ^status}}, Tape.turn(ctx, turn_id)) end,
      45_000,
      "turn #{turn_id} to be #{status}"
    )
  rescue
    error in ExUnit.AssertionError ->
      {:ok, turn} = Tape.turn(ctx, turn_id)
      flunk("#{error.message}; it is #{turn.status} (#{inspect(turn.error)})")
  end

  # A post of the person's on a thread, which opens nothing.
  defp post!(ctx, thread, text, attachments \\ []) do
    payload = if attachments == [], do: nil, else: %{"attachments" => attachments}

    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text, payload: payload}
      })

    row
  end

  # The person opens a workspace thread from a post of the daily thread.
  defp open(ctx, daily, args) do
    asked = post!(ctx, daily, "please write the moon report")

    Workspace.handle(
      "workspace",
      ctx,
      Map.merge(
        %{
          "action" => "open",
          "thread" => daily.id,
          "refs" => [asked.id],
          "title" => "Moon report",
          "ask" => "write the moon report"
        },
        args
      )
    )
  end

  defp open!(ctx, daily, args \\ %{}) do
    {:ok, %{workspace: id}} = open(ctx, daily, args)
    thread(ctx, id)
  end

  # A turn of the person's in a thread, accepted and never run.
  defp turn!(ctx, thread_id, text \\ "go on") do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), thread_id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # A turn a page's call opens in a thread, on the call's own row, as the
  # runner opens one (`Aqua.Runner`), accepted and never run.
  defp page_turn!(ctx, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "page_call",
          content: "component.list",
          client_id: Prima.UUID7.generate_id("pgc")
        },
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  # The threads a turn has read, as its row records them.
  defp read!(turn, threads) do
    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [read_threads: Arca.ThreadStorage.threads_text(threads)]
      )
  end

  defp read_threads(ctx, turn_id) do
    {:ok, %{read_threads: read}} = Tape.turn(ctx, turn_id)
    Arca.ThreadStorage.threads_of(read)
  end

  defp stop!(ctx, turn) do
    {:ok, current} = Tape.turn(ctx, turn.id)
    {:ok, _} = Tape.finish(ctx, current, "cancelled", %{error: "stopped"})
  end

  # The turn a workspace thread's first opening still waiting opens, as
  # its delivery opens it, accepted and never run.
  defp work!(ctx, workspace) do
    [opening | _] =
      Enum.filter(rows(ctx, workspace.id), &(&1.kind == "opening" and is_nil(&1.turn_id)))

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(ctx), workspace.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: opening.content},
        opening_id: opening.id,
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    turn
  end

  defp outcome(ctx, %Prima.OutboxRecord{} = record) do
    Arca.ConsumerReceipts.outcome(actor(ctx), "crew_delivery", Prima.OutboxRecord.source(record))
  end

  defp chats(chain_head) do
    Enum.filter(
      ScriptedWorker.calls(),
      &(&1.input["operation"] == "chat" and hd(&1.authority.chain) == chain_head)
    )
  end

  defp sent(call), do: Jason.encode!(call.input["params"]["messages"])

  # A workspace thread whose turn reported done with a chart it posted,
  # the turn stopped: the `workspace_report` record waiting for its
  # delivery.
  defp charted!(ctx, daily) do
    script!([reply("Working."), reply("Here it is.")])
    workspace = open!(ctx, daily)
    turn = work!(ctx, workspace)
    chart = Prima.UUID7.generate_id("msg")
    png = %{"filename" => "chart.png", "media_type" => "image/png", "bytes" => "PNG-chart"}
    {:ok, [ref]} = Aqua.Attachments.copy(ctx, workspace.id, chart, [png])

    {:ok, _} =
      Tape.post(ctx, turn, %{
        id: chart,
        content: "",
        payload: %{"post" => true, "attachments" => [ref]}
      })

    {:ok, _} =
      Tape.report_workspace(ctx, turn, "done", %{
        summary: "Charted.",
        attachments: [%{"message_id" => chart, "stored_name" => ref["stored_name"]}]
      })

    stop!(ctx, turn)
    [record] = records(ctx, "workspace_report")
    record
  end

  # `fun` under the double whose report copy dies once written: a
  # delivery try in it dies there.
  defp dying_try(fun) do
    {answer, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Prima.Test.Env.with_app_env(:arca, :storage_adapter, __MODULE__.DyingCopy, fun)
      end)

    answer
  end

  # `fun` under the double that loses the database once an opening's copy
  # is written.
  defp lost_database(fun) do
    {answer, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Prima.Test.Env.with_app_env(:arca, :storage_adapter, __MODULE__.LostDatabase, fun)
      end)

    answer
  end

  # The files stored under the message `id` of `thread_id`.
  defp copies(ctx, thread_id, id) do
    case Arca.list_recursive(actor(ctx), Arca.ThreadStorage.blob_root(thread_id) ++ [id]) do
      {:ok, files} -> files
      {:error, :not_found} -> []
    end
  end

  describe "opening" do
    test "the soul opens one from its daily turn: the thread, its opening and the daily thread's pointer land with one record, and the turn goes on",
         %{ctx: ctx, daily: daily} do
      script!([
        call("w1", "workspace", %{
          "action" => "open",
          "title" => "Moon report",
          "ask" => "write the moon report"
        }),
        reply("I opened a workspace thread for it."),
        reply("Working on the moon report.")
      ])

      {:ok, %{turn_id: soul, message_id: asked}} =
        Runner.send_message(ctx, daily.id, "make me a moon report")

      await_status(ctx, soul, "completed")

      [workspace] = Threads.list(actor(ctx), kind: "workspace")

      assert %{title: "Moon report", workspace_state: "open", opened_from: ^asked} = workspace

      assert [%{kind: "opening", sent_by: "person", author: author} = opening] =
               rows(ctx, workspace.id)

      assert author == ctx.user_id
      daily_id = daily.id

      assert %{
               "ask" => "write the moon report",
               "asked_by" => asked_by,
               "from" => %{"thread" => ^daily_id, "message" => ^asked},
               "refs" => [],
               "apart" => false,
               "title" => "Moon report"
             } = Tape.payload(opening)

      assert asked_by == ctx.user_id

      pointer = Enum.find(rows(ctx, daily.id), &(&1.kind == "pointer"))
      assert %{sent_by: "aqua", workspace_id: workspace_id} = pointer
      assert workspace_id == workspace.id

      assert [%{snapshot: %{"opening_id" => opening_id}}] = records(ctx, "workspace_open")
      assert opening_id == opening.id

      # Delivered, the soul's turn there opens on the opening itself,
      # offered every tool the soul holds: nothing narrows its work.
      assert {:ok, %{"applied" => 1}} = drain(ctx)
      %{turn_id: turn_id} = Enum.find(rows(ctx, workspace.id), &(&1.id == opening.id))
      await_status(ctx, turn_id, "completed")

      assert {:ok, %{message_id: ^opening_id, agent: "aqua", options: options}} =
               Tape.turn(ctx, turn_id)

      refute Map.has_key?(Jason.decode!(options), "tools")

      # Its first turn reads its envelope: the ask, attributed to the person.
      first =
        Enum.find(chats("agent:local.aqua"), &(sent(&1) =~ "asked, in this workspace thread"))

      assert sent(first) =~ ~s(asked, in this workspace thread \\"Moon report\\")
      assert sent(first) =~ "write the moon report"

      # Each turn of the soul reads where it is from its prompt: the daily
      # thread's, and the workspace thread's with its title and ask.
      assert first.input["params"]["system"] =~ "## Where you are"

      assert first.input["params"]["system"] =~
               ~s(You are working the workspace thread "Moon report")

      assert first.input["params"]["system"] =~ "> write the moon report"

      daily_call = Enum.find(chats("agent:local.aqua"), &(sent(&1) =~ "make me a moon report"))
      assert daily_call.input["params"]["system"] =~ "## Where you are"
      assert daily_call.input["params"]["system"] =~ "on the person's daily thread"
      refute daily_call.input["params"]["system"] =~ "working the workspace thread"

      # Once.
      assert {:ok, %{}} = drain(ctx)
      assert records(ctx, "workspace_open") == []
    end

    test "an opening whose transaction fails once its files are copied writes nothing and " <>
           "leaves none of the copies",
         %{ctx: ctx, daily: daily} do
      blob = %{
        "filename" => "moon.png",
        "media_type" => "image/png",
        "bytes" => "the database goes once this is copied"
      }

      shot = Prima.UUID7.generate_id("msg")
      {:ok, [ref]} = Aqua.Attachments.store(ctx, daily.id, shot, [blob])

      {:ok, _} =
        Tape.accept(ctx, daily.id, %{
          message: %{
            id: shot,
            author: ctx.user_id,
            sent_by: "person",
            content: "this one",
            payload: %{"attachments" => [ref]}
          }
        })

      daily_rows = rows(ctx, daily.id)

      assert {:error, {:unavailable, "Storage"}} =
               lost_database(fn ->
                 open(ctx, daily, %{
                   "attachments" => [%{"message_id" => shot, "stored_name" => ref["stored_name"]}]
                 })
               end)

      # The copy was written under the workspace thread the opening named,
      # and is gone with the transaction.
      assert_received {:copied, ["threads", workspace_id, opening_id, "0-moon.png"]}
      refute_received {:copied, _}
      refute Arca.exists?(actor(ctx), ["threads", workspace_id, opening_id, "0-moon.png"])
      assert copies(ctx, workspace_id, opening_id) == []

      # Nothing of the opening was written: no thread, no pointer (the post
      # it was asked from is the daily thread's one new row), no record,
      # and the post's own file stays.
      assert Threads.list(actor(ctx), kind: "workspace") == []
      assert {:error, :not_found} = Threads.get(actor(ctx), workspace_id)
      assert [%{kind: kind}] = rows(ctx, daily.id) -- daily_rows
      refute kind == "pointer"
      assert records(ctx, "workspace_open") == []
      assert copies(ctx, daily.id, shot) == [["threads", daily.id, shot, ref["stored_name"]]]
    end

    test "an opening from a post whose file was deleted from Files says the file is no longer " <>
           "kept, and writes nothing",
         %{ctx: ctx, daily: daily} do
      blob = %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "PNG!"}
      shot = Prima.UUID7.generate_id("msg")
      {:ok, [ref]} = Aqua.Attachments.store(ctx, daily.id, shot, [blob])

      {:ok, _} =
        Tape.accept(ctx, daily.id, %{
          message: %{
            id: shot,
            author: ctx.user_id,
            sent_by: "person",
            content: "this one",
            payload: %{"attachments" => [ref]}
          }
        })

      {:ok, _} = Arca.Files.delete(actor(ctx), "threads/#{daily.id}/#{shot}")

      assert {:error, reason} =
               open(ctx, daily, %{
                 "attachments" => [%{"message_id" => shot, "stored_name" => ref["stored_name"]}]
               })

      assert Prima.Refusal.message(reason) == "A file it carried is no longer kept"
      assert Threads.list(actor(ctx), kind: "workspace") == []
      refute Enum.any?(rows(ctx, daily.id), &(&1.kind == "pointer"))
      assert records(ctx, "workspace_open") == []
    end

    test "two openings at once make two workspace threads, each with its pointer and record",
         %{ctx: ctx, daily: daily} do
      opened =
        ["Moon report", "Sun report"]
        |> Enum.map(fn title -> Task.async(fn -> open(ctx, daily, %{"title" => title}) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert [{:ok, %{workspace: a}}, {:ok, %{workspace: b}}] = opened
      assert a != b

      assert Threads.list(actor(ctx), kind: "workspace") |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([a, b])

      pointed = for %{kind: "pointer", workspace_id: id} <- rows(ctx, daily.id), do: id
      assert Enum.sort(pointed) == Enum.sort([a, b])

      assert records(ctx, "workspace_open") |> Enum.map(& &1.source_id) |> Enum.sort() ==
               Enum.sort([a, b])
    end

    test "a thread, a post or a workspace thread of another athanor is not found, and nothing is written",
         %{ctx: ctx, daily: daily} do
      other = person!()
      {:ok, theirs} = Arca.Test.Days.thread(actor(other))
      their_post = post!(other, theirs, "theirs")
      their_workspace = open!(other, theirs)

      assert {:error, {:not_found, "thread", _}} =
               Workspace.handle("workspace", ctx, %{
                 "action" => "open",
                 "thread" => theirs.id,
                 "refs" => [their_post.id],
                 "title" => "Mine",
                 "ask" => "take theirs"
               })

      assert {:error, {:not_found, "post", _}} = open(ctx, daily, %{"refs" => [their_post.id]})

      assert {:error, {:not_found, "thread", _}} =
               open(ctx, daily, %{"title" => nil, "workspace" => their_workspace.id})

      assert {:error, {:invalid_argument, _}} =
               open(ctx, daily, %{
                 "attachments" => [%{"message_id" => their_post.id, "stored_name" => "0-x"}]
               })

      assert Threads.list(actor(ctx), kind: "workspace") == []
      assert records(ctx, "workspace_open") == []
    end

    test "a caller that is no turn of the soul in a daily thread, a forged lineage among them, opens nothing",
         %{ctx: ctx, daily: daily} do
      guest = Sanctum.Context.enter_guest(ctx)
      args = %{"action" => "open", "title" => "Moon report", "ask" => "write it"}

      # A lineage that names no open turn.
      assert {:error, {:invalid_argument, _}} =
               Workspace.handle(
                 "workspace",
                 guest,
                 Map.merge(args, %{"thread_id" => daily.id, "root_execution_id" => "exe_forged"})
               )

      # The person's session names a daily thread and its posts, or nothing.
      assert {:error, {:invalid_argument, _}} = Workspace.handle("workspace", ctx, args)

      assert {:error, {:invalid_argument, _}} =
               Workspace.handle("workspace", ctx, Map.merge(args, %{"thread" => daily.id}))

      workspace = open!(ctx, daily)

      assert {:error, {:invalid_argument, _}} =
               Workspace.handle(
                 "workspace",
                 ctx,
                 Map.merge(args, %{"thread" => workspace.id, "refs" => ["msg_x"]})
               )

      # Titles are one line of at most 64 characters, refs at most twenty.
      assert {:error, {:invalid_argument, _}} =
               open(ctx, daily, %{"title" => String.duplicate("m", 65)})

      assert {:error, {:invalid_argument, _}} = open(ctx, daily, %{"title" => "two\nlines"})

      assert {:error, {:invalid_argument, _}} =
               open(ctx, daily, %{"refs" => Enum.map(1..21, &"msg_#{&1}")})

      assert [_one] = Threads.list(actor(ctx), kind: "workspace")
    end
  end

  describe "posting and reporting under the turn's fence" do
    test "a superseded or ended turn posts and reports nothing", %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      turn = turn!(ctx, workspace.id)

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          inc: [fence: 1]
        )

      before = rows(ctx, workspace.id)
      id = Prima.UUID7.generate_id("msg")

      assert {:error, :superseded} =
               Tape.post(ctx, turn, %{id: id, content: "late", payload: nil})

      assert {:error, :superseded} = Tape.report_workspace(ctx, turn, "done", %{summary: "late"})
      assert rows(ctx, workspace.id) == before
      assert records(ctx, "workspace_report") == []
      assert thread(ctx, workspace.id).workspace_state == "open"

      {:ok, current} = Tape.turn(ctx, turn.id)
      {:ok, _} = Tape.finish(ctx, current, "cancelled", %{error: "stopped"})

      assert {:error, :not_open} =
               Tape.post(ctx, current, %{id: id, content: "late", payload: nil})

      assert {:error, :not_open} = Tape.report_workspace(ctx, current, "done", %{summary: "late"})
      assert records(ctx, "workspace_report") == []
    end

    test "a report from a turn of a daily thread is refused; a workspace thread reports once",
         %{ctx: ctx, daily: daily} do
      daily_turn = turn!(ctx, daily.id)

      assert {:error, :not_a_workspace} =
               Tape.report_workspace(ctx, daily_turn, "done", %{summary: "x"})

      workspace = open!(ctx, daily)
      turn = work!(ctx, workspace)

      assert {:ok, %{workspace_state: "done"}} =
               Tape.report_workspace(ctx, turn, "done", %{summary: "Done."})

      assert {:error, {:workspace_state, "done"}} =
               Tape.report_workspace(ctx, turn, "needs_you", %{summary: "again"})

      assert [%{snapshot: %{"outcome" => "done", "summary" => "Done."}}] =
               records(ctx, "workspace_report")
    end
  end

  describe "the state's moves" do
    test "a turn that ends failed with no report is the server's error, reported; a cancel nobody named moves nothing",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      {:ok, _} = Tape.finish(ctx, turn!(ctx, workspace.id), "cancelled", %{error: "stopped"})
      assert thread(ctx, workspace.id).workspace_state == "open"
      assert records(ctx, "workspace_report") == []

      {:ok, _} = Tape.finish(ctx, work!(ctx, workspace), "failed", %{error: "the build broke"})
      assert thread(ctx, workspace.id).workspace_state == "error"

      assert [%{snapshot: %{"outcome" => "error", "summary" => "the build broke"}}] =
               records(ctx, "workspace_report")
    end

    test "Aqua reports its work needs the person: once its turn ends the thread needs them, " <>
           "until the person writes there",
         %{ctx: ctx, daily: daily} do
      script!([
        call("r1", "workspace", %{
          "action" => "report",
          "outcome" => "needs_you",
          "summary" => "Which account should the report go to?"
        }),
        reply("Asked.")
      ])

      workspace = open!(ctx, daily)
      assert {:ok, %{"applied" => 1}} = drain(ctx)
      [%{turn_id: turn_id}] = Enum.filter(rows(ctx, workspace.id), &(&1.kind == "opening"))
      await_status(ctx, turn_id, "completed")
      assert thread(ctx, workspace.id).workspace_state == "needs_you"

      assert [%{snapshot: %{"outcome" => "needs_you", "turn_id" => ^turn_id} = snapshot}] =
               records(ctx, "workspace_report")

      assert snapshot["summary"] == "Which account should the report go to?"

      # Only new work clears it: the person's post.
      post!(ctx, workspace, "the work account")
      assert thread(ctx, workspace.id).workspace_state == "open"
    end

    test "workspace.report takes done or needs_you; failed is refused, and nothing is written",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      turn = work!(ctx, workspace)

      assert {:error,
              {:invalid_argument, "workspace.report takes an 'outcome' of done or needs_you"}} =
               Workspace.handle("workspace", Sanctum.Context.enter_guest(ctx), %{
                 "action" => "report",
                 "outcome" => "failed",
                 "summary" => "It broke.",
                 "thread_id" => workspace.id,
                 "root_execution_id" => "exe_root"
               })

      assert {:error, :illegal_transition} =
               Tape.report_workspace(ctx, turn, "failed", %{summary: "It broke."})

      assert records(ctx, "workspace_report") == []
      assert thread(ctx, workspace.id).workspace_state == "open"
    end

    test "a turn a page's call opened is no work of the thread: it keeps no thread at work, " <>
           "ends no thread in error or done, and reports nothing",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      first = work!(ctx, workspace)
      {:ok, _} = Tape.report_workspace(ctx, first, "done", %{summary: "Done."})
      stop!(ctx, first)
      assert thread(ctx, workspace.id).workspace_state == "done"
      reported = records(ctx, "workspace_report")

      # Accepted and running, then failed: the thread stays done.
      call = page_turn!(ctx, workspace)
      assert thread(ctx, workspace.id).workspace_state == "done"
      {:ok, _} = Tape.finish(ctx, call, "failed", %{error: "the brain could not be described"})
      assert thread(ctx, workspace.id).workspace_state == "done"
      assert records(ctx, "workspace_report") == reported

      # At work, a page's turn that ends uncertain leaves it at work.
      post!(ctx, workspace, "one more thing")
      work = turn!(ctx, workspace.id)
      assert thread(ctx, workspace.id).workspace_state == "open"
      {:ok, _} = Tape.finish(ctx, page_turn!(ctx, workspace), "uncertain", %{error: "lost"})
      assert thread(ctx, workspace.id).workspace_state == "open"
      assert records(ctx, "workspace_report") == reported

      # In error by Aqua's own turn, it stays in error when a page's turn
      # completes.
      {:ok, current} = Tape.turn(ctx, work.id)
      {:ok, _} = Tape.finish(ctx, current, "failed", %{error: "the build broke"})
      assert thread(ctx, workspace.id).workspace_state == "error"
      {:ok, _} = Tape.finish(ctx, page_turn!(ctx, workspace), "completed")
      assert thread(ctx, workspace.id).workspace_state == "error"
      assert length(records(ctx, "workspace_report")) == length(reported) + 1
    end

    test "a finished one, or one that needs the person, opens again when the person writes in it, or when an ask is sent there, and reports nothing",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      first = work!(ctx, workspace)
      {:ok, _} = Tape.report_workspace(ctx, first, "done", %{summary: "Done."})
      assert thread(ctx, workspace.id).workspace_state == "done"
      stop!(ctx, first)

      post!(ctx, workspace, "one more thing")
      assert thread(ctx, workspace.id).workspace_state == "open"

      {:ok, _} =
        Tape.report_workspace(ctx, turn!(ctx, workspace.id), "needs_you", %{summary: "Which?"})

      assert thread(ctx, workspace.id).workspace_state == "needs_you"

      assert {:ok, %{workspace: id, state: "open"}} =
               open(ctx, daily, %{
                 "title" => nil,
                 "workspace" => workspace.id,
                 "ask" => "try again"
               })

      assert id == workspace.id
      assert thread(ctx, workspace.id).workspace_state == "open"

      openings = for %{kind: "opening", content: ask} <- rows(ctx, workspace.id), do: ask
      assert openings == ["write the moon report", "try again"]

      assert length(records(ctx, "workspace_report")) == 2
      assert length(records(ctx, "workspace_open")) == 2
    end
  end

  describe "the report's delivery" do
    test "a report is delivered once after a crash before the wake, on the daily thread current then, and the daily turn reads it",
         %{ctx: ctx, daily: daily} do
      script!([
        call("r1", "workspace", %{
          "action" => "report",
          "outcome" => "done",
          "summary" => "The moon report is written."
        }),
        reply("Reported."),
        reply("Your moon report is ready.")
      ])

      workspace = open!(ctx, daily)
      assert {:ok, %{"applied" => 1}} = drain(ctx)
      [%{turn_id: turn_id}] = Enum.filter(rows(ctx, workspace.id), &(&1.kind == "opening"))
      await_status(ctx, turn_id, "completed")
      assert thread(ctx, workspace.id).workspace_state == "done"

      # Nothing woke the consumer; its tick delivers the report.
      [record] = records(ctx, "workspace_report")
      assert %{} = Crew.drain_all()
      assert {:ok, "applied"} = outcome(ctx, record)

      {:ok, today} = Aqua.Day.current(ctx)

      assert [
               %{sent_by: "aqua", content: "The moon report is written.", turn_id: daily_turn} =
                 report
             ] =
               Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))

      assert report.workspace_id == workspace.id
      assert %{"outcome" => "done", "from_turn" => ^turn_id} = Tape.payload(report)

      await_status(ctx, daily_turn, "completed")
      assert [read | _] = chats("agent:local.aqua") |> Enum.filter(&(sent(&1) =~ "Report from"))
      assert sent(read) =~ ~s(Report from the workspace thread \\"Moon report\\")
      assert sent(read) =~ "The moon report is written."

      # The daily turn read the workspace thread, and the daily thread the
      # workspace thread's turn read through its opening.
      assert read_threads(ctx, daily_turn) == Enum.sort([daily.id, workspace.id])

      assert %{} = Crew.drain_all()
      assert [_once] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
    end

    test "the threads a workspace thread's turn read reach the daily turn that reads its report",
         %{ctx: ctx, daily: daily} do
      script!([reply("Working."), reply("The moon is full tonight.")])
      workspace = open!(ctx, daily)
      turn = turn!(ctx, workspace.id)

      # What the reporting turn read: another thread's posts.
      read!(turn, ["thr_moon"])
      {:ok, turn} = Tape.turn(ctx, turn.id)
      {:ok, _} = Tape.report_workspace(ctx, turn, "done", %{summary: "Full moon tonight."})
      stop!(ctx, turn)

      assert %{} = Crew.drain_all()
      {:ok, today} = Aqua.Day.current(ctx)
      [%{turn_id: daily_turn}] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      await_status(ctx, daily_turn, "completed")

      # What the reporting turn read rides with the report, beside the
      # workspace thread it came from.
      assert read_threads(ctx, daily_turn) == Enum.sort(["thr_moon", workspace.id])
    end

    test "a report delivered after midnight lands on the new day's daily thread",
         %{ctx: ctx, daily: daily} do
      script!([reply("Working."), reply("Your report arrived.")])
      :ok = Aqua.Day.put_zone(ctx.user_id, @west)
      workspace = open!(ctx, daily)
      turn = turn!(ctx, workspace.id)
      {:ok, _} = Tape.report_workspace(ctx, turn, "done", %{summary: "Done."})
      stop!(ctx, turn)
      {:ok, before} = Aqua.Day.current(ctx)

      :ok = Aqua.Day.put_zone(ctx.user_id, @east)
      {:ok, after_midnight} = Aqua.Day.current(ctx)
      assert after_midnight.id != before.id

      [record] = records(ctx, "workspace_report")
      assert %{} = Crew.drain_all()
      assert {:ok, "applied"} = outcome(ctx, record)

      assert [%{kind: "report"}] =
               Enum.filter(rows(ctx, after_midnight.id), &(&1.kind == "report"))

      assert Enum.filter(rows(ctx, before.id), &(&1.kind == "report")) == []
    end

    test "an envelope's file and a report's file each read back from the row that holds it",
         %{ctx: ctx, daily: daily} do
      script!([reply("Working."), reply("Here it is.")])
      blob = %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "PNG-moon"}
      shot = Prima.UUID7.generate_id("msg")
      {:ok, [ref]} = Aqua.Attachments.store(ctx, daily.id, shot, [blob])

      {:ok, _} =
        Tape.accept(ctx, daily.id, %{
          message: %{
            id: shot,
            author: ctx.user_id,
            sent_by: "person",
            content: "this one",
            payload: %{"attachments" => [ref]}
          }
        })

      workspace =
        open!(ctx, daily, %{
          "attachments" => [%{"message_id" => shot, "stored_name" => ref["stored_name"]}]
        })

      [opening] = rows(ctx, workspace.id)
      [carried] = Aqua.Attachments.refs_of(opening)
      assert %{"filename" => "moon.png", "media_type" => "image/png"} = carried

      assert [%{"data" => data}] =
               Aqua.Attachments.load(ctx, workspace.id, [%{message_id: opening.id, ref: carried}])

      assert Base.decode64!(data) == "PNG-moon"

      # The workspace thread posts a picture and reports it.
      chart = Prima.UUID7.generate_id("msg")
      turn = turn!(ctx, workspace.id)
      png = %{"filename" => "chart.png", "media_type" => "image/png", "bytes" => "PNG-chart"}
      {:ok, [chart_ref]} = Aqua.Attachments.copy(ctx, workspace.id, chart, [png])

      {:ok, _} =
        Tape.post(ctx, turn, %{
          id: chart,
          content: "the chart",
          payload: %{"post" => true, "attachments" => [chart_ref]}
        })

      {:ok, _} =
        Tape.report_workspace(ctx, turn, "done", %{
          summary: "Charted.",
          attachments: [%{"message_id" => chart, "stored_name" => chart_ref["stored_name"]}]
        })

      stop!(ctx, turn)
      assert %{} = Crew.drain_all()
      {:ok, today} = Aqua.Day.current(ctx)
      [report] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      [copied] = Aqua.Attachments.refs_of(report)

      assert [%{"data" => data}] =
               Aqua.Attachments.load(ctx, today.id, [%{message_id: report.id, ref: copied}])

      assert Base.decode64!(data) == "PNG-chart"
    end

    # Every opening accepted reports once.
    test "two openings sent before either runs each report once, in order, and the thread is done after the second",
         %{ctx: ctx, daily: daily} do
      script!([
        call("r1", "workspace", %{
          "action" => "report",
          "outcome" => "done",
          "summary" => "First done"
        }),
        reply("Reported the first."),
        call("r2", "workspace", %{
          "action" => "report",
          "outcome" => "done",
          "summary" => "Second done"
        }),
        reply("Reported the second."),
        reply("The first is done."),
        reply("The second is done.")
      ])

      workspace = open!(ctx, daily)

      {:ok, _} =
        open(ctx, daily, %{"title" => nil, "workspace" => workspace.id, "ask" => "and a second"})

      assert {:ok, %{"applied" => 2}} = drain(ctx)

      for %{kind: "opening", turn_id: turn_id} <- rows(ctx, workspace.id),
          do: await_status(ctx, turn_id, "completed")

      assert [
               %{snapshot: %{"outcome" => "done", "summary" => "First done"}},
               %{snapshot: %{"outcome" => "done", "summary" => "Second done"}}
             ] = records(ctx, "workspace_report")

      assert thread(ctx, workspace.id).workspace_state == "done"

      # The person reads two reports on the daily thread, in order.
      assert %{} = Crew.drain_all()
      {:ok, today} = Aqua.Day.current(ctx)

      assert ["First done", "Second done"] =
               for(%{kind: "report", content: text} <- rows(ctx, today.id), do: text)
    end

    # A try that dies after its copy leaves the place it recorded first;
    # the next try discards there, behind any number of daily threads and
    # across midnight.
    test "a report tried again after midnight discards what a try that died copied, behind 200 more recently active daily threads",
         %{ctx: ctx, daily: daily} do
      :ok = Aqua.Day.put_zone(ctx.user_id, @west)
      record = charted!(ctx, daily)
      id = Crew.report_id(record)
      {:ok, earlier} = Aqua.Day.current(ctx)

      assert {:error, :crashed} = dying_try(fn -> drain(ctx) end)
      assert [_residue] = copies(ctx, earlier.id, id)

      now = DateTime.utc_now()

      rows =
        for _ <- 1..200 do
          %{
            id: Prima.UUID7.generate_id("thread"),
            athanor_id: ctx.athanor_id,
            kind: "daily",
            day: Arca.Test.Days.next(),
            title: "a day",
            created_by: ctx.user_id,
            inserted_at: now,
            updated_at: now,
            last_message_at: DateTime.add(now, 60)
          }
        end

      {200, _} = Arca.Repo.insert_all(Arca.Schemas.Thread, rows)

      :ok = Aqua.Day.put_zone(ctx.user_id, @east)
      {:ok, today} = Aqua.Day.current(ctx)
      assert today.id != earlier.id

      assert %{} = Crew.drain_all()
      assert {:ok, "applied"} = outcome(ctx, record)
      assert [%{id: ^id} = report] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      assert [_one] = Aqua.Attachments.refs_of(report)
      assert copies(ctx, earlier.id, id) == []
    end

    test "a report tried again discards what a try copied under a daily thread deleted while it copied",
         %{ctx: ctx, daily: daily} do
      record = charted!(ctx, daily)
      id = Crew.report_id(record)
      {:ok, earlier} = Aqua.Day.current(ctx)
      test = self()

      # The try has read its day and starts to copy; the person deletes
      # that day's thread; then the copy writes and the try dies.
      dying_try(fn ->
        try =
          Task.async(fn ->
            Process.put(:before_report_copy, fn ->
              send(test, :copying)
              assert_receive :go, 10_000
            end)

            drain(ctx)
          end)

        assert_receive :copying, 10_000
        assert {:ok, _} = Threads.delete(actor(ctx), earlier.id)
        send(try.pid, :go)
        assert {:error, :crashed} = Task.await(try, 15_000)
      end)

      assert [_residue] = copies(ctx, earlier.id, id)

      {:ok, today} = Aqua.Day.current(ctx)
      assert today.id != earlier.id

      assert %{} = Crew.drain_all()
      assert {:ok, "applied"} = outcome(ctx, record)
      assert [%{id: ^id}] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      assert copies(ctx, earlier.id, id) == []
    end

    test "a report tried again discards what the earlier try stored under its row",
         %{ctx: ctx, daily: daily} do
      script!([reply("Working."), reply("Here it is.")])
      workspace = open!(ctx, daily)
      turn = turn!(ctx, workspace.id)
      chart = Prima.UUID7.generate_id("msg")
      png = %{"filename" => "chart.png", "media_type" => "image/png", "bytes" => "PNG-chart"}
      {:ok, [ref]} = Aqua.Attachments.copy(ctx, workspace.id, chart, [png])

      {:ok, _} =
        Tape.post(ctx, turn, %{
          id: chart,
          content: "",
          payload: %{"post" => true, "attachments" => [ref]}
        })

      {:ok, _} =
        Tape.report_workspace(ctx, turn, "done", %{
          summary: "Charted.",
          attachments: [%{"message_id" => chart, "stored_name" => ref["stored_name"]}]
        })

      stop!(ctx, turn)

      # An earlier try that crashed after its copy and before its row.
      {:ok, today} = Aqua.Day.current(ctx)
      [record] = records(ctx, "workspace_report")
      id = Crew.report_id(record)
      {:ok, [_residue]} = Aqua.Attachments.copy(ctx, today.id, id, [png])

      assert %{} = Crew.drain_all()
      assert {:ok, "applied"} = outcome(ctx, record)
      [report] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      assert report.id == id
      assert [_one] = Aqua.Attachments.refs_of(report)
    end
  end

  describe "a copied file's provenance" do
    # A file copied into an opening or a report carries the read threads
    # of the post that held it.
    test "an opening's file carries the read threads of the daily post it was copied from, " <>
           "refs or none",
         %{ctx: ctx, daily: daily} do
      script!([reply("Working on it."), reply("More.")])

      # A daily turn that read another thread's posts posts a file.
      reader = turn!(ctx, daily.id, "draw the moon")
      read!(reader, ["thr_moon"])
      {:ok, reader} = Tape.turn(ctx, reader.id)
      post_id = Prima.UUID7.generate_id("msg")
      png = %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "PNG-moon"}
      {:ok, [ref]} = Aqua.Attachments.copy(ctx, daily.id, post_id, [png])

      {:ok, _} =
        Tape.post(ctx, reader, %{
          id: post_id,
          content: "the moon",
          payload: %{"post" => true, "attachments" => [ref]}
        })

      stop!(ctx, reader)

      # Opened with that file and without that post among its refs.
      workspace =
        open!(ctx, daily, %{
          "attachments" => [%{"message_id" => post_id, "stored_name" => ref["stored_name"]}]
        })

      [opening] = rows(ctx, workspace.id)
      assert [%{"read_threads" => ["thr_moon"]}] = Aqua.Attachments.refs_of(opening)

      assert {:ok, %{"applied" => 1}} = drain(ctx)
      %{turn_id: turn_id} = Enum.find(rows(ctx, workspace.id), &(&1.id == opening.id))
      await_status(ctx, turn_id, "completed")

      # The workspace thread's turn read the file's thread, and the daily
      # thread its opening refers to.
      assert read_threads(ctx, turn_id) == Enum.sort(["thr_moon", daily.id])
    end

    test "a report's file carries the read threads of the post that held it, not only the " <>
           "reporting turn's",
         %{ctx: ctx, daily: daily} do
      script!([reply("Here is the chart."), reply("More.")])
      workspace = open!(ctx, daily)

      # One turn of the workspace thread read another thread's posts and
      # posted a chart; another, which read none, reports it.
      poster = turn!(ctx, workspace.id, "chart it")
      read!(poster, ["thr_moon"])
      {:ok, poster} = Tape.turn(ctx, poster.id)
      chart = Prima.UUID7.generate_id("msg")
      png = %{"filename" => "chart.png", "media_type" => "image/png", "bytes" => "PNG-chart"}
      {:ok, [ref]} = Aqua.Attachments.copy(ctx, workspace.id, chart, [png])

      {:ok, _} =
        Tape.post(ctx, poster, %{
          id: chart,
          content: "",
          payload: %{"post" => true, "attachments" => [ref]}
        })

      stop!(ctx, poster)
      reporter = work!(ctx, workspace)

      {:ok, _} =
        Tape.report_workspace(ctx, reporter, "done", %{
          summary: "Charted.",
          attachments: [%{"message_id" => chart, "stored_name" => ref["stored_name"]}]
        })

      stop!(ctx, reporter)
      assert read_threads(ctx, reporter.id) == []

      assert %{} = Crew.drain_all()
      {:ok, today} = Aqua.Day.current(ctx)
      [report] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
      assert [%{"read_threads" => ["thr_moon"]}] = Aqua.Attachments.refs_of(report)
      await_status(ctx, report.turn_id, "completed")

      assert read_threads(ctx, report.turn_id) == Enum.sort(["thr_moon", workspace.id])
    end
  end

  describe "forgetting" do
    test "deleting a workspace thread removes its pointer and reports, voids its queued deliveries, and in a thread that read it deletes the later compactions, clears the session and stops the turn that read it",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      {:ok, _} = Tape.report_workspace(ctx, turn!(ctx, workspace.id), "done", %{summary: "Done."})

      # A report landed earlier on the daily thread, by its row.
      {:ok, _} =
        TurnStorage.accept_message(actor(ctx), daily.id, %{
          message: %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: "report",
            workspace_id: workspace.id,
            content: "Done.",
            payload: %{"workspace" => workspace.id, "title" => "Moon report", "outcome" => "done"}
          }
        })

      earlier = compaction!(ctx, daily, "before it read")
      reader = turn!(ctx, daily.id, "what did it say?")

      read!(reader, [workspace.id])

      later = compaction!(ctx, daily, "the report said done")

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^daily.id),
          set: [brain_session: "session-1"]
        )

      generation = thread(ctx, daily.id).brain_generation

      assert {:ok, %{cancelled: cancelled}} = Tape.delete_thread(ctx, workspace.id)
      assert reader.id in Enum.map(cancelled, & &1.turn_id)
      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, reader.id)

      kept = rows(ctx, daily.id)
      refute Enum.any?(kept, &(&1.kind in ["pointer", "report"]))
      assert Enum.any?(kept, &(&1.id == earlier.id))
      refute Enum.any?(kept, &(&1.id == later.id))

      assert %{brain_session: nil, brain_generation: raised} = thread(ctx, daily.id)
      assert raised == generation + 1

      # Its queued deliveries deliver nothing, each receipted once.
      [opening_record] = records(ctx, "workspace_open")
      [report_record] = records(ctx, "workspace_report")
      assert %{} = Crew.drain_all()
      assert {:ok, "refused"} = outcome(ctx, opening_record)
      assert {:ok, "refused"} = outcome(ctx, report_record)
      {:ok, today} = Aqua.Day.current(ctx)
      refute Enum.any?(rows(ctx, today.id), &(&1.kind == "report"))
    end

    test "a delivery from a deleted workspace thread lands nothing on the daily thread",
         %{ctx: ctx, daily: daily} do
      workspace = open!(ctx, daily)
      {:ok, _} = Tape.delete_thread(ctx, workspace.id)

      assert {:error, :workspace_gone} =
               TurnStorage.accept_message(actor(ctx), daily.id, %{
                 message: %{
                   author: Prima.Author.agent(),
                   sent_by: "aqua",
                   kind: "report",
                   workspace_id: workspace.id,
                   content: "Done."
                 }
               })

      refute Enum.any?(rows(ctx, daily.id), &(&1.kind == "report"))
    end

    test "the setting keeps a workspace thread at work and archives a finished one, every pointer kept, and the panel's list leaves it out",
         %{ctx: ctx, daily: daily} do
      working = open!(ctx, daily, %{"title" => "Working"})
      finished = open!(ctx, daily, %{"title" => "Finished"})
      {:ok, _} = Tape.report_workspace(ctx, work!(ctx, finished), "done", %{summary: "Done."})

      for turn <-
            Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.athanor_id == ^ctx.athanor_id)),
          turn.status in Prima.TurnState.open_statuses() do
        {:ok, _} = Tape.finish(ctx, turn, "cancelled", %{error: "stopped"})
      end

      # The daily thread stays by a turn still open there.
      _open = turn!(ctx, daily.id)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, 1} = Threads.count_idle(actor(ctx), future)
      assert {:ok, 1} = Threads.archive_idle(actor(ctx), future)

      archived = Threads.list(actor(ctx), kind: "workspace", archived: true)
      assert Enum.map(archived, & &1.id) == [finished.id]
      active = Threads.list(actor(ctx), kind: "workspace", archived: false)
      assert Enum.map(active, & &1.id) == [working.id]
      pointed = for %{kind: "pointer", workspace_id: id} <- rows(ctx, daily.id), do: id
      assert Enum.sort(pointed) == Enum.sort([working.id, finished.id])

      {:ok, listed} = Aqua.workspaces(ctx)
      refute finished.id in Enum.map(listed, & &1.id)
    end
  end

  describe "the records a view reads" do
    test "a workspace thread is listed while at work or waiting, and a finished one until its posts are seen",
         %{ctx: ctx, daily: daily} do
      working = open!(ctx, daily, %{"title" => "Working"})
      finished = open!(ctx, daily, %{"title" => "Finished"})
      turn = work!(ctx, finished)

      {:ok, _} =
        Tape.post(ctx, turn, %{
          id: Prima.UUID7.generate_id("msg"),
          content: "a result",
          payload: %{"post" => true}
        })

      {:ok, _} = Tape.report_workspace(ctx, turn, "done", %{summary: "Done."})

      {:ok, listed} = Aqua.workspaces(ctx)
      assert listed |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([working.id, finished.id])
      done = Enum.find(listed, &(&1.id == finished.id))
      assert %{state: "done", unread: 1, waits_on_you: false, title: "Finished"} = done

      [last | _] = Enum.reverse(rows(ctx, finished.id))
      :ok = Aqua.mark_read(ctx, finished.id, last.seq)

      {:ok, listed} = Aqua.workspaces(ctx)
      assert Enum.map(listed, & &1.id) == [working.id]

      assert {:ok, %{id: id, state: "done", opened_from: from}} = Aqua.workspace(ctx, finished.id)
      assert id == finished.id and is_binary(from)
      assert {:error, :not_found} = Aqua.workspace(ctx, daily.id)

      assert {:ok, %{count: 1, workspaces: [%{workspace: listed_id}]}} =
               Workspace.handle("workspace", ctx, %{"action" => "list"})

      assert listed_id == working.id
    end

    test "one that needs the person stays listed as waiting on them, read or not; one stopped " <>
           "or in error leaves once its posts are seen",
         %{ctx: ctx, daily: daily} do
      waiting = open!(ctx, daily, %{"title" => "Waiting"})
      stopped = open!(ctx, daily, %{"title" => "Stopped"})
      broken = open!(ctx, daily, %{"title" => "Broken"})

      result = fn workspace ->
        turn = work!(ctx, workspace)

        {:ok, _} =
          Tape.post(ctx, turn, %{
            id: Prima.UUID7.generate_id("msg"),
            content: "a result",
            payload: %{"post" => true}
          })

        turn
      end

      asks = result.(waiting)
      {:ok, _} = Tape.report_workspace(ctx, asks, "needs_you", %{summary: "Which account?"})
      stop!(ctx, asks)

      _stopping = result.(stopped)
      {:ok, %{cancelled: [_one]}} = Tape.stop_work(ctx, stopped.id)

      failing = result.(broken)
      {:ok, current} = Tape.turn(ctx, failing.id)
      {:ok, _} = Tape.finish(ctx, current, "failed", %{error: "the build broke"})

      {:ok, listed} = Aqua.workspaces(ctx)
      by_id = Map.new(listed, &{&1.id, &1})

      assert %{state: "needs_you", waits_on_you: true, unread: 1} = by_id[waiting.id]
      assert %{state: "stopped", waits_on_you: false, unread: 1} = by_id[stopped.id]
      assert %{state: "error", waits_on_you: false, unread: 1} = by_id[broken.id]

      for workspace <- [waiting, stopped, broken] do
        [last | _] = Enum.reverse(rows(ctx, workspace.id))
        :ok = Aqua.mark_read(ctx, workspace.id, last.seq)
      end

      {:ok, listed} = Aqua.workspaces(ctx)

      assert [%{id: id, state: "needs_you", waits_on_you: true, unread: 0}] = listed
      assert id == waiting.id
    end
  end

  defp compaction!(ctx, thread, summary) do
    {:ok, row} =
      Threads.append(actor(ctx), thread.id, %{
        author: Prima.Author.system(),
        sent_by: "aqua",
        kind: "compaction",
        content: summary,
        payload: %{"first_kept_seq" => 1, "summarized_through_seq" => 1}
      })

    row
  end
end
