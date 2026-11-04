defmodule MiniPbx.Message do
  @moduledoc "SIP message parsing and serialization (RFC 3261 sections 7, 20 and 25)."

  defstruct type: :request,
            method: nil,
            uri: nil,
            status: nil,
            reason: nil,
            headers: [],
            body: ""

  @compact %{
    "v" => "via",
    "f" => "from",
    "t" => "to",
    "i" => "call-id",
    "m" => "contact",
    "l" => "content-length",
    "c" => "content-type",
    "k" => "supported"
  }

  @multi ["via", "route", "record-route"]

  @canon %{
    "call-id" => "Call-ID",
    "cseq" => "CSeq",
    "www-authenticate" => "WWW-Authenticate",
    "proxy-authenticate" => "Proxy-Authenticate",
    "mime-version" => "MIME-Version"
  }

  ## ------------------------------------------------------------------
  ## Parsing

  def parse(data) when is_binary(data) do
    {head, body} =
      case :binary.split(data, "\r\n\r\n") do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    lines = head |> then(&:binary.split(&1, "\r\n", [:global])) |> unfold()

    case lines do
      [first | hdr_lines] ->
        case parse_start_line(first) do
          {:ok, msg} ->
            headers = Enum.flat_map(hdr_lines, &parse_header/1)
            {:ok, %{msg | headers: headers, body: trim_body(headers, body)}}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp unfold(lines) do
    lines
    |> Enum.reduce([], fn
      <<c, _::binary>> = line, [prev | rest] when c in [?\s, ?\t] ->
        [prev <> " " <> String.trim(line) | rest]

      line, acc ->
        [line | acc]
    end)
    |> Enum.reverse()
  end

  defp parse_start_line("SIP/2.0 " <> rest) do
    {code, reason} =
      case String.split(rest, " ", parts: 2) do
        [c, r] -> {c, r}
        [c] -> {c, ""}
      end

    case Integer.parse(code) do
      {n, ""} -> {:ok, %__MODULE__{type: :response, status: n, reason: reason}}
      _ -> :error
    end
  end

  defp parse_start_line(line) do
    case String.split(line, " ") do
      [method, uri, "SIP/2.0"] when method != "" ->
        {:ok, %__MODULE__{type: :request, method: method, uri: uri}}

      _ ->
        :error
    end
  end

  defp parse_header(line) do
    case :binary.split(line, ":") do
      [name, value] ->
        name = name |> String.trim() |> String.downcase()
        name = Map.get(@compact, name, name)
        value = String.trim(value)

        if name in @multi do
          value |> split_commas() |> Enum.map(fn v -> {name, v} end)
        else
          [{name, value}]
        end

      _ ->
        []
    end
  end

  defp trim_body(headers, body) do
    case List.keyfind(headers, "content-length", 0) do
      {_, v} ->
        case Integer.parse(v) do
          {n, _} when n >= 0 and n < byte_size(body) -> binary_part(body, 0, n)
          _ -> body
        end

      nil ->
        body
    end
  end

  @doc "Split a comma separated header value, respecting quotes and <angle brackets>."
  def split_commas(value), do: do_split(value, [], [], false, false)

  defp do_split(<<>>, cur, acc, _q, _a), do: Enum.reverse(finish(cur, acc))
  defp do_split(<<?", rest::binary>>, cur, acc, q, a), do: do_split(rest, [?" | cur], acc, not q, a)

  defp do_split(<<?<, rest::binary>>, cur, acc, false, _a),
    do: do_split(rest, [?< | cur], acc, false, true)

  defp do_split(<<?>, rest::binary>>, cur, acc, false, _a),
    do: do_split(rest, [?> | cur], acc, false, false)

  defp do_split(<<?,, rest::binary>>, cur, acc, false, false),
    do: do_split(rest, [], finish(cur, acc), false, false)

  defp do_split(<<c, rest::binary>>, cur, acc, q, a), do: do_split(rest, [c | cur], acc, q, a)

  defp finish(cur, acc) do
    s = cur |> Enum.reverse() |> :erlang.list_to_binary() |> String.trim()
    if s == "", do: acc, else: [s | acc]
  end

  ## ------------------------------------------------------------------
  ## Serialization

  def serialize(%__MODULE__{} = m) do
    start =
      case m.type do
        :request -> "#{m.method} #{m.uri} SIP/2.0"
        :response -> "SIP/2.0 #{m.status} #{m.reason}"
      end

    hdrs =
      m.headers
      |> Enum.reject(fn {k, _} -> k == "content-length" end)
      |> Enum.map(fn {k, v} -> [canon(k), ": ", v, "\r\n"] end)

    IO.iodata_to_binary([
      start,
      "\r\n",
      hdrs,
      "Content-Length: ",
      Integer.to_string(byte_size(m.body)),
      "\r\n\r\n",
      m.body
    ])
  end

  defp canon(k) do
    case Map.get(@canon, k) do
      nil -> k |> String.split("-") |> Enum.map_join("-", &String.capitalize/1)
      v -> v
    end
  end

  def request(method, uri, headers, body \\ "") do
    %__MODULE__{type: :request, method: method, uri: uri, headers: headers, body: body}
  end

  @doc """
  Build a response to `req` (RFC 3261 8.2.6). Options: `:to_tag`, `:headers`,
  `:body`, `:src` ({ip, port} used to add received/rport to the top Via).
  """
  def response(%__MODULE__{} = req, status, reason, opts \\ []) do
    tag = Keyword.get(opts, :to_tag)
    extra = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")
    src = Keyword.get(opts, :src)

    vias =
      case {headers(req, "via"), src} do
        {[first | rest], {_, _} = s} -> [fix_via(first, s) | rest]
        {v, _} -> v
      end

    to = header(req, "to") || ""
    to = if tag && status > 100 && param(to, "tag") == nil, do: to <> ";tag=" <> tag, else: to

    rr =
      if status > 100 and status < 300 and req.method == "INVITE",
        do: headers(req, "record-route"),
        else: []

    hs =
      Enum.map(vias, fn v -> {"via", v} end) ++
        [
          {"from", header(req, "from") || ""},
          {"to", to},
          {"call-id", header(req, "call-id") || ""},
          {"cseq", header(req, "cseq") || ""}
        ] ++
        Enum.map(rr, fn v -> {"record-route", v} end) ++ extra

    %__MODULE__{type: :response, status: status, reason: reason, headers: hs, body: body}
  end

  ## ------------------------------------------------------------------
  ## Header access

  def header(%{headers: h}, name) do
    case List.keyfind(h, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  def headers(%{headers: h}, name), do: for({k, v} <- h, k == name, do: v)

  ## ------------------------------------------------------------------
  ## Header value helpers

  @doc "Value of a `;name=value` parameter (\"\" for a bare flag, nil if absent)."
  def param(nil, _name), do: nil

  def param(str, name) do
    re = Regex.compile!(";\\s*" <> Regex.escape(name) <> "(?:=([^;,\\s>]*))?(?=[;,\\s>]|$)", "i")

    case Regex.run(re, str) do
      [_, v] -> v
      [_] -> ""
      _ -> nil
    end
  end

  def from_tag(msg), do: param(header(msg, "from"), "tag")
  def to_tag(msg), do: param(header(msg, "to"), "tag")

  def addr_uri(nil), do: nil

  def addr_uri(value) do
    case Regex.run(~r/<([^>]*)>/, value) do
      [_, u] -> u
      _ -> value |> String.split([";", ","]) |> hd() |> String.trim()
    end
  end

  def display_name(nil), do: nil

  def display_name(value) do
    case Regex.run(~r/^\s*"([^"]*)"\s*</, value) do
      [_, n] ->
        n

      _ ->
        case Regex.run(~r/^\s*([^<"]+?)\s*</, value) do
          [_, n] -> n
          _ -> nil
        end
    end
  end

  def parse_cseq(nil), do: {0, ""}

  def parse_cseq(value) do
    case String.split(value) do
      [n, m] ->
        case Integer.parse(n) do
          {i, _} -> {i, String.upcase(m)}
          _ -> {0, ""}
        end

      _ ->
        {0, ""}
    end
  end

  @doc "Parse a SIP(S) URI into %{scheme, user, host, port} or nil."
  def parse_uri(nil), do: nil

  def parse_uri(uri) do
    case Regex.run(~r/^(sips?):(?:([^@;]*)@)?(\[[^\]]+\]|[^:;?>\s]+)(?::(\d+))?/i, uri) do
      [_, scheme, user, host | rest] ->
        port =
          case rest do
            [p | _] when p != "" -> String.to_integer(p)
            _ -> nil
          end

        user = user |> String.split(":") |> hd()

        %{
          scheme: String.downcase(scheme),
          user: if(user == "", do: nil, else: user),
          host: host,
          port: port
        }

      _ ->
        nil
    end
  end

  def parse_via(nil), do: nil

  def parse_via(value) do
    case Regex.run(~r/^SIP\s*\/\s*2\.0\s*\/\s*(\w+)\s+([^;\s]+)(.*)$/is, value) do
      [_, proto, hostport, params] ->
        {host, port} = split_hostport(hostport)

        %{
          proto: String.upcase(proto),
          host: host,
          port: port,
          branch: param(params, "branch"),
          rport: param(params, "rport"),
          received: param(params, "received")
        }

      _ ->
        nil
    end
  end

  def split_hostport("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [h, ":" <> p] -> {h, to_int(p)}
      [h, _] -> {h, nil}
      _ -> {rest, nil}
    end
  end

  def split_hostport(s) do
    case String.split(s, ":") do
      [h, p] -> {h, to_int(p)}
      _ -> {s, nil}
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  @doc "Add received= and fill rport= on a single Via value (RFC 3581 / RFC 3261 18.2.1)."
  def fix_via(value, {ip, port}) do
    ips = ip |> :inet.ntoa() |> to_string()
    v = Regex.replace(~r/;\s*rport(?=[;,\s]|$)/i, value, ";rport=#{port}", global: false)

    host =
      case parse_via(value) do
        nil -> nil
        via -> via.host
      end

    if host != ips and not Regex.match?(~r/;\s*received=/i, v),
      do: v <> ";received=" <> ips,
      else: v
  end
end
