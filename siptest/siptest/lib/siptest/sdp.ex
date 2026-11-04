defmodule SipTest.SDP do
  @moduledoc "Minimal SDP offer/answer (RFC 4566 / RFC 3264) for one G.711 audio stream."

  @names %{0 => "PCMU", 8 => "PCMA"}

  @doc """
  Build an SDP body. Required keys: `:ip` (string), `:port`, `:payloads` (list of 0/8),
  `:sess_id`. Optional: `:te_pt` (telephone-event payload type), `:direction`.
  """
  def build(opts) do
    ip = opts.ip
    pts = opts.payloads
    te = Map.get(opts, :te_pt)
    dir = Map.get(opts, :direction, "sendrecv")
    fmts = pts ++ if(te, do: [te], else: [])

    lines =
      [
        "v=0",
        "o=siptest #{opts.sess_id} #{opts.sess_id} IN IP4 #{ip}",
        "s=siptest",
        "c=IN IP4 #{ip}",
        "t=0 0",
        "m=audio #{opts.port} RTP/AVP #{Enum.join(fmts, " ")}"
      ] ++
        Enum.map(pts, fn pt -> "a=rtpmap:#{pt} #{@names[pt]}/8000" end) ++
        if(te, do: ["a=rtpmap:#{te} telephone-event/8000", "a=fmtp:#{te} 0-16"], else: []) ++
        ["a=ptime:20", "a=#{dir}"]

    Enum.join(lines, "\r\n") <> "\r\n"
  end

  @doc "Parse the first audio stream. Returns a map or nil."
  def parse(sdp) when is_binary(sdp) do
    lines = sdp |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1)
    session_lines = Enum.take_while(lines, fn l -> not String.starts_with?(l, "m=") end)

    case Enum.find_index(lines, fn l -> String.starts_with?(l, "m=audio") end) do
      nil ->
        nil

      idx ->
        [mline | rest] = Enum.drop(lines, idx)
        media_lines = Enum.take_while(rest, fn l -> not String.starts_with?(l, "m=") end)

        case String.split(mline) do
          ["m=audio", port, _proto | pts] ->
            ip_str = find_ip(media_lines) || find_ip(session_lines)
            ip = ip_str && parse_ip(ip_str)

            if ip && Integer.parse(port) != :error do
              {port_n, _} = Integer.parse(port)

              %{
                ip: ip,
                port: port_n,
                payloads: pts |> Enum.map(&Integer.parse/1) |> Enum.flat_map(&pt_list/1),
                te_pt: find_te(media_lines),
                direction: find_direction(media_lines) || find_direction(session_lines) || :sendrecv
              }
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  defp pt_list({n, _}), do: [n]
  defp pt_list(_), do: []

  defp find_ip(lines) do
    Enum.find_value(lines, fn l ->
      case Regex.run(~r/^c=IN IP4 (\S+)/, l) do
        [_, ip] -> ip
        _ -> nil
      end
    end)
  end

  defp parse_ip(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp find_te(lines) do
    Enum.find_value(lines, fn l ->
      case Regex.run(~r/^a=rtpmap:(\d+) telephone-event\/8000/i, l) do
        [_, pt] -> String.to_integer(pt)
        _ -> nil
      end
    end)
  end

  defp find_direction(lines) do
    Enum.find_value(lines, fn
      "a=sendrecv" -> :sendrecv
      "a=sendonly" -> :sendonly
      "a=recvonly" -> :recvonly
      "a=inactive" -> :inactive
      _ -> nil
    end)
  end

  @doc "Choose a codec from the remote offer according to our preference."
  def choose_codec(%{payloads: pls}, prefer) do
    Enum.find(codec_order(prefer), fn pt -> pt in pls end)
  end

  @doc "Codec the remote side picked in its answer (first one we understand)."
  def answer_codec(%{payloads: pls}), do: Enum.find(pls, fn pt -> pt in [0, 8] end)

  def codec_order("pcma"), do: [8, 0]
  def codec_order(_), do: [0, 8]
end
