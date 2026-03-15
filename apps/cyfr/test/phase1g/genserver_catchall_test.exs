defmodule Phase1g.GenServerCatchallTest do
  @moduledoc """
  Tests that all GenServers in the cyfr app with catch-all handle_info/2
  clauses survive unexpected messages and log a warning.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @unexpected_msg :unexpected_test_message

  @genservers [
    {Emissary.MCP.SSEBuffer, "SSEBuffer"},
    {Emissary.MCP.ToolRegistry, "ToolRegistry"},
    {Emissary.MCP.ResourceRegistry, "ResourceRegistry"},
    {Arca.Cache.Sweeper, "Sweeper"},
    {Prism.TelemetryBridge, "TelemetryBridge"},
    {Arca.AuditHandler, "AuditHandler"},
    {Prism.AppRegistry, "AppRegistry"}
  ]

  describe "catch-all handle_info/2" do
    for {mod, label} <- @genservers do
      test "#{label} (#{mod}) survives unexpected message and logs warning" do
        mod = unquote(mod)
        pid = Process.whereis(mod)

        if is_nil(pid) do
          flunk("#{inspect(mod)} is not running — cannot test catch-all handle_info/2")
        end

        assert Process.alive?(pid), "#{inspect(mod)} should be alive before sending message"

        log =
          capture_log(fn ->
            send(pid, @unexpected_msg)
            # Give the GenServer time to process the message
            Process.sleep(50)
          end)

        assert Process.alive?(pid),
               "#{inspect(mod)} should still be alive after receiving unexpected message"

        assert log =~ "unexpected message",
               "Expected #{inspect(mod)} to log 'unexpected message', got: #{inspect(log)}"

        assert log =~ inspect(@unexpected_msg),
               "Expected log to contain #{inspect(@unexpected_msg)}, got: #{inspect(log)}"
      end
    end
  end
end
