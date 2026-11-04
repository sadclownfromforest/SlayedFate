defmodule MiniPbx.Config do
  @moduledoc "Runtime configuration read from environment variables (see README)."

  def web_port, do: env_int("WEB_PORT", 4200)
  def sip_port, do: env_int("SIP_PORT", 5060)
  def data_dir, do: System.get_env("DATA_DIR") || "data"

  def web_bind, do: env_ip("WEB_BIND", {127, 0, 0, 1})
  def sip_bind, do: env_ip("SIP_BIND", {0, 0, 0, 0})

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
      {n, ""} when n >= 0 and n <= 65_535 -> n
      _ -> default
    end
  end

  defp env_ip(name, default) do
    case System.get_env(name) do
      s when s in [nil, ""] ->
        default

      s ->
        case :inet.parse_address(String.to_charlist(s)) do
          {:ok, ip} -> ip
          _ -> default
        end
    end
  end
end
