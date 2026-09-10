# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.WireTest do
  use ExUnit.Case, async: true

  # New-model allowlist: keys are `tool.action` (or `tool.*` globs), values are
  # "ask" (request approval) or "auto" (call directly). An absent key means the
  # agent can't perform the action at all. `files.delete` is intentionally
  # absent here so tests can exercise the not-allowlisted path.
  # Actions a running chain can reach: an approved proposal is executed
  # in-chain, so those are the only ones worth asking about.
  @policy %{
    "component.pull" => "ask",
    "component.register" => "ask",
    "execution.run" => "ask",
    "execution.cancel" => "ask",
    "registry.report" => "ask",
    "component.*" => "ask",
    "files.read" => "auto",
    "files.write" => "auto"
  }

  describe "strip_blocks/1" do
    test "removes a complete block" do
      input = "before\n\n```aqua-actions\n[]\n```\n\nafter"
      assert Aqua.Wire.strip_blocks(input) == "before\n\n\n\nafter"
    end

    test "removes an open-tail block (mid-stream)" do
      input = "before\n```aqua-actions\n[{\"kind\":\"ui.navigate"
      assert Aqua.Wire.strip_blocks(input) == "before\n"
    end

    test "passes content with no block through unchanged" do
      input = "no actions here\nplain text"
      assert Aqua.Wire.strip_blocks(input) == input
    end

    test "removes multiple blocks in one pass" do
      input = "a\n```aqua-actions\n[]\n```\nb\n```aqua-actions\n[]\n```\nc"
      assert Aqua.Wire.strip_blocks(input) == "a\n\nb\n\nc"
    end
  end

  describe "parse/2" do
    test "ui.navigate: allowed path produces navigate intent" do
      input =
        "go now\n\n```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/activities\"}]\n```\n"

      result = Aqua.Wire.parse(input, @policy)

      assert result.stripped == "go now"
      assert result.intents == [%{kind: "navigate", to: "/activities"}]
      assert result.drops == []
    end

    test "ui.navigate: a global page is allowed as it is" do
      # The chat has no estate in its address; it is in the allowlist by
      # its own path and is pushed without the focus prefix.
      input = "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/chat\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)

      assert result.intents == [%{kind: "navigate", to: "/chat"}]
      assert result.drops == []
    end

    test "ui.navigate: a path that is not a page path is dropped, block still stripped" do
      for path <- ["http://evil.example/", "//evil.example/x", "/a/../b", "activities", "/x y"] do
        entry = Jason.encode!(%{"kind" => "ui.navigate", "path" => path})
        result = Aqua.Wire.parse("```aqua-actions\n[#{entry}]\n```", @policy)

        assert result.stripped == ""
        assert result.intents == [], "#{path} became an intent"
        assert [%{reason: reason}] = result.drops
        assert reason =~ "not a page path"
      end
    end

    test "ui.navigate: whether the console serves a page is the web adapter's decision" do
      # A well-formed path the console has no page for is an intent here;
      # `PrismWeb.Nav.page?/1` is what drops it before it is pushed.
      input = "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/etc/passwd\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)

      assert result.intents == [%{kind: "navigate", to: "/etc/passwd"}]
      assert result.drops == []
    end

    test "ui.navigate: query-string variants of allowed routes pass" do
      input =
        "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/executions?id=exec_a\"}]\n```"

      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_a"}]
    end

    test "ui.execution.focus collapses to navigate with prefix-validated id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"exec_abc\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_abc"}]
    end

    test "ui.execution.focus rejects non-prefixed id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"req_abc\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must start with exec_"
    end

    test "ui.execution.focus rejects path-injection attempts" do
      input = ~S(```aqua-actions
[{"kind":"ui.execution.focus","id":"exec_../etc/passwd"}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "disallowed characters"
    end

    test "ui.component.focus accepts ref, builds /components/:ref" do
      input =
        "```aqua-actions\n[{\"kind\":\"ui.component.focus\",\"ref\":\"local.weather-app\"}]\n```"

      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/components/local.weather-app"}]
    end

    test "ui.tincture.focus url-encodes publisher and name" do
      input = ~S(```aqua-actions
[{"kind":"ui.tincture.focus","publisher":"acme.co","name":"my-app"}]
```)
      result = Aqua.Wire.parse(input, @policy)

      assert [%{kind: "navigate", to: to}] = result.intents
      assert to =~ "publisher=acme.co"
      assert to =~ "tincture_name=my-app"
    end

    test "ui.overlay.open without state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == [%{kind: "overlay_open"}]
    end

    test "ui.overlay.open with valid state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"full\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == [%{kind: "overlay_open", state: "full"}]
    end

    test "ui.overlay.open rejects peek (post-removal)" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"peek\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must be \"half\" or \"full\""
    end

    test "ui.overlay.close" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.close\"}]\n```"
      assert Aqua.Wire.parse(input, @policy).intents == [%{kind: "overlay_close"}]
    end

    test "ui.copy_clipboard captures text" do
      input = "```aqua-actions\n[{\"kind\":\"ui.copy_clipboard\",\"text\":\"hello\"}]\n```"

      assert Aqua.Wire.parse(input, @policy).intents == [
               %{kind: "copy_clipboard", text: "hello"}
             ]
    end

    test "unknown kind is dropped" do
      input = "```aqua-actions\n[{\"kind\":\"ui.lol.do_evil\"}]\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: "unknown kind: " <> _}] = result.drops
    end

    test "malformed JSON drops the entry but still strips the block" do
      input = "before\n```aqua-actions\nthis is not JSON\n```\nafter"
      result = Aqua.Wire.parse(input, @policy)
      assert result.stripped == "before\n\nafter"
      assert result.intents == []
      assert [%{reason: "JSON parse error: " <> _}] = result.drops
    end

    test "non-array JSON body is dropped" do
      input = "```aqua-actions\n{\"kind\":\"ui.navigate\",\"path\":\"/\"}\n```"
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: "block body is not a JSON array"}] = result.drops
    end

    test "multiple intents in one block execute in order" do
      input = ~S(before
```aqua-actions
[
  {"kind":"ui.navigate","path":"/executions"},
  {"kind":"ui.copy_clipboard","text":"abc"}
]
```)
      result = Aqua.Wire.parse(input, @policy)

      assert result.intents == [
               %{kind: "navigate", to: "/executions"},
               %{kind: "copy_clipboard", text: "abc"}
             ]
    end
  end

  describe "ui.request_approval" do
    test "pure-confirmation card with no proposal accepted" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Sure?","summary":"large refactor","risk":"medium","action_description":"begin work"}]
```)
      result = Aqua.Wire.parse(input, @policy)

      assert [intent] = result.intents
      assert intent.kind == "request_approval"
      assert intent.proposal == nil
      # No proposal → action_kind is nil; risk visualization defaults.
      assert intent.action_kind == nil
      assert intent.hinted_risk == "medium"
      assert is_binary(intent.id)
    end

    test "rejects unknown risk on confirmation card" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"extreme","action_description":"z"}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "low|medium|high"
    end

    test "proposal for an 'ask' action is accepted; agent's hinted_risk preserved" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Cancel run","summary":"the stuck one","risk":"low","action_description":"execution.cancel","proposal":{"tool":"execution","action":"cancel","args":{"id":"exec_1"}}}]
```)
      result = Aqua.Wire.parse(input, @policy)

      assert [intent] = result.intents
      assert intent.proposal == %{tool: "execution", action: "cancel", args: %{"id" => "exec_1"}}
      # action_kind comes from the tool registry's annotations when it's
      # populated. In test isolation it may be nil; production paths render
      # via the conversation runner which always has the registry loaded.
      assert intent.action_kind in [nil, :write]
      assert intent.hinted_risk == "low"
    end

    test "a proposal's standing rule rides on the intent, spelled for the row" do
      policy = %{"notes.pin" => "ask", "notes.keep" => "ask", "component.pull" => "ask"}

      card = fn tool, action ->
        input = ~s(```aqua-actions
[{"kind":"ui.request_approval","title":"t","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"#{tool}","action":"#{action}","args":{}}}]
```)
        assert [intent] = Aqua.Wire.parse(input, policy).intents
        intent
      end

      # The same declaration `Aqua.ToolGrants` reads at the write, here as
      # it survives JSON: a string, `false`, or nothing.
      assert card.("notes", "pin").standing == false
      assert card.("notes", "keep").standing == "conversation"
      assert card.("component", "pull").standing == nil
    end

    test "proposal matched by a `tool.*` glob in the allowlist is accepted" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Pull","summary":"fetch it","risk":"medium","action_description":"component.pull","proposal":{"tool":"component","action":"pull","args":{"ref":"catalyst:local.x:1.0.0"}}}]
