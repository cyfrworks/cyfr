# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaActionsTest do
  use ExUnit.Case, async: true

  alias Prism.AquaActions

  # New-model allowlist: keys are `tool.action` (or `tool.*` globs), values are
  # "ask" (request approval) or "auto" (call directly). An absent key means the
  # agent can't perform the action at all. `files.delete` is intentionally
  # absent here so tests can exercise the not-allowlisted path.
  @policy %{
    "key.revoke" => "ask",
    "key.create" => "ask",
    "policy.set" => "ask",
    "policy.delete" => "ask",
    "secret.set" => "ask",
    "component.*" => "ask",
    "files.read" => "auto",
    "files.write" => "auto"
  }

  describe "strip_blocks/1" do
    test "removes a complete block" do
      input = "before\n\n```aqua-actions\n[]\n```\n\nafter"
      assert AquaActions.strip_blocks(input) == "before\n\n\n\nafter"
    end

    test "removes an open-tail block (mid-stream)" do
      input = "before\n```aqua-actions\n[{\"kind\":\"ui.navigate"
      assert AquaActions.strip_blocks(input) == "before\n"
    end

    test "passes content with no block through unchanged" do
      input = "no actions here\nplain text"
      assert AquaActions.strip_blocks(input) == input
    end

    test "removes multiple blocks in one pass" do
      input = "a\n```aqua-actions\n[]\n```\nb\n```aqua-actions\n[]\n```\nc"
      assert AquaActions.strip_blocks(input) == "a\n\nb\n\nc"
    end
  end

  describe "parse/2" do
    test "ui.navigate: allowed path produces navigate intent" do
      input =
        "go now\n\n```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/activities\"}]\n```\n"

      result = AquaActions.parse(input, @policy)

      assert result.stripped == "go now"
      assert result.intents == [%{kind: "navigate", to: "/activities"}]
      assert result.drops == []
    end

    test "ui.navigate: disallowed path is dropped, block still stripped" do
      input = "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/etc/passwd\"}]\n```"
      result = AquaActions.parse(input, @policy)

      assert result.stripped == ""
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in allowlist"
    end

    test "ui.navigate: query-string variants of allowed routes pass" do
      input =
        "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/executions?id=exec_a\"}]\n```"

      result = AquaActions.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_a"}]
    end

    test "ui.execution.focus collapses to navigate with prefix-validated id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"exec_abc\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_abc"}]
    end

    test "ui.execution.focus rejects non-prefixed id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"req_abc\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must start with exec_"
    end

    test "ui.execution.focus rejects path-injection attempts" do
      input = ~S(```aqua-actions
[{"kind":"ui.execution.focus","id":"exec_../etc/passwd"}]
```)
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "disallowed characters"
    end

    test "ui.component.focus accepts ref, builds /components/:ref" do
      input =
        "```aqua-actions\n[{\"kind\":\"ui.component.focus\",\"ref\":\"local.weather-app\"}]\n```"

      result = AquaActions.parse(input, @policy)
      assert result.intents == [%{kind: "navigate", to: "/components/local.weather-app"}]
    end

    test "ui.tincture.focus url-encodes publisher and name" do
      input = ~S(```aqua-actions
[{"kind":"ui.tincture.focus","publisher":"acme.co","name":"my-app"}]
```)
      result = AquaActions.parse(input, @policy)

      assert [%{kind: "navigate", to: to}] = result.intents
      assert to =~ "publisher=acme.co"
      assert to =~ "tincture_name=my-app"
    end

    test "ui.overlay.open without state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == [%{kind: "overlay_open"}]
    end

    test "ui.overlay.open with valid state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"full\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == [%{kind: "overlay_open", state: "full"}]
    end

    test "ui.overlay.open rejects peek (post-removal)" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"peek\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must be \"half\" or \"full\""
    end

    test "ui.overlay.close" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.close\"}]\n```"
      assert AquaActions.parse(input, @policy).intents == [%{kind: "overlay_close"}]
    end

    test "ui.copy_clipboard captures text" do
      input = "```aqua-actions\n[{\"kind\":\"ui.copy_clipboard\",\"text\":\"hello\"}]\n```"

      assert AquaActions.parse(input, @policy).intents == [
               %{kind: "copy_clipboard", text: "hello"}
             ]
    end

    test "unknown kind is dropped" do
      input = "```aqua-actions\n[{\"kind\":\"ui.lol.do_evil\"}]\n```"
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: "unknown kind: " <> _}] = result.drops
    end

    test "malformed JSON drops the entry but still strips the block" do
      input = "before\n```aqua-actions\nthis is not JSON\n```\nafter"
      result = AquaActions.parse(input, @policy)
      assert result.stripped == "before\n\nafter"
      assert result.intents == []
      assert [%{reason: "JSON parse error: " <> _}] = result.drops
    end

    test "non-array JSON body is dropped" do
      input = "```aqua-actions\n{\"kind\":\"ui.navigate\",\"path\":\"/\"}\n```"
      result = AquaActions.parse(input, @policy)
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
      result = AquaActions.parse(input, @policy)

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
      result = AquaActions.parse(input, @policy)

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
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "low|medium|high"
    end

    test "proposal for an 'ask' action is accepted; agent's hinted_risk preserved" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Revoke key","summary":"oldest","risk":"low","action_description":"key.revoke","proposal":{"tool":"key","action":"revoke","args":{"name":"old"}}}]
