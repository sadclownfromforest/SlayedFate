defmodule SipTest.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :duplicate, name: SipTest.Clients},
        {Task.Supervisor, name: SipTest.ConnSup},
        {Task.Supervisor, name: SipTest.RunSup},
        SipTest.Suite
      ] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: SipTest.Supervisor)
  end

  defp web_children do
    if System.get_env("SIPTEST_NO_WEB") in [nil, "", "0"] do
      [SipTest.Web.Server]
    else
      []
    end
  end
end
