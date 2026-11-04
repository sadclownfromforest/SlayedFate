defmodule SipPhone.Account do
  @moduledoc """
  One SIP user agent (RFC 3261) bound to its own UDP port.

  Implements over UDP: REGISTER with digest authentication and refresh,
  INVITE / CANCEL / ACK / BYE as both UAC and UAS, re-INVITE answering,
  OPTIONS and NOTIFY replies, client and server transactions with the T1/T2
  retransmission timers (sections 17.1 and 17.2), and 2xx retransmission
  until ACK (section 13.3.1.4).
  """
  use GenServer
  require Logger

  alias SipPhone.SIP.{Digest, Message, SDP}
  alias SipPhone.{Events, Media}

  @t1 500
  @t2 4_000
  @tx_timeout 32_000
  @allow "INVITE, ACK, CANCEL, BYE, OPTIONS, NOTIFY"
  @ua "SipPhone-Elixir/0.1"

  ## ------------------------------------------------------------------
  ## Public API

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: via(cfg.id))
  def via(id), do: {:via, Registry, {SipPhone.AccountReg, id}}

  def snapshot(id), do: safe_call(id, :snapshot)
  def call(id, target), do: safe_call(id, {:call, target})
  def answer(id, call_id), do: safe_call(id, {:answer, call_id})
  def hangup(id, call_id), do: safe_call(id, {:hangup, call_id})
  def dtmf(id, call_id, digit), do: safe_call(id, {:dtmf, call_id, digit})
  def reregister(id), do: safe_call(id, :reregister)

  defp safe_call(id, msg) do
    GenServer.call(via(id), msg, 15_000)
  catch
    :exit, _ -> {:error, "account is not running"}
  end

  ## ------------------------------------------------------------------
  ## Lifecycle

  @impl true
  def init(cfg) do
    Process.flag(:trap_exit, true)

    st = %{
      cfg: cfg,
      sock: nil,
      bind_error: nil,
      reg: :idle,
      reg_error: nil,
      reg_call_id: nil,
      reg_tag: tag(),
      reg_cseq: 0,
      reg_host: nil,
      reg_auth_tried: false,
      reg_timer: nil,
      reg_expires: 0,
      txs: %{},
      stxs: %{},
      calls: %{}
    }

    {:ok, st, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, st) do
    case :gen_udp.open(st.cfg.local_port, [:binary, active: true, ip: {0, 0, 0, 0}]) do
      {:ok, sock} ->
        st = %{st | sock: sock}

        st =
          if registering?(st.cfg),
            do: do_register(st, st.cfg.expires),
            else: %{st | reg: :local}

        notify(st)
        {:noreply, st}

      {:error, reason} ->
        st = %{
          st
          | bind_error: "Cannot open UDP port #{st.cfg.local_port}: #{inspect(reason)}",
            reg: :failed
        }

        notify(st)
        {:noreply, st}
    end
  end

  @impl true
  def terminate(_reason, st) do
    try do
      if st.sock do
        Enum.each(st.calls, fn {_, c} -> if c.state == :established, do: send_bye(st, c) end)
        if st.reg == :registered, do: do_register(st, 0)
        :gen_udp.close(st.sock)
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  ## ------------------------------------------------------------------
  ## Calls from the UI

  @impl true
  def handle_call(:snapshot, _from, st), do: {:reply, public(st), st}

  def handle_call({:call, target}, _from, st) do
    guarded(st, fn ->
      case start_call(st, target) do
        {:ok, st2, cid} -> {{:ok, cid}, st2}
        {:error, msg} -> {{:error, msg}, st}
      end
    end)
  end

  def handle_call({:answer, cid}, _from, st) do
    guarded(st, fn ->
      case Map.get(st.calls, cid) do
        %{dir: :in, state: :ringing} = call ->
          case do_answer(st, call) do
            {:ok, st2} -> {:ok, st2}
            {:error, msg} -> {{:error, msg}, st}
          end

        _ ->
          {{:error, "no incoming call to answer"}, st}
      end
    end)
  end

  def handle_call({:hangup, cid}, _from, st) do
    guarded(st, fn ->
      case Map.get(st.calls, cid) do
        nil -> {{:error, "no such call"}, st}
        call -> {:ok, do_hangup(st, call)}
      end
    end)
  end

  def handle_call({:dtmf, cid, digit}, _from, st) do
    case Map.get(st.calls, cid) do
      %{state: :established, media: media} when media != nil ->
        Media.dtmf(media, digit)
        {:reply, :ok, st}

      _ ->
        {:reply, {:error, "call is not connected"}, st}
    end
  end

  def handle_call(:reregister, _from, st) do
    if registering?(st.cfg) and st.sock != nil do
      st = cancel_reg_timer(st)
      st = do_register(%{st | reg_auth_tried: false}, st.cfg.expires)
      notify(st)
      {:reply, :ok, st}
    else
      {:reply, {:error, "this account has no registrar"}, st}
    end
  end

  defp guarded(st, fun) do
    {reply, st2} = fun.()
    {:reply, reply, st2}
  rescue
    e ->
      Logger.error("account #{st.cfg.id}: " <> Exception.format(:error, e, __STACKTRACE__))
      {:reply, {:error, "internal error"}, st}
  end

  ## ------------------------------------------------------------------
  ## Messages from the network and timers

  @impl true
  def handle_info({:udp, _sock, ip, port, data}, st) do
    st = safely(st, fn -> receive_datagram(st, data, {ip, port}) end)
    {:noreply, st}
  end

  def handle_info(:reg_refresh, st) do
    st = %{st | reg_timer: nil}

    st =
      if st.sock != nil and registering?(st.cfg),
        do: do_register(%{st | reg_auth_tried: false}, st.cfg.expires),
        else: st

    {:noreply, st}
  end

  def handle_info({:tx_retx, key}, st) do
    st =
      case Map.get(st.txs, key) do
        %{state: s} = tx when s in [:trying, :proceeding] ->
          if tx.kind == :invite and s == :proceeding do
            st
          else
            send_raw(st, tx.bin, tx.dest)

            interval =
              cond do
                tx.kind == :invite -> tx.interval * 2
                s == :proceeding -> @t2
                true -> min(tx.interval * 2, @t2)
              end

            retx = Process.send_after(self(), {:tx_retx, key}, interval)
            %{st | txs: Map.put(st.txs, key, %{tx | interval: interval, retx: retx})}
          end

        _ ->
          st
      end

    {:noreply, st}
  end

  def handle_info({:tx_timeout, key}, st) do
    st =
      case Map.pop(st.txs, key) do
        {nil, _} ->
          st

        {tx, txs} ->
          st = %{st | txs: txs}
          if tx.state in [:trying, :proceeding], do: on_tx_timeout(st, tx.ctx), else: st
      end

    {:noreply, st}
  end

  def handle_info({:tx_done, key}, st), do: {:noreply, %{st | txs: Map.delete(st.txs, key)}}

  def handle_info({:stx_expire, key}, st), do: {:noreply, %{st | stxs: Map.delete(st.stxs, key)}}

  def handle_info({:stx_g, key, interval}, st) do
    case Map.get(st.stxs, key) do
      %{state: :completed, bin: bin, dest: dest} ->
        send_raw(st, bin, dest)
        next = min(interval * 2, @t2)
        Process.send_after(self(), {:stx_g, key, next}, next)

      _ ->
        :ok
    end

    {:noreply, st}
  end

  def handle_info({:resend_2xx, cid, interval}, st) do
    st =
      case Map.get(st.calls, cid) do
        %{acked: false, final_bin: bin} = call when bin != nil ->
          elapsed = call.resend_ms + interval

          if elapsed >= @tx_timeout do
            st = send_bye(st, call)
            end_call(st, call, "no ACK received")
          else
            send_raw(st, bin, resp_dest(call.invite_req, call.invite_src))
            nxt = min(interval * 2, @t2)
            Process.send_after(self(), {:resend_2xx, cid, nxt}, nxt)
            put_call(st, %{call | resend_ms: elapsed})
          end

        _ ->
          st
      end

    {:noreply, st}
  end

  def handle_info(_other, st), do: {:noreply, st}

  defp safely(st, fun) do
    fun.()
  rescue
    e ->
      Logger.error("account #{st.cfg.id}: " <> Exception.format(:error, e, __STACKTRACE__))
      st
  end

  defp receive_datagram(st, data, src) do
    case Message.parse(data) do
      {:ok, msg} ->
        log(st, :in, src, data)

        case msg.type do
          :request -> handle_request(st, msg, src)
          :response -> handle_response(st, msg)
        end

      :error ->
        st
    end
  end

  ## ------------------------------------------------------------------
  ## Registration (RFC 3261 section 10)

  defp registering?(cfg), do: cfg.register and cfg.registrar != ""

  defp do_register(st, expires, auth \\ []) do
    cfg = st.cfg
    {rhost, rport} = parse_hostport(proxy_or_registrar(cfg), 5060)

    case resolve(rhost, rport) do
      {:ok, {ip, _} = dest} ->
        host = contact_host(cfg, ip)
        domain = domain(cfg, host)
        call_id = st.reg_call_id || new_call_id(host)
        cseq = st.reg_cseq + 1
        branch = new_branch()
        from_uri = "sip:#{cfg.username}@#{domain}"

        headers =
          [
            {"via", via(host, cfg.local_port, branch)},
            {"max-forwards", "70"},
            {"from", "#{display(cfg)}<#{from_uri}>;tag=#{st.reg_tag}"},
            {"to", "<#{from_uri}>"},
            {"call-id", call_id},
            {"cseq", "#{cseq} REGISTER"},
            {"contact", "<sip:#{cfg.username}@#{host}:#{cfg.local_port}>;expires=#{expires}"},
            {"expires", Integer.to_string(expires)},
            {"user-agent", @ua},
            {"allow", @allow}
          ] ++ auth

        bin = "sip:#{domain}" |> then(&Message.request("REGISTER", &1, headers)) |> Message.serialize()

        st = %{
          st
          | reg_call_id: call_id,
            reg_cseq: cseq,
            reg_host: host,
            reg: if(st.reg == :registered, do: :registered, else: :registering)
        }

        start_tx(st, :non_invite, "REGISTER", branch, bin, dest, {:register, expires})

      {:error, why} ->
        fail_reg(st, "Cannot resolve registrar: #{inspect(why)}", 30_000)
    end
  end

  defp on_register_response(st, msg, expires_req) do
    code = msg.status
    cfg = st.cfg

    cond do
      code >= 200 and code < 300 ->
        st = cancel_reg_timer(st)

        if expires_req == 0 do
          st = %{st | reg: :unregistered, reg_error: nil}
          notify(st)
          st
        else
          granted = granted_expires(msg, st, expires_req)
          delay = max(div(granted * 800, 1), 15_000)
          timer = Process.send_after(self(), :reg_refresh, delay)

          st = %{
            st
            | reg: :registered,
              reg_error: nil,
              reg_auth_tried: false,
              reg_timer: timer,
              reg_expires: granted
          }

          notify(st)
          st
        end

      code in [401, 407] and not st.reg_auth_tried ->
        uri = "sip:#{domain(cfg, st.reg_host || "")}"

        case auth_header(st, msg, "REGISTER", uri) do
          {:ok, hdr} -> do_register(%{st | reg_auth_tried: true}, expires_req, [hdr])
          :error -> fail_reg(st, "Server requires an unsupported authentication scheme", 120_000)
        end

      code in [401, 407] ->
        fail_reg(st, "Authentication failed - check username and password", 120_000)

      code == 423 and expires_req > 0 ->
        min = parse_int(Message.header(msg, "min-expires"), expires_req)
        do_register(st, max(min, expires_req))

      true ->
        fail_reg(st, "Registration failed: #{code} #{msg.reason}", 60_000)
    end
  end

  defp fail_reg(st, text, retry_ms) do
    st = cancel_reg_timer(st)
    timer = Process.send_after(self(), :reg_refresh, retry_ms)
    st = %{st | reg: :failed, reg_error: text, reg_timer: timer}
    notify(st)
    st
  end

  defp cancel_reg_timer(st) do
    cancel(st.reg_timer)
    %{st | reg_timer: nil}
  end

  defp granted_expires(msg, st, requested) do
    mine = "#{st.cfg.username}@#{st.reg_host}:#{st.cfg.local_port}"
    contacts = Message.headers(msg, "contact")
    own = Enum.find(contacts, fn c -> String.contains?(c, mine) end) || List.first(contacts)
    from_contact = Message.param(own, "expires")

    cond do
      from_contact not in [nil, ""] -> parse_int(from_contact, requested)
      Message.header(msg, "expires") != nil -> parse_int(Message.header(msg, "expires"), requested)
      true -> requested
    end
  end

  defp auth_header(st, msg, method, uri) do
    {chal_name, resp_name} =
      if msg.status == 407,
        do: {"proxy-authenticate", "proxy-authorization"},
        else: {"www-authenticate", "authorization"}

    params =
      msg
      |> Message.headers(chal_name)
      |> Enum.map(&Digest.parse_challenge/1)
      |> Enum.find(&Digest.usable?/1)

    case params do
      nil ->
        :error

      p ->
        cfg = st.cfg
        user = if cfg.auth_user != "", do: cfg.auth_user, else: cfg.username
        {:ok, {resp_name, Digest.authorization(p, user, cfg.password, method, uri)}}
    end
  end

  ## ------------------------------------------------------------------
  ## Client transactions (RFC 3261 section 17.1)

  defp start_tx(st, kind, method, branch, bin, dest, ctx) do
    send_raw(st, bin, dest)
    key = {branch, method}

    tx = %{
      kind: kind,
      method: method,
      bin: bin,
      dest: dest,
      ctx: ctx,
      state: :trying,
      interval: @t1,
      retx: Process.send_after(self(), {:tx_retx, key}, @t1),
      tmo: Process.send_after(self(), {:tx_timeout, key}, 64 * @t1),
      ack: nil
    }

    %{st | txs: Map.put(st.txs, key, tx)}
  end

  defp on_tx_timeout(st, {:register, _}),
    do: fail_reg(st, "No response from registrar (timeout)", 30_000)

  defp on_tx_timeout(st, {:invite, cid}) do
    case Map.get(st.calls, cid) do
      nil -> st
      call -> end_call(st, call, "No response (timeout)")
    end
  end

  defp on_tx_timeout(st, _ctx), do: st

  defp handle_response(st, msg) do
    via = msg |> Message.header("via") |> Message.parse_via()
    {_, method} = msg |> Message.header("cseq") |> Message.parse_cseq()
    key = {via && via.branch, method}

    case Map.get(st.txs, key) do
      nil -> stray_response(st, msg, method)
      tx -> process_response(st, key, tx, msg)
    end
  end

  defp process_response(st, key, tx, msg) do
    code = msg.status

    cond do
      code < 200 ->
        if tx.kind == :invite, do: cancel(tx.retx)
        tx = %{tx | state: :proceeding, retx: if(tx.kind == :invite, do: nil, else: tx.retx)}
        st = %{st | txs: Map.put(st.txs, key, tx)}
        dispatch_response(st, tx.ctx, msg)

      tx.state == :completed ->
        if tx.ack, do: send_raw(st, tx.ack, tx.dest)
        st

      tx.kind == :invite and code >= 300 ->
        cancel(tx.retx)
        cancel(tx.tmo)
        {:invite, cid} = tx.ctx

        ack =
          case Map.get(st.calls, cid) do
            nil -> nil
            call -> build_ack_non2xx(st, call, msg)
          end

        if ack, do: send_raw(st, ack, tx.dest)
        done = Process.send_after(self(), {:tx_done, key}, @tx_timeout)
        tx = %{tx | state: :completed, ack: ack, retx: nil, tmo: done}
        st = %{st | txs: Map.put(st.txs, key, tx)}
        dispatch_response(st, tx.ctx, msg)

      true ->
        cancel(tx.retx)
        cancel(tx.tmo)
        st = %{st | txs: Map.delete(st.txs, key)}
        dispatch_response(st, tx.ctx, msg)
    end
  end

  defp dispatch_response(st, {:register, exp}, msg) do
    if msg.status >= 200, do: on_register_response(st, msg, exp), else: st
  end

  defp dispatch_response(st, {:invite, cid}, msg), do: on_invite_response(st, cid, msg)
  defp dispatch_response(st, _ctx, _msg), do: st

  # A retransmitted 2xx to INVITE whose transaction is gone: ACK again (13.2.2.4).
  defp stray_response(st, msg, "INVITE") when msg.status >= 200 and msg.status < 300 do
    case Map.get(st.calls, Message.header(msg, "call-id")) do
      %{state: :established} = call -> send_ack_2xx(st, call)
      _ -> st
    end
  end

  defp stray_response(st, _msg, _method), do: st

  ## ------------------------------------------------------------------
  ## Outgoing calls (UAC)

  defp start_call(st, target) do
    cfg = st.cfg

    with true <- st.sock != nil or {:error, "SIP port is not open"},
         {:ok, uri} <- build_target_uri(cfg, target),
         {:ok, {ip, _} = dest} <- route_dest(cfg, uri) do
      host = contact_host(cfg, ip)
      call_id = new_call_id(host)
      codec = hd(SDP.codec_order(cfg.prefer_codec))

      case Media.start_link(%{call_id: call_id, codec: codec}) do
        {:ok, media} ->
          {:ok, send_invite(st, uri, dest, host, call_id, codec, media)}

        {:error, reason} ->
          {:error, "No free RTP port (#{inspect(reason)})"}
      end
    else
      {:error, msg} -> {:error, msg}
      false -> {:error, "SIP port is not open"}
    end
  end

  defp send_invite(st, uri, dest, host, call_id, codec, media) do
    cfg = st.cfg
    branch = new_branch()
    local_tag = tag()
    domain = domain(cfg, host)
    from_uri = "sip:#{cfg.username}@#{domain}"
    local_hdr = "#{display(cfg)}<#{from_uri}>;tag=#{local_tag}"
    sess = sess_id()

    sdp =
      SDP.build(%{
        ip: host,
        port: Media.local_port(media),
        payloads: SDP.codec_order(cfg.prefer_codec),
        te_pt: 101,
        sess_id: sess,
        direction: "sendrecv"
      })

    route =
      if cfg.outbound_proxy != "" do
        {ph, pp} = parse_hostport(cfg.outbound_proxy, 5060)
        [{"route", "<sip:#{ph}:#{pp};lr>"}]
      else
        []
      end

    headers =
      [
        {"via", via(host, cfg.local_port, branch)},
        {"max-forwards", "70"},
        {"from", local_hdr},
        {"to", "<#{uri}>"},
        {"call-id", call_id},
        {"cseq", "1 INVITE"},
        {"contact", "<sip:#{cfg.username}@#{host}:#{cfg.local_port}>"},
        {"user-agent", @ua},
        {"allow", @allow},
        {"content-type", "application/sdp"}
      ] ++ route

    msg = Message.request("INVITE", uri, headers, sdp)

    call = %{
      base_call(call_id, :out)
      | state: :calling,
        remote_label: label_from_uri(uri),
        remote_uri: uri,
        remote_target: uri,
        local_tag: local_tag,
        local_hdr: local_hdr,
        local_seq: 1,
        branch: branch,
        host: host,
        dest: dest,
        media: media,
        codec: codec,
        te_pt: 101,
        sess_id: sess,
        invite_msg: msg
    }

    st = put_call(st, call)
    emit_call(st, call)
    start_tx(st, :invite, "INVITE", branch, Message.serialize(msg), dest, {:invite, call_id})
  end

  defp on_invite_response(st, cid, msg) do
    case Map.get(st.calls, cid) do
      nil -> st
      call -> on_invite_response(st, call, msg, msg.status)
    end
  end

  defp on_invite_response(st, call, msg, code) when code < 200 do
    call = learn_remote(call, msg)

    call =
      if code > 100 and call.state == :calling, do: %{call | state: :ringing}, else: call

    call = if code > 100 or code == 100, do: %{call | got_prov: true}, else: call
    if code in [180, 183] or call.state == :ringing, do: apply_answer_sdp(call, msg)
    st = put_call(st, call)
    emit_call(st, call)
    try_cancel(st, call)
  end

  defp on_invite_response(st, call, msg, code) when code < 300 do
    call = learn_remote(call, msg)
    route_set = msg |> Message.headers("record-route") |> Enum.reverse()
    target = msg |> Message.header("contact") |> Message.addr_uri()
    target = if target in [nil, ""], do: call.remote_uri, else: target
    next_hop = if route_set == [], do: target, else: Message.addr_uri(hd(route_set))

    call = %{
      call
      | route_set: route_set,
        remote_target: target,
        target_dest: dest_for(next_hop, call.dest),
        remote_hdr: call.remote_hdr || Message.header(msg, "to")
    }

    st = send_ack_2xx(st, call)

    if call.state == :cancelling do
      # Our CANCEL crossed the 200 OK: the call is up, so tear it down with BYE.
      st = send_bye(st, call)
      end_call(st, call, "cancelled")
    else
      apply_answer_sdp(call, msg)
      call = %{call | state: :established, connected_at: now_ms(), acked: true}
      st = put_call(st, call)
      emit_call(st, call)
      st
    end
  end

  defp on_invite_response(st, call, msg, code) do
    Logger.info("account #{st.cfg.id} call #{short(call.id)}: INVITE answered #{code} #{msg.reason}")

    # RFC 3261 22.2: answer a 401/407 challenge once; once more only if the server says the nonce is stale.
    retry? = code in [401, 407] and (not call.auth_tried or (stale_challenge?(msg) and not call.stale_tried))

    if retry? do
      case invite_auth(st, call, msg, code) do
        {:ok, hdr} -> reinvite_with_auth(st, call, hdr)
        {:error, why} -> end_call(st, call, why)
      end
    else
      reason =
        cond do
          call.state == :cancelling and code == 487 -> "cancelled"
          code in [401, 407] -> "#{code} #{msg.reason} - the server rejected our credentials (check user name / password)"
          true -> "#{code} #{msg.reason}"
        end

      end_call(st, call, reason)
    end
  end

  defp invite_auth(st, call, msg, code) do
    cfg = st.cfg
    user = if cfg.auth_user != "", do: cfg.auth_user, else: cfg.username

    cond do
      cfg.password == "" ->
        Logger.warning("account #{cfg.id}: INVITE challenged (#{code}) but the account has no password")
        {:error, "#{code} #{msg.reason} - this account has no password to answer the challenge"}

      true ->
        case auth_header(st, msg, "INVITE", call.invite_msg.uri) do
          {:ok, {hname, _} = hdr} ->
            Logger.info("account #{cfg.id} call #{short(call.id)}: answering #{code} challenge as '#{user}' (#{hname})")
            {:ok, hdr}

          :error ->
            offered = msg |> Message.headers(if(code == 407, do: "proxy-authenticate", else: "www-authenticate")) |> Enum.join(" | ")
            Logger.warning("account #{cfg.id}: no usable digest challenge in #{code}: #{offered}")
            {:error, "Unsupported authentication (#{code})"}
        end
    end
  end

  defp stale_challenge?(msg) do
    (Message.headers(msg, "www-authenticate") ++ Message.headers(msg, "proxy-authenticate"))
    |> Enum.any?(&Regex.match?(~r/stale\s*=\s*"?true/i, &1))
  end

  defp short(id), do: id |> to_string() |> String.slice(0, 12)

  defp reinvite_with_auth(st, call, {hname, hvalue}) do
    branch = new_branch()
    seq = call.local_seq + 1
    inv = call.invite_msg

    headers =
      inv.headers
      |> List.keyreplace("via", 0, {"via", via(call.host, st.cfg.local_port, branch)})
      |> List.keyreplace("cseq", 0, {"cseq", "#{seq} INVITE"})
      |> Enum.reject(fn {k, _} -> k in ["authorization", "proxy-authorization"] end)

    msg = %{inv | headers: headers ++ [{hname, hvalue}]}
    call = %{
      call
      | auth_tried: true,
        stale_tried: call.auth_tried,
        branch: branch,
        local_seq: seq,
        invite_msg: msg,
        got_prov: false
    }

    Logger.info("account #{st.cfg.id} call #{short(call.id)}: re-sending INVITE with credentials (CSeq #{seq})")
    st = put_call(st, call)
    start_tx(st, :invite, "INVITE", branch, Message.serialize(msg), call.dest, {:invite, call.id})
  end

  defp learn_remote(call, msg) do
    to = Message.header(msg, "to")

    if call.remote_hdr == nil and Message.param(to, "tag") != nil do
      %{call | remote_hdr: to, remote_tag: Message.param(to, "tag")}
    else
      call
    end
  end

  defp apply_answer_sdp(call, msg) do
    if msg.body != "" and call.media != nil do
      case SDP.parse(msg.body) do
        %{ip: ip, port: port} = sdp when ip != {0, 0, 0, 0} ->
          case SDP.answer_codec(sdp) do
            nil -> :ok
            codec -> Media.set_remote(call.media, ip, port, codec, sdp.te_pt)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp try_cancel(st, %{cancel_pending: true, got_prov: true} = call) do
    st = send_cancel(st, call)
    put_call(st, %{call | cancel_pending: false})
  end

  defp try_cancel(st, _call), do: st

  defp send_cancel(st, call) do
    inv = call.invite_msg

    headers =
      [
        {"via", via(call.host, st.cfg.local_port, call.branch)},
        {"max-forwards", "70"},
        {"from", Message.header(inv, "from")},
        {"to", Message.header(inv, "to")},
        {"call-id", call.id},
        {"cseq", "#{call.local_seq} CANCEL"},
        {"user-agent", @ua}
      ] ++ for({"route", r} <- inv.headers, do: {"route", r})

    bin = "CANCEL" |> Message.request(inv.uri, headers) |> Message.serialize()
    start_tx(st, :non_invite, "CANCEL", call.branch, bin, call.dest, {:cancel, call.id})
  end

  defp build_ack_non2xx(st, call, resp) do
    inv = call.invite_msg

    headers =
      [
        {"via", via(call.host, st.cfg.local_port, call.branch)},
        {"max-forwards", "70"},
        {"from", Message.header(inv, "from")},
        {"to", Message.header(resp, "to")},
        {"call-id", call.id},
        {"cseq", "#{call.local_seq} ACK"}
      ] ++ for({"route", r} <- inv.headers, do: {"route", r})

    "ACK" |> Message.request(inv.uri, headers) |> Message.serialize()
  end

  defp send_ack_2xx(st, call) do
    msg = dialog_request(st, call, "ACK", call.local_seq, new_branch())
    send_raw(st, Message.serialize(msg), call.target_dest || call.dest)
    st
  end

  defp send_bye(st, call) do
    branch = new_branch()
    msg = dialog_request(st, call, "BYE", call.local_seq + 1, branch)

    start_tx(
      st,
      :non_invite,
      "BYE",
      branch,
      Message.serialize(msg),
      call.target_dest || call.dest,
      {:bye, call.id}
    )
  end

  defp dialog_request(st, call, method, seq, branch) do
    headers =
      [
        {"via", via(call.host, st.cfg.local_port, branch)},
        {"max-forwards", "70"},
        {"from", call.local_hdr},
        {"to", call.remote_hdr},
        {"call-id", call.id},
        {"cseq", "#{seq} #{method}"},
        {"user-agent", @ua}
      ] ++ Enum.map(call.route_set, fn r -> {"route", r} end)

    Message.request(method, call.remote_target, headers)
  end

  ## ------------------------------------------------------------------
  ## Hang up / answer

  defp do_hangup(st, %{dir: :out, state: s} = call) when s in [:calling, :ringing] do
    call = %{call | state: :cancelling, cancel_pending: true}
    st = put_call(st, call)
    emit_call(st, call)
    try_cancel(st, call)
  end

  defp do_hangup(st, %{state: :cancelling}), do: st

  defp do_hangup(st, %{dir: :in, state: :ringing} = call) do
    {st, _} =
      respond(st, call.invite_req, call.invite_src, 603, "Decline", to_tag: call.local_tag)

    end_call(st, call, "declined")
  end

  defp do_hangup(st, %{state: :established} = call) do
    st = send_bye(st, call)
    end_call(st, call, "hung up")
  end

  defp do_hangup(st, call), do: end_call(st, call, "hung up")

  defp do_answer(st, call) do
    cfg = st.cfg

    case Media.start_link(%{call_id: call.id, codec: call.codec}) do
      {:ok, media} ->
        offer = call.offer
        Media.set_remote(media, offer.ip, offer.port, call.codec, offer.te_pt)
        sess = sess_id()

        sdp =
          SDP.build(%{
            ip: call.host,
            port: Media.local_port(media),
            payloads: [call.codec],
            te_pt: offer.te_pt,
            sess_id: sess,
            direction: "sendrecv"
          })

        headers = [
          {"contact", "<sip:#{cfg.username}@#{call.host}:#{cfg.local_port}>"},
          {"allow", @allow},
          {"user-agent", @ua},
          {"content-type", "application/sdp"}
        ]

        {st, bin} =
          respond(st, call.invite_req, call.invite_src, 200, "OK",
            to_tag: call.local_tag,
            headers: headers,
            body: sdp
          )

        next_hop =
          if call.route_set == [],
            do: call.remote_target,
            else: Message.addr_uri(hd(call.route_set))

        call = %{
          call
          | state: :established,
            media: media,
            connected_at: now_ms(),
            final_bin: bin,
            te_pt: offer.te_pt,
            sess_id: sess,
            target_dest: dest_for(next_hop, call.dest)
        }

        st = put_call(st, call)
        Process.send_after(self(), {:resend_2xx, call.id, @t1}, @t1)
        emit_call(st, call)
        {:ok, st}

      {:error, reason} ->
        {:error, "No free RTP port (#{inspect(reason)})"}
    end
  end

  ## ------------------------------------------------------------------
  ## Incoming requests (UAS, RFC 3261 section 8.2 and 17.2)

  defp handle_request(st, %{method: "ACK"} = req, _src), do: handle_ack(st, req)

  defp handle_request(st, req, src) do
    key = stx_key(req)

    case Map.get(st.stxs, key) do
      %{bin: bin, dest: dest} when bin != nil ->
        # Retransmitted request: replay our last response (17.2.3).
        send_raw(st, bin, dest)
        st

      %{} ->
        st

      nil ->
        st = %{st | stxs: Map.put(st.stxs, key, %{state: :new, bin: nil, dest: nil, method: req.method})}
        dispatch_request(st, req, src)
    end
  end

  defp dispatch_request(st, %{method: "OPTIONS"} = req, src),
    do: reply(st, req, src, 200, "OK", headers: [{"allow", @allow}, {"accept", "application/sdp"}])

  defp dispatch_request(st, %{method: "NOTIFY"} = req, src), do: reply(st, req, src, 200, "OK")
  defp dispatch_request(st, %{method: "INVITE"} = req, src), do: handle_invite(st, req, src)
  defp dispatch_request(st, %{method: "BYE"} = req, src), do: handle_bye(st, req, src)
  defp dispatch_request(st, %{method: "CANCEL"} = req, src), do: handle_cancel(st, req, src)

  defp dispatch_request(st, req, src),
    do: reply(st, req, src, 405, "Method Not Allowed", headers: [{"allow", @allow}])

  defp handle_ack(st, req) do
    key = stx_key(req, "INVITE")

    case Map.get(st.stxs, key) do
      %{state: :completed} = stx ->
        %{st | stxs: Map.put(st.stxs, key, %{stx | state: :confirmed})}

      _ ->
        case Map.get(st.calls, Message.header(req, "call-id")) do
          nil -> st
          call -> put_call(st, %{call | acked: true})
        end
    end
  end

  defp handle_invite(st, req, src) do
    cid = Message.header(req, "call-id")

    cond do
      Message.to_tag(req) != nil -> handle_reinvite(st, req, src, cid)
      Map.has_key?(st.calls, cid) -> reply(st, req, src, 482, "Loop Detected")
      true -> new_incoming(st, req, src, cid)
    end
  end

  defp new_incoming(st, req, src, cid) do
    offer = if req.body == "", do: nil, else: SDP.parse(req.body)
    codec = if offer, do: SDP.choose_codec(offer, st.cfg.prefer_codec), else: nil

    if codec == nil do
      reply(st, req, src, 488, "Not Acceptable Here",
        headers: [{"warning", "399 sipphone \"G.711 audio offer required\""}]
      )
    else
      {sip, _} = src
      host = contact_host(st.cfg, sip)
      local_tag = tag()
      from_hdr = Message.header(req, "from")
      to_hdr = Message.header(req, "to")
      {cseq, _} = req |> Message.header("cseq") |> Message.parse_cseq()

      call = %{
        base_call(cid, :in)
        | state: :ringing,
          remote_label: caller_label(from_hdr),
          remote_uri: Message.addr_uri(from_hdr),
          remote_target: Message.addr_uri(Message.header(req, "contact")),
          local_tag: local_tag,
            remote_tag: Message.from_tag(req),
          local_hdr: to_hdr <> ";tag=" <> local_tag,
          remote_hdr: from_hdr,
          local_seq: 0,
          remote_seq: cseq,
          route_set: Message.headers(req, "record-route"),
          host: host,
          dest: src,
          codec: codec,
          offer: offer,
          invite_req: req,
          invite_src: src
      }

      st = put_call(st, call)

      contact = "<sip:#{st.cfg.username}@#{host}:#{st.cfg.local_port}>"
      {st, _} = respond(st, req, src, 180, "Ringing", to_tag: local_tag, headers: [{"contact", contact}])
      emit_call(st, call)

      if st.cfg.auto_answer do
        case do_answer(st, Map.fetch!(st.calls, cid)) do
          {:ok, st2} -> st2
          {:error, _} -> st
        end
      else
        st
      end
    end
  end

  defp handle_reinvite(st, req, src, cid) do
    case Map.get(st.calls, cid) do
      %{state: :established} = call ->
        offer = if req.body == "", do: nil, else: SDP.parse(req.body)

        if offer != nil and offer.ip != {0, 0, 0, 0} and call.media != nil do
          Media.set_remote(call.media, offer.ip, offer.port, call.codec, offer.te_pt || call.te_pt)
        end

        target =
          case Message.addr_uri(Message.header(req, "contact")) do
            nil -> call.remote_target
            "" -> call.remote_target
            t -> t
          end

        call = %{call | remote_target: target}
        st = put_call(st, call)

        dir =
          case offer && offer.direction do
            :sendonly -> "recvonly"
            :inactive -> "inactive"
            _ -> "sendrecv"
          end

        sdp =
          SDP.build(%{
            ip: call.host,
            port: Media.local_port(call.media),
            payloads: [call.codec],
            te_pt: call.te_pt,
            sess_id: call.sess_id,
            direction: dir
          })

        headers = [
          {"contact", "<sip:#{st.cfg.username}@#{call.host}:#{st.cfg.local_port}>"},
          {"allow", @allow},
          {"content-type", "application/sdp"}
        ]

        reply(st, req, src, 200, "OK", to_tag: call.local_tag, headers: headers, body: sdp)

      _ ->
        reply(st, req, src, 481, "Call/Transaction Does Not Exist")
    end
  end

  defp handle_bye(st, req, src) do
    case Map.get(st.calls, Message.header(req, "call-id")) do
      nil ->
        reply(st, req, src, 481, "Call/Transaction Does Not Exist")

      call ->
        st = reply(st, req, src, 200, "OK")
        end_call(st, call, "remote hung up")
    end
  end

  defp handle_cancel(st, req, src) do
    inv_key = stx_key(req, "INVITE")

    case Map.get(st.stxs, inv_key) do
      %{state: :proceeding} ->
        st = reply(st, req, src, 200, "OK")

        case Map.get(st.calls, Message.header(req, "call-id")) do
          %{dir: :in, state: :ringing} = call ->
            {st, _} =
              respond(st, call.invite_req, call.invite_src, 487, "Request Terminated",
                to_tag: call.local_tag
              )

            end_call(st, call, "missed (caller cancelled)")

          _ ->
            st
        end

      %{} ->
        reply(st, req, src, 200, "OK")

      nil ->
        reply(st, req, src, 481, "Call/Transaction Does Not Exist")
    end
  end

  ## ------------------------------------------------------------------
  ## Server transactions and responses

  defp stx_key(req, method \\ nil) do
    via = req |> Message.header("via") |> Message.parse_via()
    {via && via.branch, via && {via.host, via.port}, method || req.method}
  end

  defp reply(st, req, src, code, reason, opts \\ []) do
    {st, _bin} = respond(st, req, src, code, reason, opts)
    st
  end

  defp respond(st, req, src, code, reason, opts \\ []) do
    resp = Message.response(req, code, reason, Keyword.put(opts, :src, src))
    bin = Message.serialize(resp)
    dest = resp_dest(req, src)
    send_raw(st, bin, dest)
    {update_stx(st, stx_key(req), code, bin, dest, req.method), bin}
  end

  defp update_stx(st, key, code, bin, dest, method) do
    old = Map.get(st.stxs, key, %{})
    expiring = Map.get(old, :expiring, false)

    state =
      cond do
        code < 200 -> :proceeding
        method == "INVITE" and code >= 300 -> :completed
        method == "INVITE" -> :accepted
        true -> :done
      end

    if code >= 200 and not expiring,
      do: Process.send_after(self(), {:stx_expire, key}, @tx_timeout)

    if state == :completed, do: Process.send_after(self(), {:stx_g, key, @t1}, @t1)

    stx =
      Map.merge(old, %{
        bin: bin,
        dest: dest,
        state: state,
        method: method,
        expiring: expiring or code >= 200
      })

    %{st | stxs: Map.put(st.stxs, key, stx)}
  end

  # Where to send the response (RFC 3261 18.2.2 + RFC 3581): back to the source address.
  defp resp_dest(req, {sip, sport}) do
    via = req |> Message.header("via") |> Message.parse_via()

    port =
      cond do
        via == nil -> sport
        via.rport != nil -> sport
        via.port != nil -> via.port
        true -> 5060
      end

    {sip, port}
  end

  ## ------------------------------------------------------------------
  ## Call bookkeeping and UI events

  defp base_call(id, dir) do
    %{
      id: id,
      dir: dir,
      state: :calling,
      remote_label: "",
      remote_uri: nil,
      remote_target: nil,
      local_tag: nil,
      remote_tag: nil,
      local_hdr: nil,
      remote_hdr: nil,
      local_seq: 1,
      remote_seq: nil,
      route_set: [],
      branch: nil,
      host: nil,
      dest: nil,
      target_dest: nil,
      media: nil,
      codec: 0,
      te_pt: nil,
      sess_id: nil,
      connected_at: nil,
      reason: nil,
      cancel_pending: false,
      got_prov: false,
      auth_tried: false,
      stale_tried: false,
      acked: false,
      final_bin: nil,
      resend_ms: 0,
      invite_msg: nil,
      invite_req: nil,
      invite_src: nil,
      offer: nil
    }
  end

  defp put_call(st, call), do: %{st | calls: Map.put(st.calls, call.id, call)}

  defp end_call(st, call, reason) do
    Logger.info("account #{st.cfg.id} call #{short(call.id)}: ended (#{reason})")
    if call.media != nil, do: Media.stop(call.media)
    Events.broadcast(%{type: "call", call: call_view(st, %{call | state: :ended, reason: reason})})
    %{st | calls: Map.delete(st.calls, call.id)}
  end

  defp emit_call(st, call), do: Events.broadcast(%{type: "call", call: call_view(st, call)})

  defp call_view(st, c) do
    %{
      id: c.id,
      account_id: st.cfg.id,
      dir: Atom.to_string(c.dir),
      state: Atom.to_string(c.state),
      remote: c.remote_label,
      connected_at: c.connected_at,
      reason: c.reason
    }
  end

  defp public(st) do
    %{
      id: st.cfg.id,
      status: Atom.to_string(st.reg),
      status_text: status_text(st),
      calls: Enum.map(st.calls, fn {_, c} -> call_view(st, c) end)
    }
  end

  defp notify(st) do
    Events.broadcast(%{
      type: "account_status",
      id: st.cfg.id,
      status: Atom.to_string(st.reg),
      status_text: status_text(st)
    })
  end

  defp status_text(st) do
    cond do
      st.bind_error != nil -> st.bind_error
      st.reg == :registered -> "Registered (refresh every #{div(st.reg_expires * 8, 10)}s)"
      st.reg == :registering -> "Registering..."
      st.reg == :failed -> st.reg_error || "Registration failed"
      st.reg == :local -> "Direct calls only (no registrar)"
      st.reg == :unregistered -> "Unregistered"
      true -> "Idle"
    end
  end

  ## ------------------------------------------------------------------
  ## Addressing helpers

  defp build_target_uri(cfg, target) do
    t = target |> to_string() |> String.trim()

    cond do
      t == "" ->
        {:error, "Enter a number or a SIP address"}

      String.match?(t, ~r/^sips?:/i) ->
        {:ok, t}

      String.contains?(t, "@") ->
        {:ok, "sip:" <> t}

      String.match?(t, ~r/^[\w.\-]+:\d+$/) ->
        {:ok, "sip:" <> t}

      String.match?(t, ~r/^\d{1,3}(\.\d{1,3}){3}$/) ->
        {:ok, "sip:" <> t}

      true ->
        user =
          if String.match?(t, ~r/^[\d+*#\-\s\(\)]+$/),
            do: String.replace(t, ~r/[\s\-\(\)]/, ""),
            else: t

        case call_domain(cfg) do
          nil ->
            {:error, "No SIP server on this account - use host:port or sip:user@host:port"}

          d ->
            {:ok, "sip:#{user}@#{d}"}
        end
    end
  end

  defp call_domain(cfg) do
    cond do
      cfg.domain != "" -> cfg.domain
      cfg.registrar != "" -> cfg.registrar |> parse_hostport(5060) |> elem(0)
      true -> nil
    end
  end

  defp route_dest(cfg, uri) do
    case Message.parse_uri(uri) do
      nil ->
        {:error, "Invalid SIP address"}

      u ->
        proxy =
          cond do
            u.port != nil -> nil
            cfg.outbound_proxy != "" -> parse_hostport(cfg.outbound_proxy, 5060)
            cfg.registrar != "" and u.host == call_domain(cfg) -> parse_hostport(cfg.registrar, 5060)
            true -> nil
          end

        {h, p} = proxy || {u.host, u.port || 5060}

        case resolve(h, p) do
          {:ok, dest} -> {:ok, dest}
          {:error, why} -> {:error, "Cannot resolve #{h}: #{inspect(why)}"}
        end
    end
  end

  defp dest_for(uri, fallback) do
    with %{host: h} = u <- Message.parse_uri(uri),
         {:ok, d} <- resolve(h, u.port || 5060) do
      d
    else
      _ -> fallback
    end
  end

  defp proxy_or_registrar(cfg),
    do: if(cfg.outbound_proxy != "", do: cfg.outbound_proxy, else: cfg.registrar)

  defp parse_hostport(str, default_port) do
    {h, p} = Message.split_hostport(str)
    {h, p || default_port}
  end

  defp resolve(host, port) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, {ip, port}}
      {:error, r} -> {:error, r}
    end
  end

  defp contact_host(cfg, ip) do
    if cfg.advertised_host != "",
      do: cfg.advertised_host,
      else: ip |> local_ip_for() |> :inet.ntoa() |> to_string()
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

  defp domain(cfg, host) do
    case call_domain(cfg) do
      nil -> host
      d -> d
    end
  end

  defp display(cfg), do: if(cfg.display_name != "", do: "\"#{cfg.display_name}\" ", else: "")

  defp caller_label(from_hdr) do
    name = Message.display_name(from_hdr)
    uri = Message.addr_uri(from_hdr)
    user = case Message.parse_uri(uri) do
      %{user: u} when u != nil -> u
      _ -> uri
    end

    if name not in [nil, ""], do: "#{name} (#{user})", else: user || "unknown"
  end

  defp label_from_uri(uri) do
    case Message.parse_uri(uri) do
      %{user: u, host: h, port: p} ->
        hp = if p, do: "#{h}:#{p}", else: h
        if u, do: "#{u}@#{hp}", else: hp

      _ ->
        uri
    end
  end

  ## ------------------------------------------------------------------
  ## Low level helpers

  defp send_raw(%{sock: nil}, _bin, _dest), do: :ok

  defp send_raw(st, bin, {ip, port}) do
    :gen_udp.send(st.sock, ip, port, bin)
    log(st, :out, {ip, port}, bin)
    :ok
  end

  defp log(st, dir, {ip, port}, data) do
    text = if String.valid?(data), do: data, else: inspect(data)

    Events.broadcast(%{
      type: "log",
      entry: %{
        ts: now_ms(),
        dir: Atom.to_string(dir),
        account: st.cfg.id,
        remote: "#{:inet.ntoa(ip)}:#{port}",
        text: text
      }
    })
  end

  defp via(host, port, branch), do: "SIP/2.0/UDP #{host}:#{port};rport;branch=#{branch}"

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
  defp rand_hex(n), do: n |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp new_branch, do: "z9hG4bK" <> rand_hex(6)
  defp tag, do: rand_hex(5)
  defp new_call_id(host), do: rand_hex(10) <> "@" <> host
  defp sess_id, do: :rand.uniform(1_000_000_000)
end
