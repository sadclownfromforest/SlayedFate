defmodule SipTest.Config do
  @moduledoc "Runtime configuration read from environment variables."

  def web_port, do: env_int("WEB_PORT", 4100)

  def web_bind do
    case System.get_env("WEB_BIND") do
      s when s in [nil, ""] ->
        {127, 0, 0, 1}

      s ->
        case :inet.parse_address(String.to_charlist(s)) do
          {:ok, ip} -> ip
          _ -> {127, 0, 0, 1}
        end
    end
  end

  @doc "Host names the web UI answers to (DNS-rebinding / cross-site protection)."
  def allowed_hosts do
    extra =
      (System.get_env("ALLOWED_HOSTS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    ["localhost", "127.0.0.1", "[::1]"] ++ extra
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {n, ""} -> n
      _ -> default
    end
  end
end
