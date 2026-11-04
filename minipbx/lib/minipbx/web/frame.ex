defmodule MiniPbx.Web.Frame do
  @moduledoc "WebSocket framing (RFC 6455)."

  def send(sock, :text, data), do: :gen_tcp.send(sock, encode(1, data))
  def send(sock, :binary, data), do: :gen_tcp.send(sock, encode(2, data))
  def send(sock, :close, _data), do: :gen_tcp.send(sock, encode(8, <<1000::16>>))
  def send(sock, :pong, data), do: :gen_tcp.send(sock, encode(10, data))

  defp encode(op, data) do
    len = byte_size(data)

    hdr =
      cond do
        len < 126 -> <<1::1, 0::3, op::4, 0::1, len::7>>
        len < 65_536 -> <<1::1, 0::3, op::4, 0::1, 126::7, len::16>>
        true -> <<1::1, 0::3, op::4, 0::1, 127::7, len::64>>
      end

    [hdr, data]
  end

  @doc "Decode one client frame: {:ok, {fin, opcode, payload}, rest} | :more | :error."
  def decode(<<fin::1, _rsv::3, op::4, 1::1, len7::7, rest::binary>>) do
    case ext_len(len7, rest) do
      :more ->
        :more

      {len, _} when len > 1_048_576 ->
        :error

      {len, rest2} ->
        case rest2 do
          <<key::binary-size(4), payload::binary-size(len), tail::binary>> ->
            {:ok, {fin, op, unmask(payload, key)}, tail}

          _ ->
            :more
        end
    end
  end

  # Client frames must be masked.
  def decode(<<_::8, 0::1, _::bitstring>>), do: :error
  def decode(_), do: :more

  defp ext_len(126, <<l::16, r::binary>>), do: {l, r}
  defp ext_len(127, <<l::64, r::binary>>), do: {l, r}
  defp ext_len(n, r) when n < 126, do: {n, r}
  defp ext_len(_, _), do: :more

  defp unmask(<<>>, _key), do: <<>>

  defp unmask(payload, key) do
    n = byte_size(payload)
    full = :binary.copy(key, div(n, 4) + 1)
    :crypto.exor(payload, binary_part(full, 0, n))
  end
end
