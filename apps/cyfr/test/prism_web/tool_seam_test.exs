# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ToolSeamTest do
  @moduledoc """
  `PrismWeb.Ops` is the console's seam onto the operation catalog — one
  place that splits `"tool/action"`, one `error_message/1` vocabulary.
  `call_tool/3` takes a context, so work handed to `Prism.TaskSupervisor`
  has no reason to reach past it; this test keeps every other console
  module from calling the gate's dispatching entries, `Sanctum.Gate`'s or
  `Sanctum.Dispatch`'s, directly. The compiled beams are the reader
  (`Prima.Test.Beams`), so a call through an alias or an import and a
  capture are seen and a name inside a string is not.
  """

  use ExUnit.Case, async: true

  # The refused call below is recorded, so the test owns a sandbox.
  setup do
    Cyfr.Test.Sandbox.setup!(%{async: true})
    :ok
  end

  @seam PrismWeb.Ops
  @gate [Sanctum.Gate, Sanctum.Dispatch]
  @dispatch [:call_external, :call_in_chain]

  defp root, do: Path.expand("../../../..", __DIR__)

  # The console's tree, and the page helpers it shares with the sign-in
  # controllers: they transcribe a console flow's outcome and stay under
  # its rules.
  @page_helpers ~w(minimal_page sign_in_response safe_redirect)

  defp console_files do
    Prima.Test.SourceTree.files!(Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")) ++
      for(helper <- @page_helpers, do: Path.join(root(), "apps/cyfr/lib/cyfr_web/#{helper}.ex"))
  end

  test "the console reaches the tool surface only through its seam" do
    beams = console_beams()
    assert beams != [], "no console beam was read"

    offenders =
      for {module, source, beam} <- beams,
          module != @seam,
          {callee, function, arity} <- dispatches(beam),
          do: "#{source}: #{inspect(module)} reaches #{inspect(callee)}.#{function}/#{arity}"

    assert offenders == [],
           """
           These console modules call the gate directly instead of
           `PrismWeb.Ops.call_tool/3`:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           `call_tool/3` takes a `%Sanctum.Context{}` as well as a socket, so
           work inside a supervised task has no reason to reach past #{inspect(@seam)}.
           """

    # The seam itself makes the reach, so the scan is reading dispatch and
    # not passing on an empty read.
    seam = Enum.find_value(beams, fn {module, _source, beam} -> module == @seam and beam end)
    assert seam, "#{inspect(@seam)} has no beam"
    assert {Sanctum.Gate, :call_external, 3} in dispatches(seam)
  end

  test "a planted gate call or dispatch bypass is reported, and a string is not" do
    compiled =
      Code.compile_string(~S'''
      defmodule PrismWeb.PlantedGateCall do
        alias Sanctum.Gate
        def plant(ctx, args), do: Gate.call_external("t", ctx, args)
      end

      defmodule PrismWeb.PlantedDispatchBypass do
        def plant, do: &Sanctum.Dispatch.call_external/4
      end

      defmodule PrismWeb.PlantedString do
        def plant, do: "Sanctum.Gate.call_external(\"t\", ctx, args)"
      end
      ''')

    for {module, _beam} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    reported = for {module, beam} <- compiled, into: %{}, do: {module, dispatches(beam)}

    assert reported == %{
             PrismWeb.PlantedGateCall => [{Sanctum.Gate, :call_external, 3}],
             PrismWeb.PlantedDispatchBypass => [{Sanctum.Dispatch, :call_external, 4}],
             PrismWeb.PlantedString => []
           }
  end

  # Every production beam compiled from a console file, as
  # `{module, source, path}`.
  defp console_beams do
    sources = MapSet.new(console_files(), &Path.relative_to(&1, root()))

    for path <-
          :cyfr
          |> Application.app_dir("ebin")
          |> Path.join("Elixir.*.beam")
          |> Path.wildcard(),
        source = beam_source(path),
        MapSet.member?(sources, source),
        do:
          {path
           |> Path.basename(".beam")
           |> String.replace_prefix("Elixir.", "")
           |> List.wrap()
           |> Module.safe_concat(), source, String.to_charlist(path)}
  end

  defp beam_source(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {_module, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> Path.relative_to(root())

      _ ->
        nil
    end
  end

  # The gate dispatch `beam` calls or captures.
  defp dispatches(beam) do
    for {module, function, arity} <- Prima.Test.Beams.reaches(beam),
        module in @gate,
        function in @dispatch,
        uniq: true,
        do: {module, function, arity}
  end

  # State that exists only because a person is looking at a screen. Every
  # other change the console makes goes through a tool, because an agent can
  # make it too and one gate should answer for both.
  @console_owned [
    # Someone's own UI preferences, which carry no authority: the one
    # write ARCHITECTURE.md §3 (Prism) lets the console make beside the
    # gate. There is no `user.put_prefs` tool and there should not be one.
    {"apps/cyfr/lib/prism_web/live/settings_live.ex", "Sanctum.Tenancy.Users.put_prefs"},
    # The handle the person chose and has not claimed yet, the same
    # preference write; the claim itself is a tool call.
    {"apps/cyfr/lib/prism_web/components/identity_card.ex", "Sanctum.Tenancy.Users.put_prefs"},
    # Dropping the in-flight marker after a manual tincture refresh. Cache
    # invalidation, not persistence.
    {"apps/cyfr/lib/prism_web/live/shell_live.ex", "Arca.Cache.delete_match"},
    # The one transcription of a sign-in outcome to a browser response —
    # it mints the person's OWN session, before any console exists for
    # them. Door placement is pinned by Sanctum.DoorPlacementTest.
    {"apps/cyfr/lib/cyfr_web/sign_in_response.ex", "Sanctum.Session.create"},
    # The browser's own sign-out: it retires the session its cookie names and
    # nothing else. It reads only that cookie and runs before any caller
    # context exists, so it cannot pass the gate as `session/logout` does.
    {"apps/cyfr/lib/prism_web/controllers/auth_controller.ex", "Sanctum.Session.destroy"}
  ]

  # The namespaces whose state the console must not change behind the tool
  # surface. `Aqua` belongs here for the same reason as the rest — a
  # thread's blobs are an athanor's state, and an agent writes them
  # through the same verbs.
  @watched_roots ~w(Arca Sanctum Compendium Locus Emissary Aqua)

  # `scan` writes registry rows (Compendium.AutoIndexer walks the tree and
  # registers what it finds) — it slipped past the roster as a
  # read-sounding verb. Reads (list_*, get_*, catalogue peeks) stay
  # deliberately outside this seam: the gate exists for STATE CHANGES; a
  # read needs no consent walk and wrapping every one in MCPHelpers would
  # be indirection without a gate behind it.
  # `follow`/`unfollow` joined for the same reason as `scan`: they write
  # rows and read as innocuous verbs, so they slipped past the roster.
  # Exact names, not `follow\w*` — `followed`/`follows?` are reads, and
  # reads stay outside this seam.
  @mutating_verb ~r/^(create\w*|update\w*|delete\w*|put_\w+|set_\w+|insert\w*|revoke\w*|rotate\w*|archive\w*|remove\w*|reindex\w*|scan\w*|save\w*|destroy\w*|add_\w+|store\w*|discard\w*|follow|unfollow)$/

  # Any `Module.function(` call, whatever the module is called locally.
  @any_call ~r/\b([A-Z]\w*(?:\.[A-Z]\w+)*)\.([a-z_]\w*[!?]?)\(/

  # Resolve plain, renamed, and braced aliases before matching
  # module dependencies.
  defp aliases(source) do
    simple =
      ~r/^\s*alias\s+([A-Z][\w.]*?)(?:,\s*as:\s*([A-Z]\w*))?\s*$/m
      |> Regex.scan(source)
      |> Map.new(fn
        [_, full, as] -> {as, full}
        [_, full] -> {full |> String.split(".") |> List.last(), full}
      end)

    grouped =
      ~r/^\s*alias\s+([A-Z][\w.]*)\.\{([^}]+)\}/m
      |> Regex.scan(source)
      |> Enum.flat_map(fn [_, prefix, names] ->
        names
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn name ->
          {name |> String.split(".") |> List.last(), prefix <> "." <> name}
        end)
      end)
      |> Map.new()

    Map.merge(simple, grouped)
  end

  defp expand(module, aliases) do
    [head | rest] = String.split(module, ".")

    case Map.fetch(aliases, head) do
      {:ok, full} -> Enum.join([full | rest], ".")
      :error -> module
    end
  end

  test "the console mutates other namespaces only where it owns the state" do
    allowed = MapSet.new(@console_owned)

    found =
      console_files()
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root())
        source = Prima.Test.SourceTree.read(path)
        aliases = aliases(source)

        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _n} -> String.match?(line, ~r/^\s*#/) end)
        |> Enum.flat_map(fn {line, n} ->
          @any_call
          |> Regex.scan(line)
          |> Enum.flat_map(fn [_, module, fun] ->
            full = expand(module, aliases)

            if String.match?(fun, @mutating_verb) and
                 hd(String.split(full, ".")) in @watched_roots do
              [{rel, full <> "." <> fun, n}]
            else
              []
            end
          end)
        end)
      end)

    offenders =
      for {rel, call, n} <- found,
          not MapSet.member?(allowed, {rel, call}),
          do: "#{rel}:#{n}: #{call}"

    assert offenders == [],
           """
           The console changes state in another namespace directly:

           #{Enum.map_join(Enum.sort(offenders), "\n", &"  #{&1}")}

           If an agent should be able to do this, it is a tool call —
           `call_tool/3`, so one gate answers for the page and the agent
           alike. If it exists only for the person at the keyboard, add it to
           `@console_owned` above with a line saying why there is no tool.
           """

    stale =
      for {rel, call} <- @console_owned,
          not Enum.any?(found, fn {f, c, _} -> f == rel and c == call end),
          do: "#{rel}: #{call}"

    assert stale == [],
           "`@console_owned` names calls that are gone: #{inspect(Enum.sort(stale))}"
  end

  # The chat's verbs go through the tool surface: the same `thread`
  # actions a headless client calls, from the page. A card is decided
  # through `approval.resolve`, the one door that carries a standing
  # answer's bounds, as the wire's `approval` tool does.
  @chat_verbs %{
    "apps/cyfr/lib/prism_web/live/thread_pane_live.ex" =>
      ~w(thread/create thread/attach thread/send thread/discard thread/stop approval/resolve
         thread/revoke_grant thread/restart_for_consent),
    "apps/cyfr/lib/prism_web/live/chat_live.ex" => ~w(thread/follow thread/unfollow thread/delete)
  }

  test "the chat's turn writes go through the thread tool" do
    for {rel, verbs} <- @chat_verbs, verb <- verbs do
      source = Prima.Test.SourceTree.read(Path.join(root(), rel))

      assert source =~ ~s(call_tool(#{if rel =~ "chat_live", do: "focus", else: ""}) or
               source =~ verb,
             "#{rel} does not call #{verb} through PrismWeb.Ops"

      assert source =~ "\"#{verb}\"",
             "#{rel} does not name #{verb}"
    end

    pane =
      Prima.Test.SourceTree.read(
        Path.join(root(), "apps/cyfr/lib/prism_web/live/thread_pane_live.ex")
      )

    refute pane =~ "RoomExcerpt.read",
           "the pane passes the room reference, never the excerpt text"

    refute pane =~ "ThreadRunner.send_message"
  end

  test "call_tool splits tool/action for both shapes" do
    ctx = Sanctum.TestContext.local()

    # An unknown tool is refused by the registry rather than raising, which
    # is enough to show the name/action split happened before dispatch.
    assert {:error, _} = PrismWeb.Ops.call_tool(ctx, "no-such-tool/list", %{})

    socket = %Phoenix.LiveView.Socket{assigns: %{context: ctx, __changed__: %{}}}
    assert {:error, _} = PrismWeb.Ops.call_tool(socket, "no-such-tool/list", %{})

    assert {:error, :no_context} =
             PrismWeb.Ops.call_tool(
               %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
               "component/list",
               %{}
             )
  end
end
