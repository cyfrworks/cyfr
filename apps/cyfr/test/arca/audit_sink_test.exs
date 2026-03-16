defmodule Arca.AuditSinkTest do
  use ExUnit.Case, async: true

  test "behaviour defines handle_audit_event/3 callback" do
    callbacks = Arca.AuditSink.behaviour_info(:callbacks)
    assert {:handle_audit_event, 3} in callbacks
  end
end
