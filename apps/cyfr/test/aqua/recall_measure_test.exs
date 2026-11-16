# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RecallMeasure do
  @moduledoc false
  # The seeded athanor of `test/support/fixtures/recall_hints.json` and
  # the hints' queries, shared by the measure and the cost run.

  require Ecto.Query

  alias Arca.ThreadStorage, as: Threads

  @fixture Path.expand("../support/fixtures/recall_hints.json", __DIR__)

  def fixture, do: @fixture |> File.read!() |> Jason.decode!()

  # The fixture's threads and posts, each post written at noon of its
  # thread's day, a second apart in the fixture's order, so a search's
  # newest first is the fixture's days. Answers the message id of each
  # post's key and the thread id of each thread's key.
  def seed!(ctx, fixture, today) do
    actor = Sanctum.Context.actor(ctx)

    threads =
      Map.new(fixture["threads"], fn t ->
        {t["key"], thread!(ctx, actor, t, Date.add(today, t["day"]))}
      end)

    days = Map.new(fixture["threads"], &{&1["key"], &1["day"]})

    posts =
      fixture["posts"]
      |> Enum.with_index()
      |> Enum.sort_by(fn {p, i} -> {days[p["thread"]], i} end)
      |> Map.new(fn {post, i} ->
        thread = threads[post["thread"]]
        id = post!(ctx, actor, thread, post, threads)

        noon =
          DateTime.new!(Date.add(today, days[post["thread"]]), ~T[12:00:00.000000], "Etc/UTC")

        {1, _} =
          Arca.Repo.update_all(
            Ecto.Query.from(m in Arca.Schemas.Message, where: m.id == ^id),
            set: [inserted_at: DateTime.add(noon, i, :second)]
          )

        {post["key"], id}
      end)

    %{posts: posts, threads: Map.new(threads, fn {key, t} -> {key, t.id} end)}
  end

  defp thread!(_ctx, actor, %{"kind" => "daily"}, date) do
    {:ok, thread} = Threads.daily(actor, date)
    thread
  end

  defp thread!(ctx, _actor, %{"kind" => "workspace", "title" => title}, _date) do
    %Arca.Schemas.Thread{}
    |> Arca.Schemas.Thread.changeset(%{
      id: Prima.UUID7.generate_id("thread"),
      athanor_id: ctx.athanor_id,
      kind: "workspace",
      workspace_state: "done",
      title: title,
      created_by: ctx.user_id
    })
    |> Arca.Repo.insert!()
    |> Map.from_struct()
  end

  defp post!(ctx, actor, thread, post, threads) do
    {author, sent_by} =
      if post["by"] == "agent", do: {"aqua", "aqua"}, else: {ctx.user_id, "person"}

    # A pointer or a report on a daily thread names the workspace thread
    # of the same work, as `workspace.open` and a report leave them.
    workspace =
      if post["kind"] in ["pointer", "report"] do
        threads
        |> Map.values()
        |> Enum.find(&(&1.kind == "workspace" and nvda?(&1)))
        |> then(& &1.id)
      end

    {:ok, row} =
      Threads.append(actor, thread.id, %{
        author: author,
        sent_by: sent_by,
        kind: post["kind"],
        content: post["content"],
        workspace_id: workspace
      })

    row.id
  end

  # The fixture's one pointer and one report are the NVDA work's.
  defp nvda?(thread), do: thread.title == "NVDA technical analysis"

  @doc """
  A hint's queries: its own words of three letters or more that are not
  stopwords, each searched alone, in the order the hint says them.
  """
  def queries(hint, stopwords) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(hint))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in stopwords))
    |> Enum.uniq()
  end

  @doc """
  What the person's own search at the door answers for each of a hint's
  queries: whether its post, or any post of its thread, is among the
  twenty answered.
  """
  def try_hint(ctx, hint, stopwords, target, target_thread) do
    results =
      for q <- queries(hint, stopwords) do
        {:ok, %{results: found}} =
          Aqua.Providers.Thread.handle("thread", ctx, %{"action" => "search", "q" => q})

        {q, found}
      end

    %{
      queries: Enum.map(results, &elem(&1, 0)),
      post: Enum.any?(results, fn {_q, found} -> Enum.any?(found, &(&1.message == target)) end),
      thread:
        Enum.any?(results, fn {_q, found} -> Enum.any?(found, &(&1.thread == target_thread)) end)
    }
  end

  @doc "Every hint of the fixture tried against the seeded athanor, and the report's lines."
  def measure(ctx, fixture, seeded) do
    thread_of = Map.new(fixture["posts"], &{&1["key"], &1["thread"]})

    tried =
      for h <- fixture["hints"] do
        target = seeded.posts[h["finds"]]
        target_thread = seeded.threads[thread_of[h["finds"]]]
        Map.merge(h, try_hint(ctx, h["hint"], fixture["stopwords"], target, target_thread))
      end

    posts = Enum.count(tried, & &1.post)
    threads = Enum.count(tried, & &1.thread)

    lines =
      Enum.map(tried, fn t ->
        mark = if t.post, do: "post", else: if(t.thread, do: "thread", else: "miss")

        "  #{String.pad_trailing(mark, 6)} #{t["hint"]}  [#{Enum.join(t.queries, ", ")}] (#{t["rewording"]})"
      end)

    %{tried: tried, posts: posts, threads: threads, lines: lines}
  end
end

