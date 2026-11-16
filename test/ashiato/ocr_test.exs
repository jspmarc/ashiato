defmodule Ashiato.OcrTest do
  @moduledoc """
  Covers the socket round trip, clean errors, malformed-block rejection, the
  exact reply-size cap, and the fake's canned and recorded behaviour.
  """

  # These tests write application env for `:ashiato, Ashiato.Ocr` and start a fake under a
  # fixed registered name, so they must not run alongside another module doing the same.
  use ExUnit.Case, async: false

  alias Ashiato.Ocr
  alias Ashiato.Ocr.Fake
  alias Ashiato.Ocr.Socket
  alias Ashiato.OcrStub

  @lines [
    %{bbox: [10, 20, 400, 80], text: "こんにちは", score: 0.98, crop: "crop-bytes-1"},
    %{bbox: [10, 100, 400, 160], text: "世界", score: 0.9, crop: "crop-bytes-2"}
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

  describe "Ashiato.Ocr.recognise/1" do
    test "delegates to impl()" do
      Application.put_env(:ashiato, Ocr, impl: Fake)
      start_supervised!(Fake)
      locator = {:key, "pages/acceptance.png"}

      assert {:ok, lines} = Ocr.recognise(locator)
      assert is_list(lines) and length(lines) > 0
      assert Fake.requests() == [locator]

      Application.delete_env(:ashiato, Ocr)
    end

    test "accepts the {:key, key} locator shape the storage fake and local store return" do
      start_supervised!(Ashiato.Storage.Fake)
      assert {:ok, {:key, fake_key}} = Ashiato.Storage.Fake.locator("pages/fake.png", 300)
      assert {:ok, {:key, local_key}} = Ashiato.Storage.Local.locator("pages/local.png", 300)

      Application.put_env(:ashiato, Ocr, impl: Fake)
      start_supervised!(Fake)

      assert {:ok, lines} = Ocr.recognise(fake_key)
      assert is_list(lines) and length(lines) > 0
      assert {:ok, _} = Ocr.recognise(local_key)
      assert Fake.requests() == [fake_key, local_key]

      Application.delete_env(:ashiato, Ocr)
    end
  end

  describe "Ashiato.Ocr.Socket.recognise/1" do
    test "round trip: sends the locator and returns the validated lines", %{socket_path: path} do
      parent = self()
      encoded = Enum.map(@lines, &stub_line/1)

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
      line = stub_line(hd(@lines))

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

    test "a key locator is sent as \"key\"", %{socket_path: path} do
      parent = self()
      key = "pages/2026/1.png"
      line = stub_line(hd(@lines))

      start_supervised!(
        {OcrStub,
         path: path,
         handler: fn request ->
           send(parent, {:request, request})
           %{"lines" => [line]}
         end}
      )

      assert {:ok, [_]} = Socket.recognise({:key, key})
      assert_receive {:request, %{"op" => "ocr", "key" => ^key}}
    end

    test "a locator that is not a path, url, or key is refused, not raised" do
      assert Socket.recognise(nil) == {:error, :invalid_locator}
      assert Socket.recognise({:path, 123}) == {:error, :invalid_locator}
      assert Socket.recognise({:key, 123}) == {:error, :invalid_locator}
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
      bad = stub_line(hd(@lines)) |> Map.put("bbox", [10, 20, 300])
      reply = %{"lines" => [stub_line(hd(@lines)), bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 1}} = Socket.recognise({:path, path})
    end

    test "a block whose score is outside 0..1 is rejected", %{socket_path: path} do
      bad = stub_line(hd(@lines)) |> Map.put("score", 1.4)
      reply = %{"lines" => [bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 0}} = Socket.recognise({:path, path})
    end

    test "a block without a crop is rejected", %{socket_path: path} do
      bad = stub_line(hd(@lines)) |> Map.delete("crop")
      reply = %{"lines" => [bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 0}} = Socket.recognise({:path, path})
    end

    test "a crop that is not valid base64 is rejected", %{socket_path: path} do
      bad = stub_line(hd(@lines)) |> Map.put("crop", "!!!not base64!!!")
      reply = %{"lines" => [bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 0}} = Socket.recognise({:path, path})
    end

    test "a crop that decodes to zero bytes is rejected", %{socket_path: path} do
      bad = stub_line(hd(@lines)) |> Map.put("crop", Base.encode64(""))
      reply = %{"lines" => [bad]}
      start_supervised!({OcrStub, path: path, handler: fn _ -> reply end})

      assert {:error, {:invalid_line, 0}} = Socket.recognise({:path, path})
    end

    test "a framed reply body of exactly 16_777_216 bytes is accepted", %{socket_path: path} do
      start_supervised!(
        {OcrStub, path: path, handler: fn _ -> {:raw, framed_body(16_777_216)} end}
      )

      assert {:ok, [%{crop: crop}]} = Socket.recognise({:path, path})
      assert crop == "x"
    end

    test "a framed reply body of 16_777_217 bytes is rejected cleanly", %{socket_path: path} do
      start_supervised!(
        {OcrStub, path: path, handler: fn _ -> {:raw, framed_body(16_777_217)} end}
      )

      assert {:error, _reason} = Socket.recognise({:path, path})
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

      assert {:ok, [%{bbox: bbox, text: text, score: score, crop: crop} | _]} =
               Fake.recognise(locator)

      assert is_integer(hd(bbox)) and is_binary(text) and is_float(score) and byte_size(crop) > 0
      assert Fake.requests() == [locator]
    end

    test "configured error is returned and the request still recorded" do
      start_supervised!({Fake, error: :service_down})
      locator = {:url, "https://example.test/pages/1.png"}

      assert Fake.recognise(locator) == {:error, :service_down}
      assert Fake.requests() == [locator]
    end

    test "canned lines are configurable and key locators are recorded" do
      lines = [%{bbox: [0, 0, 1000, 100], text: "テスト", score: 1.0, crop: "crop"}]
      start_supervised!({Fake, lines: lines})

      assert Fake.recognise({:path, "x"}) == {:ok, lines}
      assert Fake.recognise({:key, "pages/1.png"}) == {:ok, lines}
      assert Fake.requests() == [{:path, "x"}, {:key, "pages/1.png"}]
    end
  end

  defp stub_line(%{crop: crop} = line) do
    line |> Map.put(:crop, Base.encode64(crop)) |> stringify_keys()
  end

  defp stringify_keys(line) do
    Map.new(line, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # Builds a framed reply body (stub adds the 4-byte length prefix) whose JSON
  # payload is exactly `target` bytes: a valid line padded through an ignored
  # top-level field.
  defp framed_body(target) do
    line = Jason.encode!(%{bbox: [0, 0, 10, 10], text: "あ", score: 1.0, crop: "eA=="})
    base = "{\"lines\":[#{line}],\"pad\":\"\"}"
    pad = String.duplicate("x", target - byte_size(base))
    :binary.replace(base, "\"pad\":\"\"", "\"pad\":\"#{pad}\"")
  end
end
