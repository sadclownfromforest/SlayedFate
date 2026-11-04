defmodule SipTest.ScriptTest do
  use ExUnit.Case, async: true

  alias SipTest.{Params, Scenarios, Script}

  test "parses every command, ignores comments and blank lines" do
    text = """
    # a comment
    send INVITE to=1002 sdp=none

    expect 180 183 timeout=ring
    expect 200 CANCEL timeout=2500
    expect-request bye timeout=60000
    auth
    auth wrong
    ack
    send ack
    wait 250
    assert-header Allow contains INVITE, BYE
    assert-body contains m=audio
    """

    assert {:ok, steps} = Script.parse(text)
    assert Enum.map(steps, & &1.cmd) ==
             [:send, :expect, :expect, :expect_request, :auth, :auth, :ack, :ack, :wait, :assert_header, :assert_body]

    [send, e1, e2, er, a1, a2 | _] = steps
    assert %{method: "INVITE", opts: %{"to" => "1002", "sdp" => "none"}} = send
    assert %{codes: [180, 183], method: nil, timeout: :ring} = e1
    assert %{codes: [200], method: "CANCEL", timeout: 2500} = e2
    assert %{method: "BYE", timeout: 60_000} = er
    assert a1.wrong == false and a2.wrong == true
    assert List.last(Enum.take(steps, 10)).text =~ "assert-header"
    assert Enum.at(steps, 9).name == "allow"
    assert Enum.at(steps, 9).text == "INVITE, BYE"
    assert Enum.at(steps, 0).line == 2
  end

  test "reports the line of an error" do
    assert {:error, "line 2: unknown command 'jump'"} = Script.parse("wait 5\njump 3")
    assert {:error, "line 1: expect needs at least one status code"} = Script.parse("expect INVITE")
    assert {:error, "line 1: wait needs milliseconds (0-600000)"} = Script.parse("wait abc")
    assert {:error, "line 1: usage: assert-header NAME contains TEXT"} = Script.parse("assert-header allow")
    assert {:error, "the script has no steps"} = Script.parse("# nothing\n\n")
    assert {:error, _} = Script.parse("expect 200 timeout=5")
  end

  test "every built-in scenario parses and ids are unique" do
    all = Scenarios.all()
    assert length(Enum.uniq_by(all, & &1.id)) == length(all)

    for sc <- all do
      assert {:ok, %{steps: [_ | _]}} = Scenarios.with_steps(sc), "scenario #{sc.id} must parse"
    end
  end

  test "params: host:port in the host field, validation and clamping" do
    assert {:ok, p} = Params.normalize(%{"host" => " 10.0.0.5:5070 "})
    assert p.host == "10.0.0.5" and p.port == 5070
    assert {:ok, %{port: 5099}} = Params.normalize(%{"host" => "h", "port" => "5099"})
    assert {:ok, %{timeout: 200, ring_timeout: 300_000}} =
             Params.normalize(%{"host" => "h", "timeout" => 5, "ring_timeout" => 10_000_000})
    assert {:ok, %{from_user: "tester", to_user: "1000", password: ""}} = Params.normalize(%{"host" => "h"})
    assert {:error, _} = Params.normalize(%{"host" => ""})
    assert {:error, _} = Params.normalize(%{"host" => "h", "port" => 70_000})
    assert {:error, _} = Params.normalize("nope")
    assert {:ok, %{host: "evilhostx"}} = Params.normalize(%{"host" => "evil host;x"})
  end
end
