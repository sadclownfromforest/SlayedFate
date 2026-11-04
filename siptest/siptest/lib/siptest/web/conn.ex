defmodule SipTest.Web.Conn do
  @moduledoc "Minimal HTTP/1.1 handler: static files and the /ws WebSocket upgrade."

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @files %{
    "/" => {"index.html", "text/html; charset=utf-8"},
    "/app.js" => {"app.js", "text/javascript; charset=utf-8"},
    "/style.css" => {"style.css", "text/css; charset=utf-8"},
    "/favicon.svg" => {"favicon.svg", "image/svg+xml"}
  }

  @csp "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; " <>
         "style-src 'self'; script-src 'self'; frame-ancestors 'none'"

  def serve(sock) do
    case read_head(sock, <<>>) do
      {:ok, req, rest} -> route(sock, req, rest)
      _ -> :gen_tcp.close(sock)
    end
  end

  defp read_head(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, parse_head(head), rest}

      _ ->
        if byte_size(acc) > 16_384 do
          :error
        else
          case :gen_tcp.recv(sock, 0, 10_000) do
            {:ok, data} -> read_head(sock, acc <> data)
            _ -> :error
          end
        end
    end
  end

  defp parse_head(head) do
    [line | hdrs] = :binary.split(head, "\r\n", [:global])

    {method, path} =
      case String.split(line, " ") do
        [m, p, _] -> {m, p}
        _ -> {"", ""}
      end

    headers =
      Map.new(
        for h <- hdrs, [k, v] <- [String.split(h, ":", parts: 2)] do
          {k |> String.trim() |> String.downcase(), String.trim(v)}
        end
      )

    %{method: method, path: path |> String.split("?") |> hd(), headers: headers}
  end

  defp route(sock, req, rest) do
    cond do
      not host_ok?(req.headers["host"]) -> respond(sock, 403, "text/plain", "Forbidden host")
      req.method != "GET" -> respond(sock, 405, "text/plain", "Method not allowed")
      req.path == "/ws" -> upgrade(sock, req, rest)
      true -> static(sock, req.path)
    end
  end

  defp host_ok?(nil), do: false

  defp host_ok?(host) do
    h = host |> String.replace(~r/:\d+$/, "") |> String.downcase()
    h in SipTest.Config.allowed_hosts()
  end

  defp origin_ok?(nil), do: true

  defp origin_ok?(origin) do
    case URI.parse(origin) do
      %URI{host: h} when is_binary(h) ->
        h = String.downcase(h)
        h in SipTest.Config.allowed_hosts() or "[" <> h <> "]" in SipTest.Config.allowed_hosts()

      _ ->
        false
    end
  end

  defp upgrade(sock, req, rest) do
    h = req.headers
    key = h["sec-websocket-key"]

    cond do
      key == nil or String.downcase(h["upgrade"] || "") != "websocket" ->
        respond(sock, 400, "text/plain", "Bad request")

      not origin_ok?(h["origin"]) ->
        respond(sock, 403, "text/plain", "Forbidden origin")

      true ->
        accept = :crypto.hash(:sha, key <> @ws_guid) |> Base.encode64()

        :gen_tcp.send(
          sock,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" <>
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        )

        SipTest.Web.Session.run(sock, rest)
    end
  end

  defp static(sock, path) do
    case Map.get(@files, path) do
      nil ->
        respond(sock, 404, "text/plain", "Not found")

      {file, type} ->
        full = Path.join(to_string(:code.priv_dir(:siptest)), Path.join("static", file))

        case File.read(full) do
          {:ok, body} -> respond(sock, 200, type, body)
          _ -> respond(sock, 404, "text/plain", "Not found")
        end
    end
  end

  defp respond(sock, code, type, body) do
    reason =
      case code do
        200 -> "OK"
        400 -> "Bad Request"
        403 -> "Forbidden"
        404 -> "Not Found"
        _ -> "Method Not Allowed"
      end

    head =
      "HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\nCache-Control: no-store\r\n" <>
        "X-Content-Type-Options: nosniff\r\nContent-Security-Policy: #{@csp}\r\n" <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, [head, body])
    :gen_tcp.close(sock)
  end
end
