defmodule Prism.AquaActionsTest do
  use ExUnit.Case, async: true

  alias Prism.AquaActions

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

  describe "parse/1" do
    test "ui.navigate: allowed path produces navigate intent" do
      input = "go now\n\n```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/activity\"}]\n```\n"
      result = AquaActions.parse(input)

      assert result.stripped == "go now"
      assert result.intents == [%{kind: "navigate", to: "/activity"}]
      assert result.drops == []
    end

    test "ui.navigate: disallowed path is dropped, block still stripped" do
      input = "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/etc/passwd\"}]\n```"
      result = AquaActions.parse(input)

      assert result.stripped == ""
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "not in allowlist"
    end

    test "ui.navigate: query-string variants of allowed routes pass" do
      input = "```aqua-actions\n[{\"kind\":\"ui.navigate\",\"path\":\"/executions?id=exec_a\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_a"}]
    end

    test "ui.execution.focus collapses to navigate with prefix-validated id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"exec_abc\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == [%{kind: "navigate", to: "/executions?id=exec_abc"}]
    end

    test "ui.execution.focus rejects non-prefixed id" do
      input = "```aqua-actions\n[{\"kind\":\"ui.execution.focus\",\"id\":\"req_abc\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must start with exec_"
    end

    test "ui.execution.focus rejects path-injection attempts" do
      input = ~S(```aqua-actions
[{"kind":"ui.execution.focus","id":"exec_../etc/passwd"}]
```)
      result = AquaActions.parse(input)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "disallowed characters"
    end

    test "ui.component.focus accepts ref, builds /components/:ref" do
      input = "```aqua-actions\n[{\"kind\":\"ui.component.focus\",\"ref\":\"local.weather-app\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == [%{kind: "navigate", to: "/components/local.weather-app"}]
    end

    test "ui.tincture.focus url-encodes publisher and name" do
      input = ~S(```aqua-actions
[{"kind":"ui.tincture.focus","publisher":"acme.co","name":"my-app"}]
```)
      result = AquaActions.parse(input)

      assert [%{kind: "navigate", to: to}] = result.intents
      assert to =~ "publisher=acme.co"
      assert to =~ "tincture_name=my-app"
    end

    test "ui.overlay.open without state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == [%{kind: "overlay_open"}]
    end

    test "ui.overlay.open with valid state" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"full\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == [%{kind: "overlay_open", state: "full"}]
    end

    test "ui.overlay.open rejects peek (post-removal)" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.open\",\"state\":\"peek\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "must be \"half\" or \"full\""
    end

    test "ui.overlay.close" do
      input = "```aqua-actions\n[{\"kind\":\"ui.overlay.close\"}]\n```"
      assert AquaActions.parse(input).intents == [%{kind: "overlay_close"}]
    end

    test "ui.copy_clipboard captures text" do
      input = "```aqua-actions\n[{\"kind\":\"ui.copy_clipboard\",\"text\":\"hello\"}]\n```"
      assert AquaActions.parse(input).intents == [%{kind: "copy_clipboard", text: "hello"}]
    end

    test "ui.request_approval requires all four fields" do
      good = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"Delete?","summary":"removes X","risk":"high","action_description":"hard delete"}]
```)
      result = AquaActions.parse(good)
      assert [%{kind: "request_approval", risk: "high"}] = result.intents
    end

    test "ui.request_approval rejects unknown risk" do
      input = ~S(```aqua-actions
[{"kind":"ui.request_approval","title":"x","summary":"y","risk":"extreme","action_description":"z"}]
```)
      result = AquaActions.parse(input)
      assert result.intents == []
      assert [%{reason: reason}] = result.drops
      assert reason =~ "low|medium|high"
    end

    test "unknown kind is dropped" do
      input = "```aqua-actions\n[{\"kind\":\"ui.lol.do_evil\"}]\n```"
      result = AquaActions.parse(input)
      assert result.intents == []
      assert [%{reason: "unknown kind: " <> _}] = result.drops
    end

    test "malformed JSON drops the entry but still strips the block" do
      input = "before\n```aqua-actions\nthis is not JSON\n```\nafter"
      result = AquaActions.parse(input)
      assert result.stripped == "before\n\nafter"
      assert result.intents == []
      assert [%{reason: "JSON parse error: " <> _}] = result.drops
    end

    test "non-array JSON body is dropped" do
      input = "```aqua-actions\n{\"kind\":\"ui.navigate\",\"path\":\"/\"}\n```"
      result = AquaActions.parse(input)
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
      result = AquaActions.parse(input)

      assert result.intents == [
               %{kind: "navigate", to: "/executions"},
               %{kind: "copy_clipboard", text: "abc"}
             ]
    end
  end

  describe "system_prelude/0" do
    test "is byte-stable across calls (compile-time module attribute)" do
      assert AquaActions.system_prelude() == AquaActions.system_prelude()
    end

    test "mentions the protocol fence and an example kind" do
      prelude = AquaActions.system_prelude()
      assert prelude =~ "aqua-actions"
      assert prelude =~ "ui.execution.focus"
    end
  end
end