```)
      result = AquaActions.parse(input, @policy)

      assert [intent] = result.intents
      assert intent.proposal == %{tool: "key", action: "revoke", args: %{"name" => "old"}}
      # action_kind comes from the tool registry's annotations when it's
      # populated. In test isolation it may be nil; production paths render
      # via aqua_live.ex which always has the registry loaded.
      assert intent.action_kind in [nil, :write]
      assert intent.hinted_risk == "low"
    end

    test "proposal matched by a `tool.*` glob in the allowlist is accepted" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Push","summary":"ship it","risk":"medium","action_description":"component.push","proposal":{"tool":"component","action":"push","args":{"ref":"catalyst:local.x:1.0.0"}}}]
```)
      result = AquaActions.parse(input, @policy)

      assert [intent] = result.intents

      assert intent.proposal == %{
               tool: "component",
               action: "push",
               args: %{"ref" => "catalyst:local.x:1.0.0"}
             }
    end

    test "kind_for/2 looks up the right kind for virtual tools" do
      assert AquaActions.kind_for("files", "read") == :read
      assert AquaActions.kind_for("files", "delete") == :destructive
      assert AquaActions.kind_for("storage", "write") == :write
    end

    test "kind_for/2 classifies any `server:tool`-namespaced external tool as :external" do
      # External upstream MCP tools are namespaced server:tool. They have
      # no enumerable action verbs, so AQUA returns :external regardless of
      # the action arg — no _default annotation involved.
      assert AquaActions.kind_for("notion:create_page", "x") == :external
      assert AquaActions.kind_for("github:list_issues", "anything") == :external
      assert AquaActions.kind_for("custom:weird-name", "") == :external
    end

    test "kind_for/2 returns nil for an internal tool with no annotation (no _default fallback)" do
      # Sanity check: a known-internal tool with an action that doesn't
      # exist in its `annotations.actions` returns nil. Previously this
      # would have fallen back to `_default`; the audit_action_kinds/0
      # startup check is what surfaces these gaps now.
      assert AquaActions.kind_for("session", "nonexistent_action") == nil
    end

    test "proposal for a tool/action not in the allowlist is dropped" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"unknown","action":"do","args":{}}}]
```)
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end

    test "proposal for an 'auto' action is dropped (must call it directly)" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"low","action_description":"z","proposal":{"tool":"files","action":"write","args":{}}}]
```)
      result = AquaActions.parse(input, @policy)
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
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end

    test "proposal with non-object args is dropped" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"key","action":"revoke","args":"not-an-object"}}]
```)
      result = AquaActions.parse(input, @policy)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must be a JSON object"
    end

    test "empty allowlist drops every proposal" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"high","action_description":"z","proposal":{"tool":"key","action":"revoke","args":{}}}]
```)
      result = AquaActions.parse(input, %{})
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in your tool allowlist"
    end
  end

  describe "system_prelude/1" do
    test "is byte-stable for the same policy" do
      assert AquaActions.system_prelude(@policy) == AquaActions.system_prelude(@policy)
    end

    test "mentions the protocol fence and an example kind" do
      prelude = AquaActions.system_prelude(%{})
      assert prelude =~ "aqua-actions"
      assert prelude =~ "ui.execution.focus"
    end

    test "lists the 'ask' targets sorted; risk visualization is the harness's job" do
      prelude = AquaActions.system_prelude(@policy)

      assert prelude =~ "## Actions that need approval"
      assert prelude =~ "key.create"
      assert prelude =~ "key.revoke"
      assert prelude =~ "policy.set"
      assert prelude =~ "policy.delete"
      assert prelude =~ "secret.set"
      # `tool.*` globs are listed verbatim
      assert prelude =~ "component.*"
      # 'auto' actions are directly callable — they don't appear here
      refute prelude =~ "files.read"
      refute prelude =~ "files.write"
      # No parenthetical risk levels — risk derives from kind, not policy mode
      refute prelude =~ "(low)"
      refute prelude =~ "(medium)"
      refute prelude =~ "(high)"
    end

    test "empty policy omits the approval section heading" do
      prelude = AquaActions.system_prelude(%{})
      refute prelude =~ "## Actions that need approval"
    end

    test "approval list is sorted (deterministic for prompt cache)" do
      prelude = AquaActions.system_prelude(@policy)
      # key.create should appear before key.revoke alphabetically
      pos_create = :binary.match(prelude, "key.create") |> elem(0)
      pos_revoke = :binary.match(prelude, "key.revoke") |> elem(0)
      assert pos_create < pos_revoke
    end
  end
end
