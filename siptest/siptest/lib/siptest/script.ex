defmodule SipTest.Script do
  @moduledoc """
  Line based scenario format (a tiny SIPp-like language). One command per line, `#` starts a comment line.

      send METHOD [key=value ...]     INVITE REGISTER OPTIONS BYE CANCEL or any other method
                                      keys: expires= max-forwards= to= sdp=none|bad dialog
      ack                             ACK the 2xx of the last INVITE (non-2xx are ACKed automatically)
      auth [wrong]                    answer the last 401/407 with digest credentials (no-op if not challenged)
      expect CODE... [METHOD] [timeout=MS|ring]
                                      wait for a response; provisional (1xx) responses not listed are skipped
      expect-request METHOD [timeout=MS|ring]
                                      wait for a request from the phone (BYE/OPTIONS/... are answered with 200)
      wait MS
      assert-header NAME contains TEXT
      assert-body contains TEXT
  """

  @doc "Parse script text into a list of step maps, or {:error, message}."
  def parse(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, n}, {:ok, acc} ->
      line = String.trim(raw)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          {:cont, {:ok, acc}}

        true ->
          case parse_line(line) do
            {:ok, step} -> {:cont, {:ok, [Map.merge(step, %{line: n, text: line}) | acc]}}
            {:error, msg} -> {:halt, {:error, "line #{n}: #{msg}"}}
          end
      end
    end)
    |> case do
      {:ok, steps} when steps != [] -> {:ok, Enum.reverse(steps)}
      {:ok, []} -> {:error, "the script has no steps"}
      error -> error
    end
  end

  defp parse_line(line) do
    [cmd | args] = String.split(line, ~r/\s+/)

    case String.downcase(cmd) do
      "send" -> parse_send(args)
      "ack" -> {:ok, %{cmd: :ack}}
      "auth" -> parse_auth(args)
      "wait" -> parse_wait(args)
      "expect" -> parse_expect(args)
      "expect-request" -> parse_expect_request(args)
      "assert-header" -> parse_assert_header(args)
      "assert-body" -> parse_assert_body(args)
      other -> {:error, "unknown command '#{other}'"}
    end
  end

  defp parse_send([]), do: {:error, "send needs a method"}

  defp parse_send([method | rest]) do
    method = String.upcase(method)

    cond do
      not Regex.match?(~r/^[A-Z][A-Z0-9_\-]*$/, method) -> {:error, "bad method '#{method}'"}
      method == "ACK" -> {:ok, %{cmd: :ack}}
      true -> {:ok, %{cmd: :send, method: method, opts: opts(rest)}}
    end
  end

  defp parse_auth([]), do: {:ok, %{cmd: :auth, wrong: false}}
  defp parse_auth(["wrong"]), do: {:ok, %{cmd: :auth, wrong: true}}
  defp parse_auth(_), do: {:error, "auth takes no argument or 'wrong'"}

  defp parse_wait([ms]) do
    case Integer.parse(ms) do
      {n, ""} when n >= 0 and n <= 600_000 -> {:ok, %{cmd: :wait, ms: n}}
      _ -> {:error, "wait needs milliseconds (0-600000)"}
    end
  end

  defp parse_wait(_), do: {:error, "wait needs milliseconds"}

  defp parse_expect(args) do
    result =
      Enum.reduce_while(args, {:ok, [], nil, %{}}, fn tok, {:ok, codes, method, o} ->
        cond do
          Regex.match?(~r/^[1-6]\d\d$/, tok) ->
            {:cont, {:ok, codes ++ [String.to_integer(tok)], method, o}}

          String.contains?(tok, "=") ->
            {:cont, {:ok, codes, method, Map.merge(o, opts([tok]))}}

          Regex.match?(~r/^[A-Za-z][A-Za-z0-9_\-]*$/, tok) ->
            {:cont, {:ok, codes, String.upcase(tok), o}}

          true ->
            {:halt, {:error, "cannot understand '#{tok}'"}}
        end
      end)

    case result do
      {:ok, [], _, _} -> {:error, "expect needs at least one status code"}
      {:ok, codes, method, o} -> with_timeout(%{cmd: :expect, codes: codes, method: method}, o)
      error -> error
    end
  end

  defp parse_expect_request([method | rest]) do
    if Regex.match?(~r/^[A-Za-z][A-Za-z0-9_\-]*$/, method) do
      with_timeout(%{cmd: :expect_request, method: String.upcase(method)}, opts(rest))
    else
      {:error, "bad method '#{method}'"}
    end
  end

  defp parse_expect_request(_), do: {:error, "expect-request needs a method"}

  defp with_timeout(step, o) do
    case Map.get(o, "timeout") do
      nil ->
        {:ok, Map.put(step, :timeout, nil)}

      "ring" ->
        {:ok, Map.put(step, :timeout, :ring)}

      v ->
        case Integer.parse(v) do
          {n, ""} when n >= 100 and n <= 600_000 -> {:ok, Map.put(step, :timeout, n)}
          _ -> {:error, "timeout must be 100-600000 or 'ring'"}
        end
    end
  end

  defp parse_assert_header([name, "contains" | words]) when words != [],
    do: {:ok, %{cmd: :assert_header, name: String.downcase(name), text: Enum.join(words, " ")}}

  defp parse_assert_header(_), do: {:error, "usage: assert-header NAME contains TEXT"}

  defp parse_assert_body(["contains" | words]) when words != [],
    do: {:ok, %{cmd: :assert_body, text: Enum.join(words, " ")}}

  defp parse_assert_body(_), do: {:error, "usage: assert-body contains TEXT"}

  defp opts(tokens) do
    Map.new(tokens, fn tok ->
      case String.split(tok, "=", parts: 2) do
        [k, v] -> {String.downcase(k), v}
        [k] -> {String.downcase(k), "true"}
      end
    end)
  end
end