```)
      result = Aqua.Wire.parse(input, @policy)

      assert [intent] = result.intents

      assert intent.proposal == %{
               tool: "component",
               action: "pull",
               args: %{"ref" => "catalyst:local.x:1.0.0"}
             }
    end

    test "a proposal the chain could not run is refused where the agent can act on it" do
      # `component.push` is external-only: the harness executes an approved
      # proposal in-chain, so a card for it would fail on the click.
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Push","summary":"ship it","risk":"medium","action_description":"component.push","proposal":{"tool":"component","action":"push","args":{}}}]
```)
      result = Aqua.Wire.parse(input, %{"component.*" => "ask"})

      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "cannot be run from a chat"
    end

    test "an execution.run of a wrapped catalyst is canonicalised before the card exists" do
      # A delete spelled as execution.run earns a files.delete card —
      # destructive kind, the virtual tool's own args — never an
      # execute-kind card for `execution.run`.
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Clean","summary":"rm","risk":"low","action_description":"d","proposal":{"tool":"execution","action":"run","args":{"reference":"catalyst:local.files:0.5.1","input":{"action":"delete","path":"data/storage/k.json"}}}}]
```)
      policy = %{"execution.run" => "ask", "storage.delete" => "ask"}
      assert [intent] = Aqua.Wire.parse(input, policy).intents
      assert intent.proposal == %{tool: "storage", action: "delete", args: %{"key" => "k"}}
      assert intent.action_kind == :destructive

      # With the canonical pair absent from the policy the card is refused,
      # however `execution.run` is held.
      result = Aqua.Wire.parse(input, %{"execution.run" => "ask"})
      assert result.intents == []
      assert [%{tag: :not_in_allowlist}] = result.drops
    end

    test "the assistant itself is never a proposal, and an unknown catalyst operation is refused" do
      card = fn reference, catalyst_input ->
        ~s(```aqua-actions
