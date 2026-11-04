defmodule SipPhone.FilesTest do
  use ExUnit.Case, async: false

  alias SipPhone.Files

  setup do
    dir = Path.join(System.tmp_dir!(), "sipphone-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "data"))
    File.mkdir_p!(Path.join(dir, ".claude"))
    File.write!(Path.join(dir, "lib/ok.ex"), "defmodule Ok do end\n")
    File.write!(Path.join(dir, "lib/secrets.ex"), "x = 1\n")
    File.write!(Path.join(dir, "lib/key.ex"), "-----BEGIN RSA PRIVATE KEY-----\nabc\n")
    File.write!(Path.join(dir, "lib/blob.ex"), <<0, 1, 2, 255>>)
    File.write!(Path.join(dir, "lib/token.js"), "1")
    File.write!(Path.join(dir, "lib/.env"), "A=1")
    File.write!(Path.join(dir, "lib/notes.txt"), "no")
    File.write!(Path.join(dir, "data/accounts.json"), ~s([{"password":"pw"}]))
    File.write!(Path.join(dir, ".claude/settings.local.json"), "{}")
    File.write!(Path.join(dir, "README.md"), "# hi\n")
    File.write!(Path.join(dir, "mix.exs"), "# mix\n")
    outside = Path.join(dir, "outside.ex")
    File.write!(outside, "secret outside")
    File.ln_s!(outside, Path.join(dir, "lib/link.ex"))

    System.put_env("SIPPHONE_SRC", dir)

    on_exit(fn ->
      System.delete_env("SIPPHONE_SRC")
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "lists only safe project files" do
    paths = Enum.map(Files.list(), & &1.path)
    assert paths == ["README.md", "lib/ok.ex", "mix.exs"]
  end

  test "reads a listed file" do
    assert {:ok, "defmodule Ok do end\n"} = Files.read("lib/ok.ex")
  end

  test "refuses private, unlisted, traversal and non-string paths" do
    for p <- [
          "data/accounts.json",
          ".claude/settings.local.json",
          "lib/.env",
          "lib/key.ex",
          "lib/secrets.ex",
          "lib/link.ex",
          "lib/../outside.ex",
          "../../etc/passwd",
          "/etc/passwd",
          "lib/notes.txt",
          nil,
          42
        ] do
      assert {:error, _} = Files.read(p), "should refuse #{inspect(p)}"
    end
  end
end
