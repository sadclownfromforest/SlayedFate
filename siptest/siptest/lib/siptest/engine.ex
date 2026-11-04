defmodule SipTest.Engine do
  @moduledoc """
  Executes one parsed scenario as a SIP UAC over UDP (RFC 3261) against the target.

  Transaction behaviour that mirrors a real UA:
    * every final non-2xx response to INVITE is ACKed automatically (17.1.1.3), also when retransmitted;
    * a retransmitted 2xx to INVITE is re-ACKed once the script has sent its ACK (13.2.2.4);
    * requests that the phone sends to us (BYE, OPTIONS, ...) are answered (200 / 488 / 481 / 501);
    * when a scenario ends with a call still ringing or established, it is CANCELled / BYEd so the phone
      is left idle.

  `emit` receives plain maps (`%{type: "step" | "trace", ...}`); the caller adds the scenario id.
  """

  alias SipTest.{Digest, Message, SDP}

  @ua "SipTest-Elixir/0.1"
  @allow "INVITE, ACK, CANCEL, BYE, OPTIONS, NOTIFY, INFO, MESSAGE, UPDATE"
  @in_ok ["OPTIONS", "NOTIFY", "INFO", "MESSAGE", "UPDATE"]

  @doc "Run `steps` with validated params `p`. Returns %{status: \"pass\" | \"fail\", error: nil | binary, ms: integer}."
  def run(steps, p, emit) do
    started = now()

    case open(p, emit) do
      {:error, msg} ->
        %{status: "fail", error: msg, ms: 0}

      {:ok, st} ->
        {outcome, st} =
          try do
            run_steps(steps, st)
          catch
            :throw, {:stopped, st2} -> {{:error, "stopped by user"}, st2}
          end

        st = cleanup(st)
        :gen_udp.close(st.sock)
        flush_udp()
        ms = now() - started

        case outcome do
          :ok -> %{status: "pass", error: nil, ms: ms}
          {:error, msg} -> %{status: "fail", error: msg, ms: ms}
        end
    end
  end

  ## ------------------------------------------------------------------
  ## Setup

  defp open(p, emit) do
    with {:ok, ip} <- resolve(p.host),
         {:ok, sock} <- :gen_udp.open(p.local_port, [:binary, active: true, ip: {0, 0, 0, 0}]),
         {:ok, {_, lport}} <- :inet.sockname(sock) do
      lhost = if p.local_host != "", do: p.local_host, else: ip |> local_ip_for() |> :inet.ntoa() |> to_string()

      {:ok,
       %{
         p: p,
         emit: emit,
         sock: sock,
         ip: ip,
         port: p.port,
         local_host: lhost,
         local_port: lport,
         cseq: 0,
         inbox: [],
         reqs_in: [],
         reqs: %{},
         call_ids: MapSet.new(),
         finals: MapSet.new(),
         history: [],
         invites: %{},
         invite: nil,
         invite_pending: false,
         call_id: nil,
         from_hdr: nil,
         inv_2xx: nil,
         remote_target: nil,
         route_set: [],
         ack_msg: nil,
         ended: false,
         last_method: nil,
         last_resp: nil
       }}
    else
      {:error, {:resolve, r}} -> {:error, "Cannot resolve #{p.host}: #{inspect(r)}"}
      {:error, r} -> {:error, "Cannot open UDP socket: #{inspect(r)}"}
    end
  end

  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, r} -> {:error, {:resolve, r}}
    end
  end

  # The local interface address the OS would use to reach `ip`.
  defp local_ip_for({127, _, _, _}), do: {127, 0, 0, 1}

  defp local_ip_for(ip) do
    case :gen_udp.open(0, [:binary]) do
      {:ok, s} ->
        res =
          with :ok <- :gen_udp.connect(s, ip, 9),
               {:ok, {lip, _}} <- :inet.sockname(s) do
            lip
          else
            _ -> {127, 0, 0, 1}
          end

        :gen_udp.close(s)
        res

      _ ->
        {127, 0, 0, 1}
    end
  end

  ## ------------------------------------------------------------------
  ## Step loop

  defp run_steps(steps, st) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, st}, fn {step, idx}, {:ok, st} ->
      st.emit.(%{type: "step", idx: idx, text: step.text, status: "running", detail: "", ms: 0})
      t0 = now()
      {res, st2} = exec(step, st)
      ms = now() - t0

      case res do
        {:ok, detail} ->
          st2.emit.(%{type: "step", idx: idx, text: step.text, status: "pass", detail: detail, ms: ms})
          {:cont, {:ok, st2}}

        {:error, detail} ->
          st2.emit.(%{type: "step", idx: idx, text: step.text, status: "fail", detail: detail, ms: ms})
          {:halt, {{:error, "step #{idx + 1} (#{step.text}): #{detail}"}, st2}}
      end
    end)
  end

  defp exec(%{cmd: :send, method: m, opts: o}, st), do: do_send(st, m, o)
  defp exec(%{cmd: :ack}, st), do: do_ack(st)
  defp exec(%{cmd: :auth, wrong: w}, st), do: do_auth(st, w)
  defp exec(%{cmd: :expect} = s, st), do: do_expect(st, s)
  defp exec(%{cmd: :expect_request} = s, st), do: do_expect_request(st, s)

  defp exec(%{cmd: :wait, ms: ms}, st) do
    st = pump_until(st, now() + ms)
    {{:ok, "waited #{ms} ms"}, st}
  end

  defp exec(%{cmd: :assert_header, name: name, text: text}, st) do
    case st.last_resp do
      nil ->
        {{:error, "no response to check yet"}, st}

      resp ->
        vals = Message.headers(resp, name)

        case Enum.find(vals, fn v -> contains?(v, text) end) do
          nil ->
            shown = if vals == [], do: "header is missing", else: "got: " <> Enum.join(vals, " | ")
            {{:error, "#{name} does not contain '#{text}' (#{shown})"}, st}

          v ->
            {{:ok, "#{name}: #{v}"}, st}
        end
    end
  end

  defp exec(%{cmd: :assert_body, text: text}, st) do
    case st.last_resp do
      nil -> {{:error, "no response to check yet"}, st}
      resp -> body_check(resp, text, st)
    end
  end

  defp body_check(resp, text, st) do
    if contains?(resp.body, text),
      do: {{:ok, "body contains '#{text}'"}, st},
      else: {{:error, "body does not contain '#{text}'"}, st}
  end

  defp contains?(hay, needle), do: String.contains?(String.downcase(hay || ""), String.downcase(needle))

  ## ------------------------------------------------------------------
  ## send

  defp do_send(st, "INVITE", o) do
    uri = "sip:#{o["to"] || st.p.to_user}@#{domain(st)}"
    call_id = new_call_id(st)
    seq = st.cseq + 1
    branch = new_branch()
    from = "#{display(st)}<#{aor(st)}>;tag=#{rand_hex(5)}"
    body = sdp_body(st, o["sdp"])

    headers =
      [
        {"via", via(st, branch)},
        {"max-forwards", o["max-forwards"] || "70"},
        {"from", from},
        {"to", "<#{uri}>"},
        {"call-id", call_id},
        {"cseq", "#{seq} INVITE"},
        {"contact", contact(st)},
        {"user-agent", @ua},
        {"allow", @allow}
      ] ++ if(body == "", do: [], else: [{"content-type", "application/sdp"}])

    msg = Message.request("INVITE", uri, headers, body)

    st = %{
      st
      | call_id: call_id,
        from_hdr: from,
        inv_2xx: nil,
        remote_target: nil,
        route_set: [],
        ack_msg: nil,
        ended: false,
        invite: %{msg: msg, branch: branch, seq: seq},
        invites: Map.put(st.invites, seq, msg),
        invite_pending: true
    }

    {{:ok, "INVITE #{uri}"}, transmit(st, msg, seq, "INVITE")}
  end

  defp do_send(st, "REGISTER", o) do
    expires = to_int(o["expires"], 300)
    seq = st.cseq + 1
    branch = new_branch()
    me = aor(st)

    headers = [
      {"via", via(st, branch)},
      {"max-forwards", o["max-forwards"] || "70"},
      {"from", "#{display(st)}<#{me}>;tag=#{rand_hex(5)}"},
      {"to", "<#{me}>"},
      {"call-id", new_call_id(st)},
      {"cseq", "#{seq} REGISTER"},
      {"contact", "#{contact(st)};expires=#{expires}"},
      {"expires", Integer.to_string(expires)},
      {"user-agent", @ua},
      {"allow", @allow}
    ]

    msg = Message.request("REGISTER", "sip:#{domain(st)}", headers)
    {{:ok, "REGISTER #{me} expires=#{expires}"}, transmit(st, msg, seq, "REGISTER")}
  end

  defp do_send(st, "CANCEL", _o) do
    case st.invite do
      nil ->
        {{:error, "no INVITE was sent, nothing to CANCEL"}, st}

      %{msg: inv, branch: branch, seq: seq} ->
        headers =
          [
            {"via", via(st, branch)},
            {"max-forwards", "70"},
            {"from", Message.header(inv, "from")},
            {"to", Message.header(inv, "to")},
            {"call-id", Message.header(inv, "call-id")},
            {"cseq", "#{seq} CANCEL"},
            {"user-agent", @ua}
          ] ++ for({"route", r} <- inv.headers, do: {"route", r})

        msg = Message.request("CANCEL", inv.uri, headers)
        {{:ok, "CANCEL (INVITE cseq #{seq})"}, transmit(st, msg, seq, "CANCEL")}
    end
  end

  defp do_send(st, "BYE", o) do
    if st.inv_2xx != nil and not st.ended do
      dialog_send(st, "BYE", o)
    else
      # no dialog: the phone must answer 481 (RFC 3261 15.1.2)
      out_of_dialog(st, "BYE", Map.put(o, "totag", rand_hex(5)))
    end
  end

  defp do_send(st, method, o) do
    if o["dialog"] == "true" and st.inv_2xx != nil,
      do: dialog_send(st, method, o),
      else: out_of_dialog(st, method, o)
  end

  defp out_of_dialog(st, method, o) do
    uri = "sip:#{o["to"] || st.p.to_user}@#{domain(st)}"
    seq = st.cseq + 1
    to = if o["totag"], do: "<#{uri}>;tag=#{o["totag"]}", else: "<#{uri}>"

    headers =
      [
        {"via", via(st, new_branch())},
        {"max-forwards", o["max-forwards"] || "70"},
        {"from", "#{display(st)}<#{aor(st)}>;tag=#{rand_hex(5)}"},
        {"to", to},
        {"call-id", new_call_id(st)},
        {"cseq", "#{seq} #{method}"},
        {"contact", contact(st)},
        {"user-agent", @ua},
        {"allow", @allow}
      ] ++ if(method == "OPTIONS", do: [{"accept", "application/sdp"}], else: [])

    msg = Message.request(method, uri, headers)
    {{:ok, "#{method} #{uri}"}, transmit(st, msg, seq, method)}
  end

  defp dialog_send(st, method, o) do
    resp = st.inv_2xx
    seq = st.cseq + 1

    headers =
      [
        {"via", via(st, new_branch())},
        {"max-forwards", o["max-forwards"] || "70"},
        {"from", st.from_hdr},
        {"to", Message.header(resp, "to")},
        {"call-id", st.call_id},
        {"cseq", "#{seq} #{method}"},
        {"user-agent", @ua}
      ] ++ Enum.map(st.route_set, fn r -> {"route", r} end)

    msg = Message.request(method, st.remote_target || st.invite.msg.uri, headers)
    st = transmit(st, msg, seq, method)
    st = if method == "BYE", do: %{st | ended: true}, else: st
    {{:ok, "#{method} within the dialog"}, st}
  end

  defp do_ack(st) do
    case st.inv_2xx do
      nil ->
        {{:error, "no 2xx response to INVITE to acknowledge"}, st}

      resp ->
        {seq, _} = resp |> Message.header("cseq") |> Message.parse_cseq()

        headers =
          [
            {"via", via(st, new_branch())},
            {"max-forwards", "70"},
            {"from", st.from_hdr},
            {"to", Message.header(resp, "to")},
            {"call-id", st.call_id},
            {"cseq", "#{seq} ACK"}
          ] ++ Enum.map(st.route_set, fn r -> {"route", r} end)

        ack = Message.request("ACK", st.remote_target || st.invite.msg.uri, headers)
        send_msg(st, ack, {st.ip, st.port})
        {{:ok, "ACK sent"}, %{st | ack_msg: ack}}
    end
  end

  ## ------------------------------------------------------------------
  ## auth (RFC 3261 22.2)

  defp do_auth(st, wrong) do
    resp = st.last_resp

    cond do
      resp == nil or resp.status not in [401, 407] ->
        # nothing to answer: hand the response back to the next `expect`
        st = if resp != nil, do: %{st | inbox: [resp | st.inbox]}, else: st
        {{:ok, "no challenge, nothing to do"}, st}

      st.p.password == "" and not wrong ->
        {{:error, "the server wants credentials but no password is set (Advanced settings)"}, st}

      true ->
        {_, method} = resp |> Message.header("cseq") |> Message.parse_cseq()
        {name, hname} =
          if resp.status == 407,
            do: {"proxy-authenticate", "proxy-authorization"},
            else: {"www-authenticate", "authorization"}

        params =
          resp
          |> Message.headers(name)
          |> Enum.map(&Digest.parse_challenge/1)
          |> Enum.find(&Digest.usable?/1)

        case {params, Map.get(st.reqs, method)} do
          {nil, _} ->
            {{:error, "no usable digest challenge (only MD5 is supported)"}, st}

          {_, nil} ->
            {{:error, "cannot find the request to repeat"}, st}

          {params, old} ->
            user = if st.p.auth_user != "", do: st.p.auth_user, else: st.p.from_user
            pass = if wrong, do: "definitely-wrong-password", else: st.p.password
            value = Digest.authorization(params, user, pass, method, old.uri)
            resend_with_auth(st, old, method, {hname, value}, wrong)
        end
    end
  end

  defp resend_with_auth(st, old, method, {hname, value}, wrong) do
    seq = st.cseq + 1
    branch = new_branch()

    headers =
      old.headers
      |> Enum.reject(fn {k, _} -> k in ["authorization", "proxy-authorization"] end)
      |> List.keyreplace("via", 0, {"via", via(st, branch)})
      |> List.keyreplace("cseq", 0, {"cseq", "#{seq} #{method}"})

    msg = %{old | headers: headers ++ [{hname, value}]}

    st =
      if method == "INVITE" do
        %{
          st
          | invite: %{msg: msg, branch: branch, seq: seq},
            invites: Map.put(st.invites, seq, msg),
            invite_pending: true
        }
      else
        st
      end

    note = if wrong, do: " (deliberately wrong password)", else: ""
    {{:ok, "repeated #{method} with #{hname}#{note}"}, transmit(st, msg, seq, method)}
  end

  ## ------------------------------------------------------------------
  ## expect

  defp do_expect(st, s) do
    method = s.method || st.last_method

    if method == nil do
      {{:error, "no request has been sent yet"}, st}
    else
      timeout = timeout_ms(st, s.timeout)
      wanted = Enum.join(s.codes, "/")

      check = fn st ->
        case scan_inbox(st.inbox, [], s.codes, method) do
          {:match, m, inbox} -> {:done, {:match, m}, %{st | inbox: inbox}}
          {:mismatch, m, inbox} -> {:done, {:mismatch, m}, %{st | inbox: inbox}}
          {:none, inbox} -> {:wait, %{st | inbox: inbox}}
        end
      end

      case await(st, now() + timeout, check) do
        {{:match, m}, st2} ->
          {{:ok, "#{m.status} #{m.reason}"}, %{st2 | last_resp: m}}

        {{:mismatch, m}, st2} ->
          {{:error, "expected #{wanted} to #{method}, got #{m.status} #{m.reason}"}, %{st2 | last_resp: m}}

        {:timeout, st2} ->
          {{:error,
            "no #{wanted} to #{method} within #{timeout} ms (received: #{history_text(st2)})"}, st2}
      end
    end
  end

  # Responses to `method`: matching code -> :match; other final -> :mismatch; other 1xx are skipped.
  defp scan_inbox([], acc, _codes, _method), do: {:none, Enum.reverse(acc)}

  defp scan_inbox([m | rest], acc, codes, method) do
    {_, m_method} = m |> Message.header("cseq") |> Message.parse_cseq()

    cond do
      m_method != method -> scan_inbox(rest, [m | acc], codes, method)
      m.status in codes -> {:match, m, Enum.reverse(acc) ++ rest}
      m.status < 200 -> scan_inbox(rest, acc, codes, method)
      true -> {:mismatch, m, Enum.reverse(acc) ++ rest}
    end
  end

  defp do_expect_request(st, s) do
    timeout = timeout_ms(st, s.timeout)

    check = fn st ->
      case Enum.find_index(st.reqs_in, fn r -> r.method == s.method end) do
        nil ->
          {:wait, st}

        i ->
          {r, rest} = List.pop_at(st.reqs_in, i)
          {:done, r, %{st | reqs_in: rest}}
      end
    end

    case await(st, now() + timeout, check) do
      {:timeout, st2} ->
        {{:error, "no incoming #{s.method} within #{timeout} ms"}, st2}

      {req, st2} ->
        {{:ok, "received #{req.method} from the phone and answered it"}, st2}
    end
  end

  defp history_text(st) do
    case st.history do
      [] -> "nothing"
      h -> h |> Enum.take(8) |> Enum.reverse() |> Enum.join(", ")
    end
  end

  defp timeout_ms(st, nil), do: st.p.timeout
  defp timeout_ms(st, :ring), do: st.p.ring_timeout
  defp timeout_ms(_st, n), do: n

  ## ------------------------------------------------------------------
  ## Receiving

  defp await(st, deadline, check) do
    case check.(st) do
      {:done, result, st2} ->
        {result, st2}

      {:wait, st2} ->
        remaining = deadline - now()

        if remaining <= 0 do
          {:timeout, st2}
        else
          case pump(st2, remaining) do
            {:ok, st3} -> await(st3, deadline, check)
            :timeout -> {:timeout, st2}
          end
        end
    end
  end

  defp pump_until(st, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      st
    else
      case pump(st, remaining) do
        {:ok, st2} -> pump_until(st2, deadline)
        :timeout -> st
      end
    end
  end

  defp pump(st, timeout_ms) do
    sock = st.sock

    receive do
      {:udp, ^sock, ip, port, data} -> {:ok, handle_datagram(st, data, {ip, port})}
      :stop_run -> throw({:stopped, st})
    after
      max(timeout_ms, 0) -> :timeout
    end
  end

  defp flush_udp do
    receive do
      {:udp, _, _, _, _} -> flush_udp()
    after
      0 -> :ok
    end
  end

  defp handle_datagram(st, data, src) do
    trace(st, "in", src, data)

    case Message.parse(data) do
      {:ok, %{type: :response} = msg} -> handle_response(st, msg)
      {:ok, %{type: :request} = req} -> handle_request(st, req, src)
      _ -> st
    end
  end

  defp handle_response(st, msg) do
    call_id = Message.header(msg, "call-id")
    {seq, method} = msg |> Message.header("cseq") |> Message.parse_cseq()

    if MapSet.member?(st.call_ids, call_id) do
      process_response(st, msg, {call_id, seq, method})
    else
      st
    end
  end

  defp process_response(st, msg, {_call_id, seq, method} = key) do
    duplicate = msg.status >= 200 and MapSet.member?(st.finals, key)

    cond do
      duplicate ->
        redo_ack(st, msg, seq, method)

      true ->
        st = %{st | history: ["#{msg.status} #{method}" | st.history], inbox: st.inbox ++ [msg]}
        st = if msg.status >= 200, do: %{st | finals: MapSet.put(st.finals, key)}, else: st
        if method == "INVITE", do: invite_response(st, msg, seq), else: st
    end
  end

  defp invite_response(st, msg, seq) do
    current? = st.invite != nil and seq == st.invite.seq

    cond do
      msg.status < 200 ->
        st

      msg.status < 300 ->
        if current? do
          target = msg |> Message.header("contact") |> Message.addr_uri()

          %{
            st
            | invite_pending: false,
              inv_2xx: msg,
              remote_target: if(target in [nil, ""], do: nil, else: target),
              route_set: msg |> Message.headers("record-route") |> Enum.reverse()
          }
        else
          st
        end

      true ->
        st = if current?, do: %{st | invite_pending: false}, else: st
        auto_ack(st, msg, seq)
    end
  end

  defp redo_ack(st, msg, seq, "INVITE") do
    cond do
      msg.status >= 300 -> auto_ack(st, msg, seq)
      st.ack_msg != nil -> send_msg(st, st.ack_msg, {st.ip, st.port}) && st
      true -> st
    end
  end

  defp redo_ack(st, _msg, _seq, _method), do: st

  # ACK for a final non-2xx response: same branch as the INVITE, To from the response (17.1.1.3)
  defp auto_ack(st, resp, seq) do
    case Map.get(st.invites, seq) do
      nil ->
        st

      inv ->
        headers =
          [
            {"via", hd(Message.headers(inv, "via"))},
            {"max-forwards", "70"},
            {"from", Message.header(inv, "from")},
            {"to", Message.header(resp, "to")},
            {"call-id", Message.header(inv, "call-id")},
            {"cseq", "#{seq} ACK"}
          ] ++ for({"route", r} <- inv.headers, do: {"route", r})

        send_msg(st, Message.request("ACK", inv.uri, headers), {st.ip, st.port})
        st
    end
  end

  defp handle_request(st, req, src) do
    st = %{st | reqs_in: st.reqs_in ++ [req]}

    case req.method do
      "ACK" ->
        st

      "BYE" ->
        reply(st, req, src, 200, "OK", [])
        %{st | ended: true}

      m when m in @in_ok ->
        reply(st, req, src, 200, "OK", [{"allow", @allow}])
        st

      "INVITE" ->
        reply(st, req, src, 488, "Not Acceptable Here", [])
        st

      "CANCEL" ->
        reply(st, req, src, 481, "Call/Transaction Does Not Exist", [])
        st

      _ ->
        reply(st, req, src, 501, "Not Implemented", [])
        st
    end
  end

  defp reply(st, req, src, code, reason, headers) do
    resp = Message.response(req, code, reason, to_tag: rand_hex(5), src: src, headers: headers)
    send_msg(st, resp, src)
  end

  ## ------------------------------------------------------------------
  ## Cleanup: leave the phone idle

  defp cleanup(st) do
    cond do
      st.inv_2xx != nil and not st.ended ->
        {_, st} = dialog_send(st, "BYE", %{})
        pump_until(st, now() + 1_000)

      st.invite_pending ->
        {_, st} = do_send(st, "CANCEL", %{})
        pump_until(st, now() + 1_000)

      true ->
        st
    end
  end

  ## ------------------------------------------------------------------
  ## Sending helpers

  defp transmit(st, msg, seq, method) do
    send_msg(st, msg, {st.ip, st.port})

    %{
      st
      | cseq: max(st.cseq, seq),
        reqs: Map.put(st.reqs, method, msg),
        call_ids: MapSet.put(st.call_ids, Message.header(msg, "call-id")),
        last_method: method
    }
  end

  defp send_msg(st, msg, {ip, port} = dest) do
    bin = Message.serialize(msg)
    :gen_udp.send(st.sock, ip, port, bin)
    trace(st, "out", dest, bin)
    :ok
  end

  defp trace(st, dir, {ip, port}, data) do
    text = if String.valid?(data), do: data, else: inspect(data)

    st.emit.(%{
      type: "trace",
      dir: dir,
      remote: "#{:inet.ntoa(ip)}:#{port}",
      ts: now(),
      text: text
    })
  end

  defp sdp_body(_st, "none"), do: ""
  defp sdp_body(_st, "bad"), do: "v=0\r\ns=-\r\nm=audio notaport RTP/AVP\r\n"

  defp sdp_body(st, _) do
    SDP.build(%{
      ip: st.local_host,
      port: st.p.rtp_port,
      payloads: [0, 8],
      te_pt: 101,
      sess_id: :rand.uniform(1_000_000_000),
      direction: "sendrecv"
    })
  end

  defp domain(st) do
    cond do
      st.p.domain != "" -> st.p.domain
      st.p.port == 5060 -> st.p.host
      true -> "#{st.p.host}:#{st.p.port}"
    end
  end

  defp aor(st), do: "sip:#{st.p.from_user}@#{domain(st)}"
  defp display(st), do: if(st.p.display != "", do: "\"#{st.p.display}\" ", else: "")
  defp contact(st), do: "<sip:#{st.p.from_user}@#{st.local_host}:#{st.local_port}>"
  defp via(st, branch), do: "SIP/2.0/UDP #{st.local_host}:#{st.local_port};rport;branch=#{branch}"

  defp to_int(nil, default), do: default

  defp to_int(s, default) do
    case Integer.parse(s) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp rand_hex(n), do: n |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp new_branch, do: "z9hG4bK" <> rand_hex(6)
  defp new_call_id(st), do: rand_hex(10) <> "@" <> st.local_host
end