[{"kind":"ui.request_approval","title":"t","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"execution","action":"run","args":{"reference":"#{reference}","input":#{Jason.encode!(catalyst_input)}}}}]
```)
      end

      policy = %{"execution.run" => "ask", "files.*" => "ask"}

      result = Aqua.Wire.parse(card.("formula:local.aqua", %{"tool_policy" => %{}}), policy)
      assert [%{tag: :not_in_allowlist, reason: reason}] = result.drops
      assert reason =~ "clone a role"

      result = Aqua.Wire.parse(card.("catalyst:local.files", %{"action" => "bogus"}), policy)
      assert [%{tag: :not_in_allowlist, reason: reason}] = result.drops
      assert reason =~ "names no operation"

      # Any other reference is the app launch the policy holds at ask.
      assert [intent] =
               Aqua.Wire.parse(card.("formula:local.other", %{"x" => 1}), policy).intents

      assert intent.proposal.tool == "execution"
    end

    test "a request two virtual actions build identically is canonical only when the policy agrees" do
      card = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"t","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"execution","action":"run","args":{"reference":"catalyst:local.files","input":{"action":"tree","path":"src"}}}}]
```)
      agreed = %{"files.tree" => "ask", "files.list" => "ask"}

      assert [%{proposal: %{tool: "files", action: "tree"}}] =
               Aqua.Wire.parse(card, agreed).intents

      split = %{"files.tree" => "ask", "files.list" => "auto"}
      assert [%{reason: reason}] = Aqua.Wire.parse(card, split).drops
      assert reason =~ "answers differently"
    end

    test "a files proposal inside the storage boundary is the storage operation" do
      card = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"t","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"files","action":"delete","args":{"path":"data/storage/k.json"}}}]
```)

      assert [%{proposal: %{tool: "storage", action: "delete", args: %{"key" => "k"}}}] =
               Aqua.Wire.parse(card, %{"files.delete" => "ask", "storage.delete" => "ask"}).intents

      # And files.delete alone does not cover it: the storage pair decides.
      assert [%{tag: :not_in_allowlist}] =
               Aqua.Wire.parse(card, %{"files.delete" => "ask"}).drops
    end

    test "a denied pair and a UI event are never proposable" do
      card = fn tool, action ->
        ~s(```aqua-actions
[{"kind":"ui.request_approval","title":"t","summary":"s","risk":"low","action_description":"d","proposal":{"tool":"#{tool}","action":"#{action}","args":{}}}]
```)
      end

      result =
        Aqua.Wire.parse(card.("component", "pull"), %{
          "component.*" => "ask",
          "component.pull" => "deny"
        })

      assert [%{tag: :not_in_allowlist, reason: reason}] = result.drops
      assert reason =~ "declined"

      result = Aqua.Wire.parse(card.("request_setup", "open"), %{"request_setup.open" => "ask"})
      assert [%{tag: :auto_allowlisted}] = result.drops

      # And the prelude never lists it as something to ask for.
      refute Aqua.Prelude.system_prelude(%{"request_setup.open" => "ask"}) =~ "request_setup.open"
    end

    test "auto_permitted?/2 is the one kind rule" do
      assert Aqua.Kinds.auto_permitted?("files", "read")
      assert Aqua.Kinds.auto_permitted?("files", "write")
      assert Aqua.Kinds.auto_permitted?("http", "post")
      refute Aqua.Kinds.auto_permitted?("files", "delete")
      refute Aqua.Kinds.auto_permitted?("notion:create_page", "call")
      refute Aqua.Kinds.auto_permitted?("no_such_tool", "go")
    end

    test "kind_for/2 looks up the right kind for virtual tools" do
      assert Aqua.Kinds.kind_for("files", "read") == :read
      assert Aqua.Kinds.kind_for("files", "delete") == :destructive
      assert Aqua.Kinds.kind_for("storage", "write") == :write
    end

    test "a proposal for an external `server:tool` validates end to end" do
      # The id-shape regex refused `:` while every other layer — docs,
      # kind_for, the approval card, scope_permitted — spoke `server:tool`,
      # so a policy that asked for approval on an external MCP tool told
      # the agent to request a card that silently never appeared.
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Create page","summary":"in Notion","risk":"medium","action_description":"notion:create_page","proposal":{"tool":"notion:create_page","action":"call","args":{"title":"Hi"}}}]
```)
      result = Aqua.Wire.parse(input, %{"notion:create_page.call" => "ask"})

      assert result.drops == []
      assert [intent] = result.intents

      assert intent.proposal == %{
               tool: "notion:create_page",
               action: "call",
               args: %{"title" => "Hi"}
             }

      assert intent.action_kind == :external
    end

    test "kind_for/2 classifies any `server:tool`-namespaced external tool as :external" do
      # External upstream MCP tools are namespaced server:tool. They have
      # no enumerable action verbs, so AQUA returns :external regardless of
      # the action arg — no _default annotation involved.
      assert Aqua.Kinds.kind_for("notion:create_page", "x") == :external
      assert Aqua.Kinds.kind_for("github:list_issues", "anything") == :external
      assert Aqua.Kinds.kind_for("custom:weird-name", "") == :external
    end

    test "kind_for/2 returns nil for an internal tool with no annotation (no _default fallback)" do
      # An unknown action has no kind; startup validation reports missing annotations.
      assert Aqua.Kinds.kind_for("session", "nonexistent_action") == nil
    end

    test "proposal for a tool/action not in the allowlist is dropped" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"unknown","action":"do","args":{}}}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end

    test "proposal for an 'auto' action is dropped (must call it directly)" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"low","action_description":"z","proposal":{"tool":"files","action":"write","args":{}}}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "allowlisted as 'auto'"
    end

    test "proposal for an action of an allowlisted tool but with no matching key is dropped" do
      # `files.read`/`files.write` are present but `files.delete` is not, and
      # there's no `files.*` glob — so a delete request is not permitted.
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"files","action":"delete","args":{}}}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end

    test "proposal with non-object args is dropped" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"key","action":"revoke","args":"not-an-object"}}]
