defmodule SipTest.FakeUas do
  @moduledoc "A scriptable fake phone on 127.0.0.1 for exercising the engine."
  alias SipTest.Message

  @doc """
  `handler` receives each request and returns a list of responses:
  `{code, reason, headers, body}` (answers that request) or
  `{:to, other_request, code, reason, headers, body}` (answers an earlier request).
  """
  def start(handler) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, sock} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(sock)
        send(parent, {:uas_port, port})
        loop(sock, handler)
      end)

    receive do
      {:uas_port, port} -> {pid, port}
    after
      2_000 -> raise "fake UAS did not start"
    end
  end

  defp loop(sock, handler) do
    receive do
      {:udp, ^sock, ip, port, data} ->
        case Message.parse(data) do
          {:ok, %{type: :request} = req} ->
            for item <- handler.(req) do
              {orig, code, reason, headers, body} =
                case item do
                  {code, reason, headers, body} -> {req, code, reason, headers, body}
                  {:to, orig, code, reason, headers, body} -> {orig, code, reason, headers, body}
                end

              resp =
                Message.response(orig, code, reason,
                  to_tag: "uastag",
                  src: {ip, port},
                  headers: headers,
                  body: body
                )

              :gen_udp.send(sock, ip, port, Message.serialize(resp))
            end

          _ ->
            :ok
        end

        loop(sock, handler)
    end
  end
end