defmodule Aqua.RecallMeasureTest do
  @moduledoc """
  How far plain search finds a reworded hint: the twenty hints of
  `test/support/fixtures/recall_hints.json`, written before search was
  built, against the athanor that file seeds. The share found is
  reported, never gated: what this asserts is only that every hint was
  tried.
  """

  use ExUnit.Case, async: false

  alias Aqua.RecallMeasure

  setup do
    Cyfr.Test.Sandbox.setup!()
    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  test "the twenty reworded hints, each tried by its own words", %{ctx: ctx} do
    fixture = RecallMeasure.fixture()
    seeded = RecallMeasure.seed!(ctx, fixture, Date.utc_today())

    %{tried: tried, posts: posts, threads: threads, lines: lines} =
      RecallMeasure.measure(ctx, fixture, seeded)

    IO.puts(
      "\nrecall measure (#{Arca.Repo.__adapter__() |> inspect()}): " <>
        "#{posts}/20 posts found, #{threads}/20 in their thread\n" <> Enum.join(lines, "\n")
    )

    assert length(tried) == 20
  end
end

defmodule Aqua.RecallCostTest do
  @moduledoc """
  What one search costs on a seeded athanor of a year of daily threads:
  twenty posts a day for 365 days, the recall fixture's posts among them
  on their days. Reported, never gated, on each adapter: the time of one
  search, the rows it read and the memory of the process that read them,
  for a word on every day (the first page answers) and for a word on no
  day (every row is read). Run alone: `--only benchmark`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.RecallMeasure
  alias Arca.ThreadStorage, as: Threads

  @moduletag :benchmark
  @moduletag timeout: 1_800_000

  @days 365
  @per_day 20

  setup do
    Cyfr.Test.Sandbox.setup!()
    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  test "one search over a year of daily threads", %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    today = Date.utc_today()
    {seed_us, :ok} = :timer.tc(fn -> year!(ctx, actor, today) end)
    fixture = RecallMeasure.fixture()
    seeded = RecallMeasure.seed!(ctx, fixture, today)
    %{posts: posts, threads: threads, lines: lines} = RecallMeasure.measure(ctx, fixture, seeded)

    rows =
      Arca.Repo.aggregate(
        from(m in Arca.Schemas.Message, where: m.athanor_id == ^ctx.athanor_id),
        :count
      )

    bytes =
      Arca.Repo.one(
        from(m in Arca.Schemas.Message,
          where: m.athanor_id == ^ctx.athanor_id,
          select: sum(fragment("length(?)", m.content))
        )
      )

    report =
      for {label, q} <- [{"a word on every day", "weather"}, {"a word on no day", "zyzzyva"}] do
        {us, scanned, memory} = timed(actor, q)
        "  #{label} (#{q}): #{div(us, 1000)} ms, #{scanned} rows read, #{div(memory, 1024)} KiB"
      end

    IO.puts(
      "\nrecall cost (#{inspect(Arca.Repo.__adapter__())}): #{rows} posts, #{bytes} bytes of text, " <>
        "seeded in #{div(seed_us, 1_000_000)} s\n" <>
        Enum.join(report, "\n") <>
        "\n  the twenty hints among a year: #{posts}/20 posts found, #{threads}/20 in their thread\n" <>
        Enum.join(lines, "\n")
    )
  end

  # The median of five searches' time, with the rows the last read and the
  # memory of the process that ran it at its end.
  defp timed(actor, q) do
    runs =
      for _ <- 1..5 do
        Task.async(fn ->
          :erlang.garbage_collect()
          {us, {:ok, %{scanned: scanned}}} = :timer.tc(fn -> Threads.search(actor, q) end)
          {:memory, memory} = Process.info(self(), :memory)
          {us, scanned, memory}
        end)
        |> Task.await(:infinity)
      end

    {us, _, _} = runs |> Enum.sort() |> Enum.at(2)
    {_, scanned, memory} = List.last(runs)
    {us, scanned, memory}
  end

  @lines [
    "Good morning. Two meetings today, and the weather is mild with some rain after four.",
    "Lunch with the team is at noon; the weather looks fine for walking there.",
    "Moved the dentist to next week and answered the landlord about the boiler.",
    "Remind me to pay the electricity bill before Friday, and to water the plants.",
    "The weather turns cold tomorrow, so take the heavier coat and an umbrella."
  ]

  # A year of daily threads, each day's rows written at that day's time.
  defp year!(ctx, actor, today) do
    for d <- @days..1//-1 do
      date = Date.add(today, -d)
      {:ok, thread} = Threads.daily(actor, date)
      at = DateTime.new!(date, ~T[08:00:00.000000], "Etc/UTC")

      rows =
        for n <- 1..@per_day do
          agent? = rem(n, 2) == 0

          %{
            id: Prima.UUID7.generate_id("msg"),
            thread_id: thread.id,
            athanor_id: ctx.athanor_id,
            seq: n,
            author: if(agent?, do: "aqua", else: ctx.user_id),
            sent_by: if(agent?, do: "aqua", else: "person"),
            kind: "text",
            content: "Day #{d}, #{n}: " <> Enum.at(@lines, rem(n + d, length(@lines))),
            inserted_at: DateTime.add(at, n * 60, :second)
          }
        end

      {@per_day, _} = Arca.Repo.insert_all(Arca.Schemas.Message, rows)
    end

    :ok
  end
end
