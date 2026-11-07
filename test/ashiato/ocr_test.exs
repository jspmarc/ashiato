defmodule Ashiato.OcrTest do
  @moduledoc """
  OCR client contract: socket round trip, clean errors, malformed-block
  rejection, and the fake's canned/recorded behaviour.
  """

  # These tests write application env for `:ashiato, Ashiato.Ocr` and start a fake under a
  # fixed registered name, so they must not run alongside another module doing the same.
  use ExUnit.Case, async: false

  alias Ashiato.Ocr
  alias Ashiato.Ocr.Fake
  alias Ashiato.Ocr.Socket
  alias Ashiato.OcrStub

  @lines [
    %{bbox: [10, 20, 400, 80], text: "こんにちは", score: 0.98},
    %{bbox: [10, 100, 400, 160], text: "世界", score: 0.9}
  ]

  setup do
    path =
      Path.join(System.tmp_dir!(), "ashiato-ocr-test-#{System.unique_integer([:positive])}.sock")

    Application.put_env(:ashiato, Ocr, socket_path: path, timeout: 5_000)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:ashiato, Ocr)
    end)

    %{socket_path: path}
  end

  describe "Ashiato.Ocr.Socket.recognise/1" do
    test "round trip: sends the locator and returns the validated lines", %{socket_path: path} do
      parent = self()
      encoded = Enum.map(@lines, &stringify_keys/1)

      start_supervised!(
        {OcrStub,
         path: path,
         handler: fn request ->
           send(parent, {:request, request})
           %{"lines" => encoded}
         end}
      )

      assert Socket.recognise({:path, path}) == {:ok, @lines}
      assert_receive {:request, %{"op" => "ocr", "path" => ^path}}
    end

    test "a url locator is sent as \"url\", not image bytes", %{socket_path: path} do
      parent = self()
      url = "https://example.test/pages/1.png"
      line = stringify_keys(hd(@lines))

      start_supervised!(
        {OcrStub,
         path: path,
         handler: fn request ->
           send(parent, {:request, request})
           %{"lines" => [line]}
         end}
      )

      assert {:ok, [_]} = Socket.recognise({:url, url})
      assert_receive {:request, %{"op" => "ocr", "url" => ^url}}
    end

    test "a locator that is not a path or url is refused, not raised" do
      assert Socket.recognise(nil) == {:error, :invalid_locator}
      assert Socket.recognise({:path, 123}) == {:error, :invalid_locator}
      assert Socket.recognise("just-a-string") == {:error, :invalid_locator}
    end

    test "missing socket file is a clean error", %{socket_path: path} do
      assert Socket.recognise({:path, path}) == {:error, :enoent}
    end

    test "unparseable reply is a clean error", %{socket_path: path} do
      start_supervised!(
        {OcrStub, path: path, handler: fn _ -> {:raw, "<html>not json</html>"} end}
      )

      error = Socket.recognise({:path, path})
      assert error == {:error, :invalid_json}
      refute inspect(error) =~ "not json"
    end

    test "a block with a three-integer bbox is rejected, not passed on", %{socket_path: path} do
      bad = %{"bbox" => [10, 20, 300], "text" => "こんにちは", "score" => 0.9}
      reply = %{"lines" => [stringify_keys(hd(@lines)), bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 1}} = Socket.recognise({:path, path})
    end

    test "a block whose score is outside 0..1 is rejected", %{socket_path: path} do
      bad = %{"bbox" => [10, 20, 300, 400], "text" => "こんにちは", "score" => 1.4}
      reply = %{"lines" => [bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 0}} = Socket.recognise({:path, path})
    end

    test "a silent service hits the bounded timeout instead of hanging", %{socket_path: path} do
      Application.put_env(:ashiato, Ocr, socket_path: path, timeout: 100)
      start_supervised!({OcrStub, path: path, handler: fn _ -> :no_reply end})

      assert Socket.recognise({:path, path}) == {:error, :timeout}
    end
  end

  describe "Ashiato.Ocr.Fake" do
    test "returns canned lines and records requests" do
      start_supervised!(Fake)
      locator = {:path, "/images/page-1.png"}

      assert {:ok, [%{bbox: bbox, text: text, score: score} | _]} = Fake.recognise(locator)
      assert is_integer(hd(bbox)) and is_binary(text) and is_float(score)
      assert Fake.requests() == [locator]
    end

    test "configured error is returned and the request still recorded" do
      start_supervised!({Fake, error: :service_down})
      locator = {:url, "https://example.test/pages/1.png"}

      assert Fake.recognise(locator) == {:error, :service_down}
      assert Fake.requests() == [locator]
    end

    test "canned lines are configurable" do
      lines = [%{bbox: [0, 0, 1000, 100], text: "テスト", score: 1.0}]
      start_supervised!({Fake, lines: lines})

      assert Fake.recognise({:path, "x"}) == {:ok, lines}
    end
  end

  test "acceptance: Ocr.impl() behaviour through Fake" do
    Application.put_env(:ashiato, Ashiato.Ocr, impl: Fake)
    start_supervised!(Fake)
    locator = {:path, "/images/acceptance.png"}

    assert {:ok, lines} = Ocr.impl().recognise(locator)
    assert is_list(lines) and length(lines) > 0
    assert Fake.requests() == [locator]

    Application.delete_env(:ashiato, Ashiato.Ocr)
  end

  defp stringify_keys(line) do
    Map.new(line, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