defmodule SipTest.EngineTest do
  use ExUnit.Case, async: true

  alias SipTest.{Engine, FakeUas, Message, Params, Scenarios, Script}

  @sdp "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 4000 RTP/AVP 0\r\n"
  @contact {"contact", "<sip:uas@127.0.0.1:9>"}

  defp params(port, extra \\ %{}) do
    {:ok, p} =
      Params.normalize(
        Map.merge(%{"host" => "127.0.0.1", "port" => port, "password" => "pw", "timeout" => 800, "ring_timeout" => 2_000}, extra)
      )

    p
  end

  defp run_scenario(id, port, extra \\ %{}) do
    {:ok, sc} = Scenarios.with_steps(Scenarios.get(id))
    Engine.run(sc.steps, params(port, extra), fn _ -> :ok end)
  end

  defp run_script(text, port) do
    {:ok, steps} = Script.parse(text)
    Engine.run(steps, params(port), fn _ -> :ok end)
  end

  # Handler that rings, then lets the test decide the rest through the process dictionary of the UAS.
  defp phone(test_pid, opts \\ []) do
    answer? = Keyword.get(opts, :answer, false)
    reject = Keyword.get(opts, :reject)

    fn req ->
      send(test_pid, {:got, req.method})

      case req.method do
        "OPTIONS" ->
          [{200, "OK", [{"allow", "INVITE, ACK, CANCEL, BYE, OPTIONS"}], ""}]

        "INVITE" ->
          Process.put(:invite, req)

          cond do
            reject != nil -> [{100, "Trying", [], ""}, {reject, "Rejected", [], ""}]
            answer? -> [{180, "Ringing", [], ""}, {200, "OK", [@contact, {"content-type", "application/sdp"}], @sdp}]
            true -> [{100, "Trying", [], ""}, {180, "Ringing", [@contact], ""}]
          end

        "CANCEL" ->
          [{200, "OK", [], ""}, {:to, Process.get(:invite), 487, "Request Terminated", [], ""}]

        "BYE" ->
          [{200, "OK", [], ""}]

        _ ->
          []
      end
    end
  end

  test "OPTIONS ping passes against a phone that answers 200" do
    {_, port} = FakeUas.start(phone(self()))
    assert %{status: "pass"} = run_scenario("options-ping", port)
  end

  test "a wrong status code fails the scenario with a readable error" do
    {_, port} = FakeUas.start(fn _ -> [{500, "Server Error", [], ""}] end)
    res = run_scenario("options-ping", port)
    assert res.status == "fail"
    assert res.error =~ "expected 200 to OPTIONS, got 500"
  end

  test "silence is reported as a timeout" do
    {_, port} = FakeUas.start(fn _ -> [] end)
    res = run_scenario("options-ping", port, %{"timeout" => 300})
    assert res.status == "fail"
    assert res.error =~ "no 200 to OPTIONS within 300 ms"
  end

  test "ringing then CANCEL: 200 for CANCEL and 487 for INVITE (acked automatically)" do
    {_, port} = FakeUas.start(phone(self()))
    assert %{status: "pass"} = run_scenario("invite-ringing-cancel", port)
    assert_receive {:got, "INVITE"}, 1_000
    assert_receive {:got, "CANCEL"}, 1_000
    assert_receive {:got, "ACK"}, 1_000
  end

  test "answered call: 200, ACK, then BYE gets 200" do
    {_, port} = FakeUas.start(phone(self(), answer: true))
    assert %{status: "pass"} = run_scenario("invite-answer-bye", port)
    assert_receive {:got, "ACK"}, 1_000
    assert_receive {:got, "BYE"}, 1_000
  end

  test "a rejected call is accepted by the reject scenario and the non-2xx is ACKed" do
    {_, port} = FakeUas.start(phone(self(), reject: 486))
    assert %{status: "pass"} = run_scenario("invite-reject", port)
    assert_receive {:got, "ACK"}, 1_000
  end

  test "BYE outside a dialog expects 481" do
    {_, port} = FakeUas.start(fn _ -> [{481, "Call/Transaction Does Not Exist", [], ""}] end)
    assert %{status: "pass"} = run_scenario("bye-unknown-dialog", port)
  end

  test "register with digest: 401 challenge is answered and then 200" do
    me = self()

    {_, port} =
      FakeUas.start(fn req ->
        case Message.header(req, "authorization") do
          nil ->
            [{401, "Unauthorized", [{"www-authenticate", "Digest realm=\"test\", nonce=\"abc123\", qop=\"auth\", algorithm=MD5"}], ""}]

          auth ->
            send(me, {:auth, auth})
            [{200, "OK", [], ""}]
        end
      end)

    assert %{status: "pass"} = run_scenario("register-auth", port)
    assert_received {:auth, auth}
    assert auth =~ ~s(username="tester")
    assert auth =~ ~s(realm="test")
    assert auth =~ "response="
  end

  test "register works when the server does not challenge at all" do
    {_, port} = FakeUas.start(fn _ -> [{200, "OK", [], ""}] end)
    assert %{status: "pass"} = run_scenario("register-auth", port)
  end

  test "wrong password scenario passes when the server rejects again, fails when it accepts" do
    {_, p1} = FakeUas.start(fn _ -> [{401, "Unauthorized", [{"www-authenticate", "Digest realm=\"r\", nonce=\"n\""}], ""}] end)
    assert %{status: "pass"} = run_scenario("register-wrong-password", p1)

    {_, p2} =
      FakeUas.start(fn req ->
        if Message.header(req, "authorization"),
          do: [{200, "OK", [], ""}],
          else: [{401, "Unauthorized", [{"www-authenticate", "Digest realm=\"r\", nonce=\"n\""}], ""}]
      end)

    res = run_scenario("register-wrong-password", p2)
    assert res.status == "fail"
    assert res.error =~ "got 200"
  end

  test "missing password is reported instead of sending garbage" do
    {_, port} = FakeUas.start(fn _ -> [{401, "Unauthorized", [{"www-authenticate", "Digest realm=\"r\", nonce=\"n\""}], ""}] end)
    res = run_scenario("register-auth", port, %{"password" => ""})
    assert res.status == "fail"
    assert res.error =~ "no password"
  end

  test "a failing scenario leaves the phone idle: CANCEL is sent for a ringing call" do
    {_, port} = FakeUas.start(phone(self()))
    res = run_script("send INVITE\nexpect 200 timeout=500\n", port)
    assert res.status == "fail"
    assert_receive {:got, "CANCEL"}, 2_000
  end

  test "asserts check headers and body of the last response" do
    {_, port} = FakeUas.start(phone(self(), answer: true))
    assert %{status: "pass"} = run_script("send INVITE\nexpect 200 timeout=ring\nassert-header contact contains uas@\nassert-body contains m=audio\nack\nsend BYE\nexpect 200\n", port)

    {_, port2} = FakeUas.start(phone(self(), answer: true))
    res = run_script("send INVITE\nexpect 200 timeout=ring\nassert-body contains video\nack\nsend BYE\nexpect 200\n", port2)
    assert res.status == "fail"
    assert res.error =~ "body does not contain 'video'"
  end

  test "unresolvable host fails cleanly" do
    {:ok, steps} = Script.parse("send OPTIONS\nexpect 200")
    {:ok, p} = Params.normalize(%{"host" => "no-such-host.invalid"})
    res = Engine.run(steps, p, fn _ -> :ok end)
    assert res.status == "fail"
    assert res.error =~ "Cannot resolve"
  end
end
