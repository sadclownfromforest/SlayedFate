defmodule SipPhone.Media do
  @moduledoc """
  One RTP session (RFC 3550) per call: G.711 over UDP, 20 ms packetization,
  RFC 4733 telephone-event for DTMF. Audio to/from the browser is 8 kHz
  signed 16-bit little-endian PCM.
  """
  use GenServer
  import Bitwise

  alias SipPhone.{Events, G711}

  @ptime 20
  @samples 160
  @frame_bytes 320
  @max_buf 6400

  ## API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def local_port(pid), do: GenServer.call(pid, :port)

  def set_remote(pid, ip, port, codec, te_pt),
    do: GenServer.cast(pid, {:remote, ip, port, codec, te_pt})

  def dtmf(pid, digit), do: GenServer.cast(pid, {:dtmf, digit})
  def stop(pid), do: GenServer.cast(pid, :stop)

  @doc "Push microphone PCM (from the browser) to the call's RTP session."
  def push_pcm(call_id, pcm) do
    case Registry.lookup(SipPhone.MediaReg, call_id) do
      [{pid, _}] -> GenServer.cast(pid, {:pcm, pcm})
      _ -> :ok
    end
  end

  ## Callbacks

  @impl true
  def init(opts) do
    case open_socket() do
      {:ok, sock, port} ->
        Registry.register(SipPhone.MediaReg, opts.call_id, nil)

        {:ok,
         %{
           call_id: opts.call_id,
           sock: sock,
           port: port,
           codec: opts.codec,
           remote: nil,
           te_pt: nil,
           ssrc: :rand.uniform(0xFFFFFFFF),
           seq: :rand.uniform(0xFFFF),
           ts: :rand.uniform(0xFFFFFFFF),
           buf: <<>>,
           marker: true,
           next_at: nil,
           dtmf: nil,
           dtmf_q: []
         }}

      {:error, reason} ->
        {:stop, {:rtp_open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, st), do: {:reply, st.port, st}

  @impl true
  def handle_cast({:remote, ip, port, codec, te_pt}, st) do
    st = %{st | remote: {ip, port}, codec: codec, te_pt: te_pt}

    st =
      if st.next_at == nil do
        Process.send_after(self(), :tick, @ptime)
        %{st | next_at: System.monotonic_time(:millisecond) + @ptime}
      else
        st
      end

    {:noreply, st}
  end

  def handle_cast({:pcm, pcm}, st) do
    buf = st.buf <> pcm
    size = byte_size(buf)
    buf = if size > @max_buf, do: binary_part(buf, size - @max_buf, @max_buf), else: buf
    {:noreply, %{st | buf: buf}}
  end

  def handle_cast({:dtmf, digit}, st) do
    if st.te_pt != nil and digit_code(digit) != nil do
      {:noreply, %{st | dtmf_q: st.dtmf_q ++ [digit]}}
    else
      {:noreply, st}
    end
  end

  def handle_cast(:stop, st), do: {:stop, :normal, st}

  @impl true
  def handle_info(:tick, st) do
    st = send_frame(st)
    now = System.monotonic_time(:millisecond)
    next = st.next_at + @ptime
    next = if next < now - 100, do: now + @ptime, else: next
    Process.send_after(self(), :tick, max(next - now, 1))
    {:noreply, %{st | next_at: next}}
  end

  def handle_info({:udp, _sock, _ip, _port, data}, st) do
    case parse_rtp(data) do
      {pt, payload} when pt in [0, 8] -> Events.audio(st.call_id, G711.decode(pt, payload))
      _ -> :ok
    end

    {:noreply, st}
  end

  def handle_info(_other, st), do: {:noreply, st}

  ## Sending

  defp send_frame(%{dtmf: nil, dtmf_q: [d | rest]} = st),
    do: send_frame(%{st | dtmf: %{event: digit_code(d), ts0: st.ts, ticks: 0}, dtmf_q: rest})

  defp send_frame(%{dtmf: nil} = st) do
    {pcm, buf} =
      if byte_size(st.buf) >= @frame_bytes do
        <<frame::binary-size(@frame_bytes), rest::binary>> = st.buf
        {frame, rest}
      else
        {:binary.copy(<<0>>, @frame_bytes), st.buf}
      end

    packet = rtp(st.codec, st.marker, st.seq, st.ts, st.ssrc, G711.encode(st.codec, pcm))
    send_pkt(st, packet)
    advance(%{st | buf: buf, marker: false})
  end

  defp send_frame(%{dtmf: ev} = st) do
    # RFC 4733: 8 packets of growing duration, then 3 end-of-event packets.
    ending = ev.ticks >= 8
    e = if ending, do: 1, else: 0
    dur = if ending, do: 8 * @samples, else: (ev.ticks + 1) * @samples
    payload = <<ev.event::8, e::1, 0::1, 10::6, dur::16>>
    send_pkt(st, rtp(st.te_pt, ev.ticks == 0, st.seq, ev.ts0, st.ssrc, payload))
    ticks = ev.ticks + 1
    st = if ticks >= 11, do: %{st | dtmf: nil}, else: %{st | dtmf: %{ev | ticks: ticks}}
    advance(st)
  end

  defp advance(st),
    do: %{st | seq: (st.seq + 1) &&& 0xFFFF, ts: (st.ts + @samples) &&& 0xFFFFFFFF}

  defp send_pkt(%{remote: {ip, port}, sock: sock}, packet), do: :gen_udp.send(sock, ip, port, packet)
  defp send_pkt(_, _), do: :ok

  defp rtp(pt, marker, seq, ts, ssrc, payload) do
    m = if marker, do: 1, else: 0
    <<2::2, 0::1, 0::1, 0::4, m::1, pt::7, seq::16, ts::32, ssrc::32, payload::binary>>
  end

  ## Receiving

  defp parse_rtp(<<2::2, p::1, x::1, cc::4, _m::1, pt::7, _seq::16, _ts::32, _ssrc::32, rest::binary>>) do
    n = cc * 4

    case rest do
      <<_csrc::binary-size(n), rest2::binary>> ->
        rest3 = if x == 1, do: skip_ext(rest2), else: rest2
        payload = if p == 1, do: strip_pad(rest3), else: rest3
        if is_binary(payload), do: {pt, payload}, else: nil

      _ ->
        nil
    end
  end

  defp parse_rtp(_), do: nil

  defp skip_ext(<<_id::16, len::16, rest::binary>>) do
    n = len * 4

    case rest do
      <<_ext::binary-size(n), r::binary>> -> r
      _ -> nil
    end
  end

  defp skip_ext(_), do: nil

  defp strip_pad(bin) when is_binary(bin) and byte_size(bin) > 0 do
    pad = :binary.last(bin)
    if pad <= byte_size(bin), do: binary_part(bin, 0, byte_size(bin) - pad), else: nil
  end

  defp strip_pad(_), do: nil

  ## Helpers

  defp open_socket do
    {lo, hi} = SipPhone.Config.rtp_range()
    ports = for p <- lo..hi, rem(p, 2) == 0, do: p

    Enum.find_value(Enum.shuffle(ports), {:error, :no_free_rtp_port}, fn p ->
      case :gen_udp.open(p, [:binary, active: true, ip: {0, 0, 0, 0}]) do
        {:ok, s} -> {:ok, s, p}
        _ -> nil
      end
    end)
  end

  defp digit_code(d) when d in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
    do: String.to_integer(d)

  defp digit_code("*"), do: 10
  defp digit_code("#"), do: 11
  defp digit_code("A"), do: 12
  defp digit_code("B"), do: 13
  defp digit_code("C"), do: 14
  defp digit_code("D"), do: 15
  defp digit_code(_), do: nil
end