```)
      result = Aqua.Wire.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must be a JSON object"
    end

    test "empty allowlist drops every proposal" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"key","action":"revoke","args":{}}}]
```)
      result = Aqua.Wire.parse(input, %{})
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end
  end

  describe "system_prelude/1" do
    test "is byte-stable for the same policy" do
      assert Aqua.Prelude.system_prelude(@policy) == Aqua.Prelude.system_prelude(@policy)
    end

    test "mentions the protocol fence and an example kind" do
      prelude = Aqua.Prelude.system_prelude(%{})
      assert prelude =~ "aqua-actions"
      assert prelude =~ "ui.execution.focus"
    end

    test "lists the 'ask' targets sorted; risk visualization is the harness's job" do
      prelude = Aqua.Prelude.system_prelude(@policy)

      assert prelude =~ "## Actions that need approval"
      assert prelude =~ "component.pull"
      assert prelude =~ "execution.run"
      assert prelude =~ "execution.cancel"
      assert prelude =~ "registry.report"
      # `tool.*` globs are listed verbatim
      assert prelude =~ "component.*"
      # an action the chain cannot reach is not offered: the card would be
      # refused at the call, so the agent is not told to propose it
      refute Aqua.Prelude.system_prelude(%{"key.create" => "ask"}) =~ "key.create"

      # `component.register` is the deliberate instance of that rule.
      # It indexes whatever is sitting on the athanor's `components/` tree,
      # which a catalyst with a storage write grant can write to, so it
      # dropped `:in_chain` — and an approved proposal executes in-chain.
      # `consent: :staging` alone would NOT have closed this: it refuses
      # `Context.plane: :guest`, and AQUA runs host-side with the person's
      # own external context.
      refute Aqua.Prelude.system_prelude(%{"component.register" => "ask"}) =~
               "component.register"

      # 'auto' actions are directly callable — they don't appear here
      refute prelude =~ "files.read"
      refute prelude =~ "files.write"
      # No parenthetical risk levels — risk derives from kind, not policy mode
      refute prelude =~ "(low)"
      refute prelude =~ "(medium)"
      refute prelude =~ "(high)"
    end

    test "empty policy omits the approval section heading" do
      prelude = Aqua.Prelude.system_prelude(%{})
      refute prelude =~ "## Actions that need approval"
    end

    test "approval list is sorted (deterministic for prompt cache)" do
      prelude = Aqua.Prelude.system_prelude(@policy)
      # component.pull should appear before execution.cancel alphabetically
      pos_pull = :binary.match(prelude, "component.pull") |> elem(0)
      pos_cancel = :binary.match(prelude, "execution.cancel") |> elem(0)
      assert pos_pull < pos_cancel
    end
  end

  describe "ui.copy_clipboard" do
    defp clipboard(text) do
      json = Jason.encode!([%{"kind" => "ui.copy_clipboard", "text" => text}])
      Aqua.Wire.parse("```aqua-actions\n#{json}\n```", @policy)
    end

    test "ordinary text passes through, newlines and tabs intact" do
      body = "def run do\n\tIO.puts(:ok)\nend"
      assert %{intents: [%{kind: "copy_clipboard", text: ^body}], drops: []} = clipboard(body)
    end

    test "a trailing newline is stripped" do
      # The clipboard is the one action whose output leaves the browser, and
      # a terminal treats a trailing newline as Enter: model-written text
      # ending in one runs on paste without a second keystroke.
      assert %{intents: [%{text: "rm -rf /tmp/x"}]} = clipboard("rm -rf /tmp/x\n")
      assert %{intents: [%{text: "rm -rf /tmp/x"}]} = clipboard("rm -rf /tmp/x\n\n\n")
    end

    test "carriage returns and other control characters are removed" do
      assert %{intents: [%{text: "echo hiecho bye"}]} = clipboard("echo hi\recho bye")
      assert %{intents: [%{text: "ab"}]} = clipboard("a\x00\x07\x1bb")
    end

    test "oversized text is dropped by name" do
      assert %{intents: [], drops: [%{reason: reason}]} =
               clipboard(String.duplicate("x", 100_001))

      assert reason =~ "ui.copy_clipboard"
      assert reason =~ "100000"

      assert %{intents: [%{kind: "copy_clipboard"}], drops: []} =
               clipboard(String.duplicate("x", 100_000))
    end

    test "a non-string is dropped" do
      block = "```aqua-actions\n[{\"kind\":\"ui.copy_clipboard\",\"text\":42}]\n```"
      assert %{intents: [], drops: [%{reason: reason}]} = Aqua.Wire.parse(block, @policy)
      assert reason =~ "requires string"
    end
  end
end
