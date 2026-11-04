defmodule SipPhone.MixProject do
  use Mix.Project

  def project do
    [
      app: :sipphone,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SipPhone.Application, []}
    ]
  end
end
