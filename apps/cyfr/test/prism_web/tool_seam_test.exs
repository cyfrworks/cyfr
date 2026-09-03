# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ToolSeamTest do
  @moduledoc """
  `PrismWeb.MCPHelpers` is the console's seam onto the MCP tool surface —
  one place that splits `"tool/action"`, one `error_message/1` vocabulary.

  Eight console call sites reached past it and spelled
  `ToolRegistry.call_external/3` themselves, all for the same reason:
  `call_tool/3` wanted a socket, and work handed to `Aqua.TaskSupervisor`
  has a context and no socket. The seam takes a context now, so the reason
  is gone — and this test is what keeps the sites from coming back.
  """

  use ExUnit.Case, async: true

  @seam "apps/cyfr/lib/prism_web/mcp_helpers.ex"

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the console reaches the tool surface only through its seam" do
    offenders =
      [Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.reject(&String.ends_with?(&1, "mcp_helpers.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> Cyfr.Test.SourceTree.read()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          String.contains?(line, "ToolRegistry.call_external")
        end)
        |> Enum.map(fn {_line, n} -> "#{Path.relative_to(path, root())}:#{n}" end)
      end)

    assert offenders == [],
           """
           These console modules call the tool registry directly instead of
           `PrismWeb.MCPHelpers.call_tool/3`:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           `call_tool/3` takes a `%Sanctum.Context{}` as well as a socket, so
           work inside a supervised task has no reason to reach past #{@seam}.
           """
  end

  # State that exists only because a person is looking at a screen. Every
  # other change the console makes goes through a tool, because an agent can
  # make it too and one gate should answer for both.
  @console_owned [
    # Someone's own UI preferences. There is no `user.put_prefs` tool and
    # there should not be one.
    {"apps/cyfr/lib/prism_web/live/settings_live.ex", "Sanctum.Tenancy.Users.put_prefs"},
    # Dropping the in-flight marker after a manual tincture refresh. Cache
    # invalidation, not persistence.
    {"apps/cyfr/lib/prism_web/live/shell_live.ex", "Arca.Cache.delete_match"},
    # The one transcription of a sign-in outcome to a browser response —
    # it mints and retires the person's OWN session, before any console
    # exists for them. Door placement is pinned by Sanctum.DoorPlacementTest.
    {"apps/cyfr/lib/prism_web/sign_in_response.ex", "Sanctum.Session.create"},
    {"apps/cyfr/lib/prism_web/sign_in_response.ex", "Sanctum.Session.destroy"},
    # Signing out: the same act as above, from the browser's own form post.
    # A person retiring their OWN session, with no agent equivalent.
    {"apps/cyfr/lib/prism_web/controllers/session_controller.ex", "Sanctum.Session.destroy"},
    # Recording the registry push token the claim flow just obtained. Part of
    # minting the person's identity, before any athanor exists to run a tool
    # in; `Compendium.MCP.Shared.namespace_bearer/2` reads it afterwards.
    {"apps/cyfr/lib/prism_web/controllers/claim_namespace_controller.ex",
     "Compendium.Registry.CredentialStore.put_push_token"},
    # Chat IS on the wire now (`conversation.*`, external-plane and
    # OIDC-only, so no agent and no API key reaches it) — and the console
    # is a deliberate in-process client of the same domain functions
    # rather than a caller of its own tool: the LiveView already holds an
    # authenticated member context, and the registry gate exists for
    # surfaces that do not. Same functions, two doors —
    # `PrismWeb.MCPHelpers` states the rule.
    {"apps/cyfr/lib/prism_web/live/conversation_pane_live.ex", "Arca.ConversationStorage.create"},
    {"apps/cyfr/lib/prism_web/live/chat_live.ex", "Arca.ConversationStorage.delete"},
    # Following is the person's own sidebar and notify roster — the rows
    # the `conversation.follow`/`unfollow` verbs write for a headless
    # client, written directly for the same reason as create/delete above.
    {"apps/cyfr/lib/prism_web/live/chat_live.ex", "Arca.TopicSubscriptionStorage.follow"},
    {"apps/cyfr/lib/prism_web/live/chat_live.ex", "Arca.TopicSubscriptionStorage.unfollow"},
    # Withdrawing an approval the person was shown. The grant belongs to the
    # click that made it; the runner is told, not asked.
    {"apps/cyfr/lib/prism_web/live/conversation_pane_live.ex",
     "Aqua.ConversationRunner.revoke_grant"},
    # Attachments a person drags into their own chat, and the same call
    # undone when the message they belonged to is not sent. Storage-capped by
    # `Sanctum.Tenancy.Caps.check_storage/2` like every other tenant write.
    {"apps/cyfr/lib/prism_web/live/conversation_pane_live.ex", "Aqua.Attachments.store"},
    {"apps/cyfr/lib/prism_web/live/conversation_pane_live.ex", "Aqua.Attachments.discard"}
  ]

  # The namespaces whose state the console must not change behind the tool
  # surface. `Aqua` belongs here for the same reason as the rest — a
  # conversation's blobs are an athanor's state, and an agent writes them
  # through the same verbs.
  @watched_roots ~w(Arca Sanctum Compendium Opus Locus Emissary Aqua)

  # `scan` writes registry rows (Compendium.AutoIndexer walks the tree and
  # registers what it finds) — it slipped past the roster as a
  # read-sounding verb. Reads (list_*, get_*, catalogue peeks) stay
  # deliberately outside this seam: the gate exists for STATE CHANGES; a
  # read needs no consent walk and wrapping every one in MCPHelpers would
  # be indirection without a gate behind it.
  # `follow`/`unfollow` joined for the same reason as `scan`: they write
  # rows and read as innocuous verbs, so they slipped past the roster.
  # Exact names, not `follow\w*` — `followed`/`followers` are reads, and
  # reads stay outside this seam.
  @mutating_verb ~r/^(create\w*|update\w*|delete\w*|put_\w+|set_\w+|insert\w*|revoke\w*|rotate\w*|archive\w*|remove\w*|reindex\w*|scan\w*|save\w*|destroy\w*|add_\w+|store\w*|discard\w*|follow|unfollow)$/

  # Any `Module.function(` call, whatever the module is called locally.
  @any_call ~r/\b([A-Z]\w*(?:\.[A-Z]\w+)*)\.([a-z_]\w*[!?]?)\(/

  # `alias A.B.C`, `alias A.B.C, as: D`, `alias A.{B, C}` — the local name a
  # module goes by in this file. Without this the guard anchored on literal
  # roots, so one `alias Arca.ConversationStorage, as: Conversations` hid
  # every call through it, and the roster read as two entries when it was
  # really more.
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
      [Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root())
        source = Cyfr.Test.SourceTree.read(path)
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

  test "call_tool splits tool/action for both shapes" do
    ctx = Sanctum.TestContext.local()

    # An unknown tool is refused by the registry rather than raising, which
    # is enough to show the name/action split happened before dispatch.
    assert {:error, _} = PrismWeb.MCPHelpers.call_tool(ctx, "no-such-tool/list", %{})

    socket = %Phoenix.LiveView.Socket{assigns: %{context: ctx, __changed__: %{}}}
    assert {:error, _} = PrismWeb.MCPHelpers.call_tool(socket, "no-such-tool/list", %{})

    assert {:error, :no_context} =
             PrismWeb.MCPHelpers.call_tool(
               %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
               "component/list",
               %{}
             )
  end
end
