defmodule MiniPbx.Views do
  @moduledoc "JSON-ready snapshots of what the browser shows."
  alias MiniPbx.{Calls, Cdr, Registrar, Store, Transport}

  @areas ~w(config regs calls cdr)

  def areas, do: @areas

  def snapshot("config") do
    %{
      "extensions" => Enum.map(Store.extensions(), &Store.public/1),
      "routes" => Store.routes(),
      "settings" => Store.settings(),
      "sip_port" => Transport.port(),
      "sip_host" => Transport.host_for({192, 0, 2, 1})
    }
  end

  def snapshot("regs"), do: Registrar.all()
  def snapshot("calls"), do: Calls.active()
  def snapshot("cdr"), do: Cdr.list(limit: 500)
  def snapshot(_), do: nil

  def all, do: Map.new(@areas, fn a -> {a, snapshot(a)} end)
end
