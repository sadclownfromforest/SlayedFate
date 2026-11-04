defmodule SipPhone.LogBufferTest do
  use ExUnit.Case, async: false

  require Logger
  alias SipPhone.LogBuffer

  test "redacts secrets in log lines" do
    assert LogBuffer.redact(~s(cfg %{password: "hunter2", user: "a"})) =~ ~s(password: "***")
    refute LogBuffer.redact(~s(cfg %{password: "hunter2"})) =~ "hunter2"
    refute LogBuffer.redact(~s(%{"password" => "hunter2"})) =~ "hunter2"
    assert LogBuffer.redact("nothing to hide") == "nothing to hide"
  end

  test "Logger lines end up in the buffer, secrets redacted" do
    LogBuffer.clear()
    Logger.error("logbuffer-test token=abc123 visible")
    Process.sleep(200)
    lines = LogBuffer.lines()
    line = Enum.find(lines, &(&1["text"] =~ "logbuffer-test"))
    assert line["level"] == "error"
    refute line["text"] =~ "abc123"
    assert line["text"] =~ "visible"
  end
end
