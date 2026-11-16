# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Browser do
  @moduledoc """
  The `browser` tool: Aqua's browser, a real Chrome that is the person's
  alone (`Opus.Browser`), and the person's browser setting
  (`Aqua.BrowserSetting`).

  ## Aqua's actions

  `open` (an http or https address), `read` (the page as text, each
  element Aqua can act on marked with its ref), `click` and `type` (an
  element by its ref), `key` (one named key), `page` (below),
  `screenshot` and `close`. They run in a
  turn's chain and nowhere else (`planes: [:in_chain]`), only for a
  person's own sign-in (`consent: :interactive`), and each follows the
  person's browser setting (`follows_setting`), not a policy line: with
  it on, every one runs without a card; with it off, every one is
  refused here before any Chrome starts, and Aqua says the browser is
  turned off. `read` and `screenshot` are reads, `close` a write, and the
  rest reach the outside.

  Each acts on the window of the thread its turn runs in, which
  `Opus.Browser` names from the lineage the gate stamped and from no
  argument, for a caller the session owner proves to be that running
  turn. What a page holds is outside material, named by its host.

  `page` shows a page in the window, from exactly one of: `html`, a page
  of one file Aqua wrote; `files`, a page of several files Aqua hands,
  each a `path` held to `Prima.PathSafety`, of a type the served types
  name by its extension (`Compendium.tincture_served_types/0`), and its
  `content`, text or base64 by its `encoding`, with the page's `name`
  and its `entry` (`index.html` unless named), an html file among them;
  or `tincture`, a tincture version of the person's, read as the endpoint
  reads it and admitted as `source` admits its path
  (`Compendium.tincture_files/3`), held to the put's bound before its
  files are read. Its files are laid out under the
  address a public tincture of that name has (`Prima.TinctureUrl.path/3`
  with the `local` publisher), the page of one file as `index.html` of
  the name `page`, and are put into the window (`Opus.Browser.put/3`).
  The entry is handed with the `<base>` and the SDK a tincture's entry is
  served with (`Compendium.tincture_head_tags/3`); a plain page's entry
  is first given a head (`Compendium.plain_entry/1`), and a tincture's is
  handed as it was written.

  `screenshot` keeps the image as a draft of the turn's attempt, under a
  message id of its own that has not been sent, in the turn's thread,
  with the sources of what it shows beside it
  (`Aqua.Attachments.draft/4`), and answers that id: that attempt's
  `thread.post` publishes it (its `screenshot`); one never posted stays
  unsent, its bytes kept until its thread is deleted.
  The turn is proved again before the image is stored, so a turn
  superseded meanwhile writes nothing.

  ## The person's watch

  `watch` shows the person one workspace thread's window, live, on the
  page that asked (C12), and takes their clicks and keys into it: the
  person on a page of their own and no one else (`planes: [:external]`,
  `consent: :interactive`, proved again by the session owner,
  `Opus.Browser.person/1`, and admitted on the console's path alone,
  `Opus.Browser.watch/4`, so a paired device's channel and the command
  line are refused and start nothing), for a workspace thread of their
  own (`Aqua.workspace/2`). It is refused with the turned-off sentence
  while the setting is off, and starts no browser then: off, no browser
  of the person's runs. The watch belongs to the calling process, the
  page's view, which the gate runs the handler on
  (`Opus.Browser.watch/4`): its images and its end come to it, it says
  when it drew an image and hands the person's input under that watch
  alone, and it ends with that process. A stream open when the setting
  goes off ends with the turned-off sentence.

  ## The setting

  `turn_on` and `turn_off` set the person's browser setting; `status`
  reads it, with whether Aqua's browser is added and running. The
  person calls them from the Aqua page; a turn calls them too, proved as
  the running turn itself. `turn_on` is never standing (`standing:
  false`): a turn's call asks with a card in its thread each time, so
  text Aqua read never widens its own reach. `turn_off` only takes reach
  away and holds at once.
  """

  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @read_chars 65_536
  @max_url 4_096
  @max_text 65_536
  @max_html 4_194_304
  # The name a page of one file is laid out under, and the entry a page of
  # several files opens at unless it names one.
  @page_name "page"
  @default_entry "index.html"
  @keys ~w(Enter Tab Escape Backspace Delete ArrowUp ArrowDown ArrowLeft ArrowRight Home End PageUp PageDown Space)
  # What each action hands the driver of its arguments.
  @driver_args %{
    "open" => ["url"],
    "read" => [],
    "click" => ["ref"],
    "type" => ["ref", "text"],
    "key" => ["key"],
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
              max: @max_html,
              description:
                "page: a page of one file to show in this thread's window, as html; give exactly one of html, files and tincture"
            ),
            Arg.new(
              "files",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("path", :string,
                      required: true,
                      description: "the file's path in the page, as css/site.css"
                    ),
                    Arg.new("content", :string,
                      required: true,
                      bulk: true,
                      description: "the file's content: its text, or its bytes in base64"
                    ),
                    Arg.new("encoding", :string,
                      enum: ["text", "base64"],
                      description:
                        "base64 when content is the file's bytes in base64; text otherwise"
                    )
                  ]}
               )},
              min: 1,
              max: Opus.Browser.put_bound().files,
              description:
                "page: a page of several files to show in this thread's window, each {path, content, encoding}, with name and entry"
            ),
            Arg.new("name", :string,
              description: "page with files: the page's name, the last segment of its address"
            ),
            Arg.new("entry", :string,
              description:
                "page with files: the path of the html file it opens at, index.html unless named"
            ),
            Arg.new("tincture", :string,
              description:
                "page: a tincture version of yours to show as it is served, as tincture:local.<name>:<version>"
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
          "watch",
          "Watch this thread's window",
          [
            Arg.new("thread", :string,
              required: true,
              max: 64,
              description: "watch: the workspace thread whose window the person watches"
            ),
            Arg.new("width", :integer,
              required: true,
              min: 16,
              max: 4096,
              description: "watch: the width, in pixels, the window's images are scaled to fit"
            ),
            Arg.new("height", :integer,
              required: true,
              min: 16,
              max: 4096,
              description: "watch: the height, in pixels, the window's images are scaled to fit"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive,
          sources: []
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
          "Let Aqua use the browser",
          [],
          [kind: :write, sources: [], standing: false] ++ setting
        ),
        Operation.new(
          "browser",
          "turn_off",
          "Stop Aqua using the browser",
          [],
          [kind: :write, sources: [], reduces_authority: true] ++ setting
        )
      ],
      description:
        "Aqua's browser, a real Chrome that is the person's alone, with a window for each thread. open, read, click, type, key, page, screenshot and close act in this thread's window while the person's browser setting is on; page shows a page there, of one html file, of several files, or a tincture version of yours as it is served; thread.post shows a screenshot by the message_id it answered; watch shows the person a workspace thread's window on their own page; status reads the setting, turn_on asks the person to let Aqua use the browser, turn_off stops Aqua using it.",
      title: "Browser"
    )
  end

  @doc """
  What Aqua and the person read for an action of the browser while the
  person's browser setting is off, whoever refuses it: this provider, or
  the turn's policy, which the setting decides for an action the agent's
  author named (`Aqua.Loop.Policy`).
  """
  @spec turned_off() :: String.t()
  def turned_off, do: "The browser is turned off."

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

  defp action("watch", ctx, %{"thread" => thread, "width" => width, "height" => height})
       when is_binary(thread) and is_integer(width) and is_integer(height) do
    with :ok <- Opus.Browser.person(ctx) |> watcher(),
         {:ok, true} <- Aqua.BrowserSetting.allowed?(ctx) |> unavailable() |> on(),
         {:ok, _work} <- workspace(ctx, thread),
         {:ok, _watch} <-
           Opus.Browser.watch(ctx, thread, %{width: width, height: height}, fn ->
             Aqua.BrowserSetting.allowed?(ctx) == {:ok, true}
           end)
           |> watcher() do
      {:ok, %{watching: thread}}
    end
  end

  defp action("page", ctx, args) do
    caller = Opus.Browser.caller(ctx, args)

    with {:ok, true} <- Aqua.BrowserSetting.allowed?(ctx) |> unavailable() |> on(),
         {:ok, _turn} <- Opus.Browser.turn(caller) |> refused(),
         {:ok, put} <- put(ctx, args),
         {:ok, answer} <-
           Opus.Browser.put(caller, put, fn ->
             Aqua.BrowserSetting.allowed?(ctx) == {:ok, true}
           end)
           |> refused() do
      {:ok, %{url: answer["url"], title: answer["title"]}}
    end
  end

  defp action(action, ctx, args) when is_map_key(@driver_args, action) do
    caller = Opus.Browser.caller(ctx, args)

    with {:ok, true} <- Aqua.BrowserSetting.allowed?(ctx) |> unavailable() |> on(),
         {:ok, _turn} <- Opus.Browser.turn(caller) |> refused(),
         {:ok, answer} <-
           Opus.Browser.act(caller, action, Map.take(args, @driver_args[action]), fn ->
             Aqua.BrowserSetting.allowed?(ctx) == {:ok, true}
           end)
           |> refused() do
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

  # The image is kept only while the turn still runs, as a draft of that
  # attempt (`Aqua.Attachments.draft/4`): one superseded since the driver
  # answered writes nothing. The draft keeps what the page it shows came
  # from: the turn's sources so far, which name the host of every page
  # it opened or read, and the screenshot's own, an outside source.
  defp answered(
         "screenshot",
         ctx,
         {:turn, _ctx, _lineage} = caller,
         args,
         %{"png" => png} = answer
       )
       when is_binary(png) do
    with {:bytes, {:ok, bytes}} <- {:bytes, Base.decode64(png)},
         {:ok, _turn} <- Opus.Browser.turn(caller) |> refused(),
         {:ok, turn} <- held(ctx, args) do
      file = %{"filename" => "screenshot.png", "media_type" => "image/png", "bytes" => bytes}
      sources = Prima.Source.decode(turn.sources) ++ answer_sources(nil, answer)

      case Aqua.Attachments.draft(ctx, turn, file, sources) do
        {:ok, message_id, ref} ->
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

  defp answered(action, _ctx, _caller, _args, answer) when action in ["open", "click"],
    do: {:ok, %{url: answer["url"], title: answer["title"]}}

  defp answered("close", _ctx, _caller, _args, answer),
    do: {:ok, %{closed: answer["closed"] == true}}

  defp answered(_action, _ctx, _caller, _args, _answer), do: {:ok, %{done: true}}

  # ---------------------------------------------------------------------------
  # A page's put

  # The put of exactly one of html, files and tincture; a page's name and
  # entry go with its files alone.
  defp put(ctx, args) do
    case {Enum.filter(~w(html files tincture), &(args[&1] != nil)), args["name"], args["entry"]} do
      {["files"], name, entry} ->
        plain(ctx, name, entry || @default_entry, args["files"])

      {["html"], nil, nil} ->
        plain(ctx, @page_name, @default_entry, [
          %{"path" => @default_entry, "content" => args["html"]}
        ])

      {["tincture"], nil, nil} ->
        tincture(ctx, args["tincture"])

      {[_given], _name, _entry} ->
        {:error, {:invalid_argument, "browser.page takes a name and an entry with files alone"}}

      _none_or_more ->
        {:error,
         {:invalid_argument, "browser.page takes exactly one of html, files and tincture"}}
    end
  end

  # A page Aqua wrote: its files held to the path rules and the served
  # types, its entry an html file among them, first given a head.
  defp plain(ctx, name, entry, files) do
    with :ok <- page_name(name),
         {:ok, files} <- plain_files(files),
         {:ok, %{type: "text/html"}} <- entry_file(files, entry),
         {:ok, root} <- root(ctx, name) do
      {:ok, handed(root, entry, files, &Compendium.plain_entry/1)}
    else
      {:ok, %{path: path}} ->
        {:error, {:invalid_argument, "The entry #{path} is not an html file."}}

      {:error, _refused} = refused ->
        refused
    end
  end

  # A tincture version as the endpoint reads it; its entry is handed as
  # it was written.
  defp tincture(ctx, reference) when is_binary(reference) do
    with {:ok, %{name: name, entry: entry, files: files}} <-
           Compendium.tincture_files(ctx, reference, Opus.Browser.put_bound()) |> over_bound(),
         {:ok, root} <- root(ctx, name) do
      {:ok, handed(root, entry, files, & &1)}
    end
  end

  defp tincture(_ctx, _reference),
    do: {:error, {:invalid_argument, "tincture names a tincture version"}}

  defp over_bound({:error, :over_bound}), do: {:error, refusal(:put_too_large)}
  defp over_bound(read), do: read

  # The entry given the `<base>` of its own directory and the SDK, as the
  # endpoint serves a tincture's entry.
  defp handed(root, entry, files, prepare) do
    base = root <> "/" <> entry_dir(entry)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    files =
      Enum.map(files, fn
        %{path: ^entry, bytes: bytes} = file ->
          %{file | bytes: Compendium.tincture_head_tags(prepare.(bytes), base, nonce)}

        file ->
          file
      end)

    %{root: root, entry: entry, files: files}
  end

  defp entry_dir(entry) do
    case Path.dirname(entry) do
      "." -> ""
      dir -> dir <> "/"
    end
  end

  # The page's address, a public tincture's of the name: the same names the
  # SDK reads from it there.
  defp root(ctx, name) do
    case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      {:ok, athanor} ->
        {:ok, Prima.TinctureUrl.path(Sanctum.Tenancy.Athanors.route_slug(athanor), "local", name)}

      {:error, _unanswered} ->
        {:error, {:unavailable, "The page's address"}}
    end
  end

  defp page_name(name) when is_binary(name) do
    case Prima.ComponentRef.validate_ref_parts("local", name) do
      :ok -> :ok
      {:error, sentence} -> {:error, {:invalid_argument, "name: #{sentence}"}}
    end
  end

  defp page_name(_name),
    do: {:error, {:invalid_argument, "browser.page with files takes the page's name"}}

  defp plain_files(files) when is_list(files) and files != [] do
    types = Compendium.tincture_served_types()

    files
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn file, {:ok, taken, paths} ->
      case plain_file(file, types) do
        {:ok, %{path: path} = file} ->
          if MapSet.member?(paths, path),
            do: {:halt, {:error, {:invalid_argument, "#{path} is given twice."}}},
            else: {:cont, {:ok, [file | taken], MapSet.put(paths, path)}}

        {:error, _refused} = refused ->
          {:halt, refused}
      end
    end)
    |> case do
      {:ok, taken, _paths} -> {:ok, Enum.reverse(taken)}
      {:error, _refused} = refused -> refused
    end
  end

  defp plain_files(_files),
    do: {:error, {:invalid_argument, "files is a list of {path, content, encoding}"}}

  defp plain_file(%{"path" => path, "content" => content} = file, types)
       when is_binary(path) and is_binary(content) do
    with :ok <- safe_path(path),
         {:ok, type} <- served(types, path),
         {:ok, bytes} <- content(path, content, Map.get(file, "encoding")) do
      {:ok, %{path: path, type: type, bytes: bytes}}
    end
  end

  defp plain_file(_file, _types),
    do: {:error, {:invalid_argument, "Each of files is {path, content, encoding}."}}

  defp safe_path(path) do
    case Prima.PathSafety.validate_relative_path(path) do
      :ok -> :ok
      {:error, {_refusal, sentence}} -> {:error, {:invalid_argument, "#{path}: #{sentence}"}}
    end
  end

  defp served(types, path) do
    case Map.fetch(types, path |> Path.extname() |> String.downcase()) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        {:error,
         {:invalid_argument,
          "#{path} is not a type a page serves; a served file is one of " <>
            (types |> Map.keys() |> Enum.sort() |> Enum.join(" "))}}
    end
  end

  defp content(_path, content, encoding) when encoding in [nil, "text"], do: {:ok, content}

  defp content(path, content, "base64") do
    case Base.decode64(content) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_argument, "The content of #{path} is not base64."}}
    end
  end

  defp content(path, _content, _encoding),
    do: {:error, {:invalid_argument, "The encoding of #{path} is text or base64."}}

  defp entry_file(files, entry) do
    case Enum.find(files, &(&1.path == entry)) do
      nil -> {:error, {:invalid_argument, "The entry is not among the files."}}
      file -> {:ok, file}
    end
  end

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

  defp workspace(ctx, thread) do
    case Aqua.workspace(ctx, thread) do
      {:ok, work} -> {:ok, work}
      {:error, :not_found} -> {:error, {:not_found, "thread", thread}}
      {:error, reason} -> refused({:error, reason})
    end
  end

  # A watch's refusals, in words the person reads at their screen.
  defp watcher(:ok), do: :ok
  defp watcher({:ok, _} = ok), do: ok

  defp watcher({:error, :not_owned}),
    do: {:error, conflict("Aqua's browser shows only on a page of yours in CYFR.")}

  defp watcher({:error, :too_many_watches}),
    do:
      {:error,
       conflict(
         "Aqua's browser is already showing #{Opus.Browser.max_windows()} threads' windows; close one of them first."
       )}

  defp watcher({:error, reason}), do: refused({:error, reason})

  # The turn as its fence holds it now, with the attempt the call came from.
  defp held(ctx, args) do
    case Aqua.Tape.held_turn(ctx, args) do
      {:ok, turn} -> {:ok, turn}
      {:error, :database_error} -> {:error, refusal(:unavailable)}
      {:error, _lost} -> {:error, refusal(:not_owned)}
    end
  end

  defp on({:ok, true}), do: {:ok, true}
  defp on({:ok, false}), do: {:error, conflict(turned_off())}
  defp on(other), do: other

  defp unavailable({:error, :unavailable}), do: {:error, {:unavailable, "The browser setting"}}
  defp unavailable(answer), do: answer

  # The browser's refusals, in words Aqua and the person read.
  defp refused({:ok, _} = ok), do: ok
  defp refused({:error, reason}), do: {:error, refusal(reason)}

  defp refusal(:not_owned), do: conflict("This turn no longer owns the work.")
  defp refusal(:turned_off), do: conflict(turned_off())

  defp refusal(:not_added),
    do:
      conflict(
        "The browser was not found. The person adds Aqua's browser from the Aqua page, once."
      )

  defp refusal(:not_browser), do: conflict("This program is not Aqua's browser.")

  defp refusal(:disabled),
    do: conflict("Aqua's browser is disabled on the Programs page; the person enables it there.")

  defp refusal(:unavailable), do: conflict("The browser's response is unavailable.")

  defp refusal(:too_many_windows),
    do:
      conflict(
        "Aqua's browser has its #{Opus.Browser.max_windows()} windows open, one for each thread that used it. " <>
          "Close this thread's window when done with it; the person can close Aqua's browser from what is running."
      )

  defp refusal({:ended, _reason}),
    do: conflict("The browser stopped before it answered. Ask again to start it.")

  defp refusal(:too_large), do: {:invalid_argument, "That page is too large to show."}

  defp refusal(:put_too_large) do
    %{files: files, bytes: bytes} = Opus.Browser.put_bound()

    {:invalid_argument,
     "That page is too large to show: the browser takes at most #{files} files and " <>
       "#{div(bytes, 1_048_576)} MiB in one page."}
  end

  defp refusal(:response_too_large),
    do:
      {:invalid_argument,
       "The browser's answer is larger than the #{div(Opus.Browser.max_response(), 1_048_576)} MiB CYFR takes; read a smaller page."}

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
