# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Browser do
  @moduledoc """
  The `browser` tool: AQUA's browser, a real Chrome that is the person's
  alone (`Opus.Browser`), and the person's browser setting
  (`Aqua.BrowserSetting`).

  ## AQUA's actions

  `open` (an http or https address), `read` (the page as text, each
  element AQUA can act on marked with its ref), `click` and `type` (an
  element by its ref), `key` (one named key), `page` (the window shows a
  page AQUA wrote, as html), `screenshot` and `close`. They run in a
  turn's chain and nowhere else (`planes: [:in_chain]`), only for a
  person's own sign-in (`consent: :interactive`), and each follows the
  person's browser setting (`follows_setting`), not a policy line: with
  it on, every one runs without a card; with it off, every one is
  refused here before any Chrome starts, and AQUA says the browser is
  turned off. `read` and `screenshot` are reads, `close` a write, and the
  rest reach the outside.

  Each acts on the window of the thread its turn runs in, which
  `Opus.Browser` names from the lineage the gate stamped and from no
  argument, for a caller the session owner proves to be that running
  turn. What a page holds is outside material, named by its host.

  `screenshot` stores the image under a message id of its own that has
  not been sent, in the turn's thread, as a person's files wait under an
  unsent message (`Aqua.Attachments.store/4`), and answers that id: a
  post publishes it, or it expires unsent. The turn is proved again
  before the image is stored, so a turn superseded meanwhile writes
  nothing.

  ## The setting

  `turn_on` and `turn_off` set the person's browser setting; `status`
  reads it, with whether AQUA's browser is added and running. The
  person calls them from the AQUA page; a turn calls them too, proved as
  the running turn itself. `turn_on` is never standing (`standing:
  false`): a turn's call asks with a card in its thread each time, so
  text AQUA read never widens its own reach. `turn_off` only takes reach
  away and holds at once.
  """

  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @read_chars 65_536
  @max_url 4_096
  @max_text 65_536
  @max_html 4_194_304
  @keys ~w(Enter Tab Escape Backspace Delete ArrowUp ArrowDown ArrowLeft ArrowRight Home End PageUp PageDown Space)
  # What each action hands the driver of its arguments.
  @driver_args %{
    "open" => ["url"],
    "read" => [],
    "click" => ["ref"],
    "type" => ["ref", "text"],
    "key" => ["key"],
    "page" => ["html"],
    "screenshot" => [],
    "close" => []
  }

  @impl true
  def service, do: "aqua"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    ref =
      Arg.new("ref", :string,
        required: true,
        max: 32,
        description: "click, type: the element's ref, as read marks it"
      )

    family = [
      kind: :external,
      planes: [:in_chain],
      consent: :interactive,
      follows_setting: true,
      sources: {:answer, {__MODULE__, :answer_sources}}
    ]

    setting = [planes: [:external, :in_chain], consent: :interactive]

    Operation.tool(
      [
        Operation.new(
          "browser",
          "open",
          "Open an address",
          [
            Arg.new("url", :string,
              required: true,
              max: @max_url,
              description: "open: the http or https address to open in this thread's window"
            )
          ],
          family
        ),
        Operation.new(
          "browser",
          "read",
          "Read the page",
          [
            Arg.new("from", :integer,
              min: 0,
              description:
                "read: the character to read on from, the `next` an earlier answer gave (0 from the start)"
            )
          ],
          Keyword.merge(family, kind: :read, recovery: :replay_safe)
        ),
        Operation.new("browser", "click", "Click an element", [ref], family),
        Operation.new(
          "browser",
          "type",
          "Type into an element",
          [
            ref,
            Arg.new("text", :string,
              required: true,
              max: @max_text,
              description: "type: the text to type into the element"
            )
          ],
          Keyword.put(family, :sources, [])
        ),
        Operation.new(
          "browser",
          "key",
          "Press a key",
          [
            Arg.new("key", :string,
              required: true,
              enum: @keys,
              description: "key: the key to press"
            )
          ],
          Keyword.put(family, :sources, [])
        ),
        Operation.new(
          "browser",
          "page",
          "Show a page",
          [
            Arg.new("html", :string,
              required: true,
              max: @max_html,
              description: "page: the page to show in this thread's window, as html"
            )
          ],
          family
        ),
        Operation.new(
          "browser",
          "screenshot",
          "Take a screenshot",
          [],
          Keyword.merge(family, kind: :read)
        ),
        Operation.new(
          "browser",
          "close",
          "Close the window",
          [],
          Keyword.merge(family, kind: :write, sources: [])
        ),
        Operation.new(
          "browser",
          "status",
          "Browser setting",
          [],
          [kind: :read, sources: [], recovery: :replay_safe] ++ setting
        ),
        Operation.new(
          "browser",
          "turn_on",
          "Let AQUA use the browser",
          [],
          [kind: :write, sources: [], standing: false] ++ setting
        ),
        Operation.new(
          "browser",
          "turn_off",
          "Stop AQUA using the browser",
          [],
          [kind: :write, sources: [], reduces_authority: true] ++ setting
        )
      ],
      description:
        "AQUA's browser, a real Chrome that is the person's alone, with a window for each thread. open, read, click, type, key, page, screenshot and close act in this thread's window while the person's browser setting is on; status reads the setting, turn_on asks the person to let AQUA use the browser, turn_off stops AQUA using it.",
      title: "Browser"
    )
  end

  @doc """
  What an answer carries: outside material, named by the page's host,
  or by the browser for an answer that names no page.
  """
  @spec answer_sources(Prima.Actor.t() | nil, term()) :: [Prima.Source.t()]
  def answer_sources(_actor, %{url: url}) when is_binary(url),
    do: [Prima.Source.outside(URI.parse(url).host || "browser")]

  def answer_sources(_actor, _answer), do: [Prima.Source.outside("browser")]

  @impl true
  def handle("browser", %Context{} = ctx, %{"action" => action} = args),
    do: action(action, ctx, args)

  # ---------------------------------------------------------------------------

  defp action("status", ctx, args) do
    with {:ok, _who} <- person_or_turn(ctx, args),
         {:ok, on} <- Aqua.BrowserSetting.allowed?(ctx) |> unavailable() do
      added =
        case Opus.Browser.row(ctx.athanor_id) do
          {:ok, _row} -> "added"
          {:error, :not_added} -> "not_added"
          {:error, :disabled} -> "disabled"
          {:error, _other} -> "not_browser"
        end

      {:ok,
       %{on: on, browser: added, running: Opus.Browser.running?(ctx.athanor_id, ctx.user_id)}}
    end
  end

  defp action(action, ctx, args) when action in ["turn_on", "turn_off"] do
    on = action == "turn_on"

    with {:ok, _who} <- person_or_turn(ctx, args),
         {:ok, on} <- Aqua.BrowserSetting.put(ctx, on) |> unavailable() do
      {:ok, %{on: on}}
    end
  end

  defp action(action, ctx, args) when is_map_key(@driver_args, action) do
    caller = Opus.Browser.caller(ctx, args)

    with {:ok, true} <- Aqua.BrowserSetting.allowed?(ctx) |> unavailable() |> on(),
         {:ok, _turn} <- Opus.Browser.turn(caller) |> refused(),
         {:ok, answer} <-
           Opus.Browser.act(caller, action, Map.take(args, @driver_args[action])) |> refused() do
      answered(action, ctx, caller, args, answer)
    end
  end

  defp action(action, _ctx, _args),
    do: {:error, {:invalid_argument, "browser.#{action}: the arguments are incomplete"}}

  defp answered("read", _ctx, _caller, args, answer) do
    text = Map.get(answer, "text", "")
    total = String.length(text)
    from = min(Map.get(args, "from") || 0, total)
    shown = String.slice(text, from, @read_chars)

    {:ok,
     %{
       url: answer["url"],
       title: answer["title"],
       text: shown,
       from: from,
       next: from + String.length(shown),
       total: total
     }}
  end

  # The image is stored only while the turn still runs: one superseded
  # since the driver answered writes nothing.
  defp answered(
         "screenshot",
         ctx,
         {:turn, _ctx, lineage} = caller,
         _args,
         %{"png" => png} = answer
       )
       when is_binary(png) do
    with {:bytes, {:ok, bytes}} <- {:bytes, Base.decode64(png)},
         {:ok, _turn} <- Opus.Browser.turn(caller) |> refused() do
      message_id = Prima.UUID7.generate_id("msg")
      file = %{"filename" => "screenshot.png", "media_type" => "image/png", "bytes" => bytes}

      case Aqua.Attachments.store(ctx, lineage["thread_id"], message_id, [file]) do
        {:ok, [ref]} ->
          {:ok,
           %{
             message_id: message_id,
             attachment: ref,
             width: answer["width"],
             height: answer["height"]
           }}

        {:error, reason} ->
          {:error,
           conflict("The screenshot could not be kept: #{Sanctum.Refusals.render(reason)}")}
      end
    else
      {:bytes, :error} -> {:error, refusal(:unavailable)}
      {:error, _refused} = refused -> refused
    end
  end

  defp answered(action, _ctx, _caller, _args, answer) when action in ["open", "click", "page"],
    do: {:ok, %{url: answer["url"], title: answer["title"]}}

  defp answered("close", _ctx, _caller, _args, answer),
    do: {:ok, %{closed: answer["closed"] == true}}

  defp answered(_action, _ctx, _caller, _args, _answer), do: {:ok, %{done: true}}

  # A person at a screen, or a running turn of theirs that made the call
  # itself: a component a turn started, a key and a frame reach nothing.
  defp person_or_turn(%Context{plane: :guest} = ctx, args),
    do: Opus.Browser.turn(Opus.Browser.caller(ctx, args)) |> refused()

  defp person_or_turn(ctx, _args) do
    case Opus.Browser.person(ctx) do
      :ok -> {:ok, :person}
      {:error, reason} -> refused({:error, reason})
    end
  end

  defp on({:ok, true}), do: {:ok, true}
  defp on({:ok, false}), do: {:error, conflict("The browser is turned off.")}
  defp on(other), do: other

  defp unavailable({:error, :unavailable}), do: {:error, {:unavailable, "The browser setting"}}
  defp unavailable(answer), do: answer

  # The browser's refusals, in words AQUA and the person read.
  defp refused({:ok, _} = ok), do: ok
  defp refused({:error, reason}), do: {:error, refusal(reason)}

  defp refusal(:not_owned), do: conflict("This turn no longer owns the work.")
  defp refusal(:turned_off), do: conflict("The browser is turned off.")

  defp refusal(:not_added),
    do:
      conflict(
        "The browser was not found. The person adds AQUA's browser from the AQUA page, once."
      )

  defp refusal(:not_browser), do: conflict("This program is not AQUA's browser.")

  defp refusal(:disabled),
    do: conflict("AQUA's browser is disabled on the Programs page; the person enables it there.")

  defp refusal(:unavailable), do: conflict("The browser's response is unavailable.")

  defp refusal(:too_many_windows),
    do:
      conflict(
        "AQUA's browser has its #{Opus.Browser.max_windows()} windows open, one for each thread that used it. " <>
          "Close this thread's window when done with it; the person can close AQUA's browser from what is running."
      )

  defp refusal({:ended, _reason}),
    do: conflict("The browser stopped before it answered. Ask again to start it.")

  defp refusal(:too_large), do: {:invalid_argument, "That page is too large to show."}

  defp refusal({:driver, code, sentence})
       when code in ~w(bad_url bad_ref bad_key no_window too_large bad_request),
       do: {:invalid_argument, sentence}

  defp refusal({:driver, _code, sentence}), do: conflict(sentence)

  defp refusal(reason) do
    if Sanctum.Refusals.known?(reason),
      do: reason,
      else: conflict("The browser could not start: #{Sanctum.Refusals.render(reason)}")
  end

  defp conflict(sentence), do: {:conflict, sentence}
end
